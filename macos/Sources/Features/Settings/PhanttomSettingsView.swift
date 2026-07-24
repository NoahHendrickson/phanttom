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
    @ObservedObject private var claude = PhanttomClaudeIntegration.shared

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

            Section {
                Toggle("Claude Code integration", isOn: $claude.enabled)
            } header: {
                Text("Agents")
            } footer: {
                Text(
                    "Shows live Claude Code activity on tabs: thinking "
                    + "animation, tab names from your first prompt, and "
                    + "worktree-aware directory tracking. Installs hooks in "
                    + "~/.claude/settings.json (backup kept); turning this "
                    + "off removes only Phanttom's entries."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .frame(minHeight: 280)
    }
}
