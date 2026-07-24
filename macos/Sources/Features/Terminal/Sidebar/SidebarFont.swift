import SwiftUI

/// Sidebar chrome typography — Inter Variable, bundled under `macos/Fonts/`
/// and registered via `ATSApplicationFontsPath`. SF Symbols (chevrons, ×)
/// stay on `.system` so they keep the symbol font.
enum SidebarFont {
    private static let family = "Inter Variable"

    static func font(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        Font.custom(family, size: size).weight(weight)
    }
}
