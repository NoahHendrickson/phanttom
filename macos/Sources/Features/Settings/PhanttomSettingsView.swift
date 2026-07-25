import SwiftUI

/// Phanttom's settings window content. Font-size and quit→reopen window
/// restore apply live (debounced) through a managed config fragment;
/// sidebar grouping applies instantly through SwiftUI. Chrome
/// (sidebar/terminal colors) is locked to the Figma design and is not
/// exposed here.
///
/// Lives in its own file (upstream's `SettingsView` placeholder is left
/// untouched) so upstream's future settings GUI merges cleanly.
struct PhanttomSettingsView: View {
    @ObservedObject private var settings = PhanttomSettings.shared

    var body: some View {
        Form {
            Section {
                Toggle("Override font size", isOn: $settings.overrideFontSize)

                Stepper(value: $settings.fontSize, in: 6...72, step: 1) {
                    HStack {
                        Text("Font size")
                        Spacer()
                        Text(String(format: "%g pt", settings.fontSize))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(!settings.overrideFontSize)
            } header: {
                Text("Font")
            } footer: {
                Text("Overrides font-size from your config. Turn off to return to your configured size.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Restore windows on quit", isOn: $settings.restoreWindowsOnQuit)
            } header: {
                Text("Windows")
            } footer: {
                Text(
                    "Keeps tab and split layout (and each tab's directory) "
                        + "after Cmd-Q. Does not restore running programs, "
                        + "scrollback, or agent status — those start fresh."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Group tabs by project", isOn: $settings.sidebarGroupByProject)
                Toggle("Show pull request status", isOn: $settings.showPullRequestStatus)
            } header: {
                Text("Sidebar")
            } footer: {
                Text(
                    "Pull request status asks the gh CLI about the branch in "
                        + "each idle tab, roughly once a minute per branch. "
                        + "That is an authenticated request to GitHub from "
                        + "your machine, so it stays off until you turn it on."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            ClaudeCodeIntegrationSection()
            CursorAgentIntegrationSection()
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .frame(minHeight: 320)
    }
}

/// Normalized snapshot of an agent integration's state, so one Section view
/// can drive every installer without knowing their status / error
/// vocabularies (Claude has a `legacyInline` state and a `settingsCorrupt`
/// error; Cursor has two config files that can each be corrupt).
private struct AgentIntegrationState {
    /// Status caption under the header.
    var caption: String
    /// The agent's directory is absent — every control is inert, and the
    /// caption already explains why, so this is not surfaced as a failure.
    var agentMissing: Bool
    /// Actionable failure, shown in red in place of the caption.
    var failure: String?
    /// Title for the install/update button, or nil when fully installed
    /// (the button is hidden entirely).
    var primaryTitle: String?
    /// Whether there is anything to remove.
    var canRemove: Bool

    /// Pre-`onAppear` placeholder: matches the old per-section initial state
    /// (unknown caption, "Set Up" offered, nothing to remove yet).
    static let loading = AgentIntegrationState(
        caption: "…", agentMissing: false, failure: nil,
        primaryTitle: "Set Up", canRemove: false)
}

extension AgentIntegrationState {
    init(_ result: PhanttomClaudeIntegration.ActionResult) {
        let missing = result.error == .claudeNotFound
        self.init(
            caption: result.message,
            agentMissing: missing,
            // Surface actionable failures; "not found" is already the caption.
            failure: (result.error != nil && !missing) ? result.message : nil,
            primaryTitle: {
                switch result.status {
                case .installedCurrent: return nil
                case .notInstalled: return "Set Up"
                case .installedOutdated, .legacyInline: return "Update"
                }
            }(),
            canRemove: result.status != .notInstalled
        )
    }

    init(_ result: PhanttomCursorIntegration.ActionResult) {
        let missing = result.error == .cursorNotFound
        self.init(
            caption: result.message,
            agentMissing: missing,
            failure: (result.error != nil && !missing) ? result.message : nil,
            primaryTitle: {
                switch result.status {
                case .installedCurrent: return nil
                case .notInstalled: return "Set Up"
                case .installedOutdated: return "Update"
                }
            }(),
            canRemove: result.status != .notInstalled
        )
    }
}

/// One agent's hooks/statusline installer row. Every integration presents the
/// same three affordances — a status caption, Set Up / Update, and a confirmed
/// Remove… — so the chrome lives here once and each agent supplies its copy
/// plus three closures.
private struct AgentIntegrationSection: View {
    let title: String
    let footer: String
    let removeAlertTitle: String
    let removeAlertMessage: String
    /// Read current status without touching the filesystem beyond a stat.
    let load: () -> AgentIntegrationState
    /// Install or update. Also lifts a prior Remove's opt-out so launch-time
    /// auto-sync resumes — for every build, since the marker lives beside the
    /// agent's config.
    let install: () -> AgentIntegrationState
    /// Uninstall. Records the opt-out first so removal sticks across launches
    /// and across builds.
    let uninstall: () -> AgentIntegrationState

    @State private var state = AgentIntegrationState.loading
    @State private var confirmRemove = false

    var body: some View {
        Section {
            Text(state.failure ?? state.caption)
                .font(.caption)
                .foregroundStyle(state.failure == nil ? Color.secondary : Color.red)

            HStack {
                if let primaryTitle = state.primaryTitle {
                    Button(primaryTitle) { state = install() }
                        .disabled(state.agentMissing)
                }
                Button("Remove…") { confirmRemove = true }
                    .disabled(state.agentMissing || !state.canRemove)
            }
        } header: {
            Text(title)
        } footer: {
            Text(footer)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onAppear { state = load() }
        .alert(removeAlertTitle, isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) { state = uninstall() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(removeAlertMessage)
        }
    }
}

/// Claude Code hooks/statusline installer (see `PhanttomClaudeIntegration`).
private struct ClaudeCodeIntegrationSection: View {
    var body: some View {
        AgentIntegrationSection(
            title: "Claude Code",
            footer: "Phanttom hooks (pixel rain, tab auto-naming, agent pwd " +
                "tracking, model label) are set up once you agree, then " +
                "repaired and updated on launch, writing " +
                "~/.claude/settings.json with a timestamped backup. They run " +
                "in every Claude Code session on this Mac but only emit " +
                "inside Phanttom. Remove turns this off until you set up " +
                "again.",
            removeAlertTitle: "Remove Claude Code Integration?",
            removeAlertMessage: "Restores your previous statusline (if any) and removes Phanttom's hooks, helper script, and the config backups it made. Automatic setup on launch stays off until you set up again.",
            load: { .init(PhanttomClaudeIntegration.currentStatus()) },
            install: {
                // Setting up here IS the answer to the launch-time consent
                // question, so record it: launch must never re-ask something
                // the user has already decided in Settings.
                PhanttomClaudeIntegration.setAskedAutoInstall(true)
                PhanttomClaudeIntegration.setAutoInstallDisabled(false)
                return .init(PhanttomClaudeIntegration.performInstall())
            },
            uninstall: {
                PhanttomClaudeIntegration.setAskedAutoInstall(true)
                PhanttomClaudeIntegration.setAutoInstallDisabled(true)
                return .init(PhanttomClaudeIntegration.performUninstall())
            }
        )
    }
}

/// Cursor Agent CLI hooks/statusline installer (see `PhanttomCursorIntegration`).
private struct CursorAgentIntegrationSection: View {
    var body: some View {
        AgentIntegrationSection(
            title: "Cursor Agent",
            footer: "Phanttom hooks (pixel rain, the model label, agent pwd " +
                "tracking) are set up once you agree, then repaired and " +
                "updated on launch, writing ~/.cursor/hooks.json and " +
                "~/.cursor/cli-config.json with timestamped backups. They " +
                "run in every Cursor Agent session on this Mac but only emit " +
                "inside Phanttom. Remove turns this off until you set up " +
                "again.",
            removeAlertTitle: "Remove Cursor Agent Integration?",
            removeAlertMessage: "Restores your previous statusline (if any) and removes Phanttom's hooks, helper script, and the config backups it made. Automatic setup on launch stays off until you set up again.",
            load: { .init(PhanttomCursorIntegration.currentStatus()) },
            install: {
                PhanttomCursorIntegration.setAskedAutoInstall(true)
                PhanttomCursorIntegration.setAutoInstallDisabled(false)
                return .init(PhanttomCursorIntegration.performInstall())
            },
            uninstall: {
                PhanttomCursorIntegration.setAskedAutoInstall(true)
                PhanttomCursorIntegration.setAutoInstallDisabled(true)
                return .init(PhanttomCursorIntegration.performUninstall())
            }
        )
    }
}
