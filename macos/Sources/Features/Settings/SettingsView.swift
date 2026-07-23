import SwiftUI

/// Phanttom's settings window content. Terminal-background changes apply
/// live (debounced) through a managed config fragment; sidebar changes apply
/// instantly through SwiftUI.
struct SettingsView: View {
    @ObservedObject var ghostty: Ghostty.App
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

                Toggle("Glass effect", isOn: $settings.sidebarGlass)

                LabeledSlider(
                    label: "Blur amount",
                    value: $settings.sidebarBlurAmount,
                    range: 0.1...1.0,
                    display: String(format: "%.0f%%", settings.sidebarBlurAmount * 100)
                )
                .disabled(!settings.sidebarGlass)

                Text("Glass blurs what’s behind the window in the sidebar’s region only. Lower the opacity to let it show through — the terminal side is unaffected.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .frame(minHeight: 360)
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
