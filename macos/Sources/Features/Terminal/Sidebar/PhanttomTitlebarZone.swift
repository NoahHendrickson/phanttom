import AppKit

/// Marker class so the zone view can be found on re-sync without adding
/// stored state to TerminalWindow (extensions can't).
private final class PhanttomTitlebarZoneView: NSView {}

extension TerminalWindow {
    /// Phanttom: paints the titlebar segment above the sidebar in the
    /// sidebar's color so sidebar + titlebar strip read as one panel
    /// (Cursor-style split chrome). Called at the end of syncAppearance so
    /// it survives all the titlebar redraws that reset upstream styling
    /// (tab bar recreation, tab switches, settings changes).
    func syncPhanttomTitlebarZone() {
        guard sidebarActive else { return }
        guard let titlebarView = titlebarContainer?
            .firstDescendant(withClassName: "NSTitlebarView") else { return }

        let zone: PhanttomTitlebarZoneView
        if let existing = titlebarView.subviews
            .compactMap({ $0 as? PhanttomTitlebarZoneView }).first {
            zone = existing
        } else {
            zone = PhanttomTitlebarZoneView()
            zone.wantsLayer = true
            zone.autoresizingMask = [.height]
            // Below everything so the traffic lights, title, and any
            // accessories draw on top of the color strip.
            titlebarView.addSubview(zone, positioned: .below, relativeTo: titlebarView.subviews.first)
        }

        let settings = PhanttomSettings.shared
        let base = settings.resolvedSidebarColor(terminalBackground: preferredBackgroundColor)
        zone.layer?.backgroundColor = base
            .withAlphaComponent(base.alphaComponent * settings.sidebarOpacity)
            .cgColor

        phanttomTitlebarZoneSetWidth(phanttomSidebarWidth)
    }

    /// Cheap width-only update used during divider drags and the
    /// collapse/expand animation; the full sync above handles color.
    func phanttomTitlebarZoneSetWidth(_ width: CGFloat) {
        guard let titlebarView = titlebarContainer?
            .firstDescendant(withClassName: "NSTitlebarView"),
              let zone = titlebarView.subviews
            .compactMap({ $0 as? PhanttomTitlebarZoneView }).first else { return }

        zone.frame = NSRect(x: 0, y: 0, width: width, height: titlebarView.bounds.height)
        zone.isHidden = width <= 0
    }

    private var phanttomSidebarWidth: CGFloat {
        (contentView as? SidebarSplitView)?.currentSidebarWidth ?? 0
    }
}
