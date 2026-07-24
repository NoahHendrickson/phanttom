import SwiftUI

/// Phanttom's settings window content. Font-size changes apply live
/// (debounced) through a managed config fragment; sidebar grouping applies
/// instantly through SwiftUI. Chrome (sidebar/terminal colors) is locked
/// to the Figma design and is not exposed here.
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

            Section("Sidebar") {
                Toggle("Group tabs by project", isOn: $settings.sidebarGroupByProject)
            }

            ClaudeCodeIntegrationSection()
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .frame(minHeight: 320)
    }
}

/// Claude Code hooks/statusline installer (see `PhanttomClaudeIntegration`).
private struct ClaudeCodeIntegrationSection: View {
    @State private var caption = "…"
    @State private var status: PhanttomClaudeIntegration.IntegrationStatus = .notInstalled
    @State private var claudeMissing = false
    @State private var lastError: String?
    @State private var confirmRemove = false

    var body: some View {
        Section {
            Text(lastError ?? caption)
                .font(.caption)
                .foregroundStyle(lastError == nil ? Color.secondary : Color.red)

            HStack {
                if showPrimaryButton {
                    Button(primaryButtonTitle) {
                        // Explicit Set Up also lifts a prior Remove's opt-out
                        // so launch-time auto-sync resumes.
                        UserDefaults.standard.removeObject(
                            forKey: PhanttomClaudeIntegration.autoInstallDisabledKey)
                        apply(PhanttomClaudeIntegration.performInstall())
                    }
                    .disabled(claudeMissing)
                }
                Button("Remove…") {
                    confirmRemove = true
                }
                .disabled(claudeMissing || status == .notInstalled)
            }
        } header: {
            Text("Claude Code")
        } footer: {
            Text(
                "Phanttom hooks (pixel rain, tab auto-naming, agent pwd " +
                "tracking, model label) install automatically on launch when " +
                "~/.claude exists, writing ~/.claude/settings.json with a " +
                "timestamped backup. Remove turns this off until you set up " +
                "again."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .onAppear { apply(PhanttomClaudeIntegration.currentStatus()) }
        .alert("Remove Claude Code Integration?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) {
                // Removal must stick: block launch-time auto-install until an
                // explicit Set Up.
                UserDefaults.standard.set(
                    true, forKey: PhanttomClaudeIntegration.autoInstallDisabledKey)
                apply(PhanttomClaudeIntegration.performUninstall())
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Restores your previous statusline (if any) and removes Phanttom's hooks and helper script. Automatic setup on launch stays off until you set up again.")
        }
    }

    private var showPrimaryButton: Bool {
        switch status {
        case .installedCurrent: return false
        case .notInstalled, .installedOutdated, .legacyInline: return true
        }
    }

    private var primaryButtonTitle: String {
        switch status {
        case .notInstalled: return "Set Up"
        case .legacyInline, .installedOutdated: return "Update"
        case .installedCurrent: return "Set Up"
        }
    }

    private func apply(_ result: PhanttomClaudeIntegration.ActionResult) {
        status = result.status
        claudeMissing = result.error == .claudeNotFound
        caption = result.message
        // Surface actionable failures; "not found" is already the caption.
        if let err = result.error, err != .claudeNotFound {
            lastError = result.message
        } else {
            lastError = nil
        }
    }
}
