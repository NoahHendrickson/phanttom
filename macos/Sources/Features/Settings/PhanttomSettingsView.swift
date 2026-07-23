import SwiftUI

/// Phanttom's settings window content. Terminal-background changes apply
/// live (debounced) through a managed config fragment; sidebar changes apply
/// instantly through SwiftUI.
///
/// Lives in its own file (upstream's `SettingsView` placeholder is left
/// untouched) so upstream's future settings GUI merges cleanly.
struct PhanttomSettingsView: View {
    @ObservedObject private var settings = PhanttomSettings.shared

    var body: some View {
        Form {
            Section {
                Toggle("Override terminal background", isOn: $settings.overrideBackground)

                Group {
                    ColorPicker(
                        "Background color",
                        selection: $settings.backgroundColor,
                        supportsOpacity: false
                    )

                    LabeledSlider(
                        label: "Opacity",
                        value: $settings.backgroundOpacity,
                        range: 0.1...1.0,
                        display: String(format: "%.0f%%", settings.backgroundOpacity * 100)
                    )

                    LabeledSlider(
                        label: "Background blur",
                        value: $settings.backgroundBlur,
                        range: 0...40,
                        display: settings.backgroundBlur < 1
                            ? "Off" : String(format: "%.0f", settings.backgroundBlur)
                    )
                }
                .disabled(!settings.overrideBackground)
            } header: {
                Text("Terminal Background")
            } footer: {
                Text(
                    "Applied via a managed fragment (phanttom.conf) that your " +
                    "config includes — your own config file stays untouched. " +
                    "Blur requires opacity below 100%."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

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
                Picker("Background", selection: $settings.sidebarStyle) {
                    ForEach(PhanttomSettings.SidebarStyle.allCases) { style in
                        Text(style.label).tag(style)
                    }
                }
                .pickerStyle(.segmented)

                if settings.sidebarStyle == .custom {
                    ColorPicker(
                        "Sidebar color",
                        selection: $settings.sidebarColor,
                        supportsOpacity: false
                    )
                }

                LabeledSlider(
                    label: "Opacity",
                    value: $settings.sidebarOpacity,
                    range: 0.1...1.0,
                    display: String(format: "%.0f%%", settings.sidebarOpacity * 100)
                )

                Stepper(value: $settings.sidebarFontSize, in: 8...20, step: 1) {
                    HStack {
                        Text("Font size")
                        Spacer()
                        Text(String(format: "%g pt", settings.sidebarFontSize))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }

                HStack {
                    ColorPicker(
                        "Thinking animation",
                        selection: $settings.sidebarWorkingColor,
                        supportsOpacity: false
                    )
                    if PhanttomSettings.hex(from: settings.sidebarWorkingColor)
                        != PhanttomSettings.hex(from: PhanttomSettings.defaultWorkingColor) {
                        Button("Reset") {
                            settings.sidebarWorkingColor = PhanttomSettings.defaultWorkingColor
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                    }
                }

                Toggle("Group tabs by project", isOn: $settings.sidebarGroupByProject)

                Toggle("Glass effect", isOn: $settings.sidebarGlass)

                LabeledSlider(
                    label: "Blur amount",
                    value: $settings.sidebarBlurAmount,
                    range: 0...1.0,
                    display: String(format: "%.0f%%", settings.sidebarBlurAmount * 100)
                )
                .disabled(!settings.sidebarGlass)

                Text("Glass makes the sidebar see through the window — lower the sidebar opacity to reveal it. Blur amount controls how frosted that view is; 0% is completely clear. The terminal side is unaffected.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ClaudeCodeIntegrationSection()
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .frame(minHeight: 360)
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
                "Installs Phanttom hooks for pixel rain, tab auto-naming, " +
                "agent pwd tracking, and the model label. Writes " +
                "~/.claude/settings.json (with a timestamped backup)."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .onAppear { apply(PhanttomClaudeIntegration.currentStatus()) }
        .alert("Remove Claude Code Integration?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) {
                apply(PhanttomClaudeIntegration.performUninstall())
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Restores your previous statusline (if any) and removes Phanttom's hooks and helper script.")
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

private struct LabeledSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let display: String

    var body: some View {
        HStack {
            Text(label)
            Slider(value: $value, in: range)
            Text(display)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .trailing)
        }
    }
}
