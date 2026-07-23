import AppKit

/// Marker classes so the zone views can be found on re-sync without adding
/// stored state to TerminalWindow (extensions can't).
private final class PhanttomTitlebarLeftZoneView: NSView {}
private final class PhanttomTitlebarRightZoneView: NSView {}
private final class PhanttomTitlebarDividerView: NSView {}

extension TerminalWindow {
    /// Phanttom: splits the titlebar into two color zones aligned with the
    /// sidebar divider (Cursor-style chrome). The left zone renders exactly
    /// like the sidebar (same resolved color at the same opacity, so window
    /// glass shows through identically); the right zone renders what the
    /// window style would have painted for the terminal side. The style's
    /// own full-width fill is cleared so the translucent left zone isn't
    /// backed by an opaque layer.
    ///
    /// Called (deferred a runloop turn) from syncAppearance so it runs after
    /// subclass overrides repaint the titlebar, and therefore survives all
    /// the redraw triggers (tab switches, tab bar recreation, settings).
    ///
    /// Pass `width` when the caller knows the divider position better than
    /// the split view's current frames do (during the collapse/expand
    /// animation the frames lag the toggle by a full animation).
    func syncPhanttomTitlebarZone(width: CGFloat? = nil) {
        guard sidebarActive else { return }
        guard let titlebarView = titlebarContainer?
            .firstDescendant(withClassName: "NSTitlebarView") else { return }

        // Take over background painting from the window style: it fills the
        // whole titlebar with one color (container on Ventura, titlebar view
        // on Tahoe), which would sit opaquely behind our translucent zones.
        titlebarView.wantsLayer = true
        titlebarView.layer?.backgroundColor = nil
        titlebarContainer?.layer?.backgroundColor = nil

        func zone<V: NSView>(_ type: V.Type, _ make: () -> V) -> V {
            if let existing = titlebarView.subviews.compactMap({ $0 as? V }).first {
                return existing
            }
            let view = make()
            view.wantsLayer = true
            view.autoresizingMask = [.height]
            // Below everything so the traffic lights, title, and any
            // accessories draw on top of the color strips.
            titlebarView.addSubview(view, positioned: .below, relativeTo: titlebarView.subviews.first)
            return view
        }
        let left = zone(PhanttomTitlebarLeftZoneView.self) { .init() }
        let right = zone(PhanttomTitlebarRightZoneView.self) { .init() }
        left.autoresizingMask = [.height, .maxXMargin]
        right.autoresizingMask = [.height, .width]

        // Left: the sidebar's exact look — resolved color at sidebar opacity.
        let settings = PhanttomSettings.shared
        let base = settings.resolvedSidebarColor(terminalBackground: preferredBackgroundColor)
        left.layer?.backgroundColor = base
            .withAlphaComponent(base.alphaComponent * settings.sidebarOpacity)
            .cgColor

        // Right: what the transparent style would paint for the terminal side
        // (clear when the Tahoe glass background style owns the titlebar).
        let glassTitlebar = derivedConfig.backgroundBlur.isGlassStyle &&
            (derivedConfig.macosTitlebarStyle == .transparent || derivedConfig.macosTitlebarStyle == .tabs)
        right.layer?.backgroundColor = glassTitlebar
            ? NSColor.clear.cgColor
            : (preferredBackgroundColor ?? .windowBackgroundColor).cgColor

        // Hairline continuing the sidebar's divider through the titlebar.
        // Stacked topmost (above the left zone, which sits above the right
        // zone). Geometry (phanttomTitlebarZoneSetWidth) leaves the divider
        // column free of BOTH zones, so this translucent hairline composites
        // directly over the window background — exactly what the split
        // view's divider composites over (opaque terminal color, or the
        // glass blur when the window is transparent). Backing it with
        // either zone's color tints the titlebar segment differently from
        // the segment below it.
        let divider: PhanttomTitlebarDividerView
        if let existing = titlebarView.subviews
            .compactMap({ $0 as? PhanttomTitlebarDividerView }).first {
            divider = existing
        } else {
            divider = .init()
            divider.wantsLayer = true
            divider.autoresizingMask = [.height]
            titlebarView.addSubview(divider, positioned: .above, relativeTo: left)
        }
        divider.layer?.backgroundColor =
            ((contentView as? SidebarSplitView)?.dividerColor
                ?? .white.withAlphaComponent(0.12)).cgColor

        phanttomTitlebarZoneSetWidth(width ?? phanttomSidebarWidth)
    }

    /// Cheap geometry-only update used during divider drags and the
    /// collapse/expand animation; the full sync above handles colors.
    func phanttomTitlebarZoneSetWidth(_ width: CGFloat) {
        guard let titlebarView = titlebarContainer?
            .firstDescendant(withClassName: "NSTitlebarView") else { return }
        let bounds = titlebarView.bounds

        // Mirror the split view's geometry exactly: sidebar pane
        // [0, width - 1), divider column [width - 1, width), terminal from
        // width. The divider column gets NEITHER zone behind it, so the
        // hairline composites over the bare window background exactly like
        // the split view's own divider one pixel below.
        let dividerX = max(width - 1, 0)
        if let left = titlebarView.subviews
            .compactMap({ $0 as? PhanttomTitlebarLeftZoneView }).first {
            left.frame = NSRect(x: 0, y: 0, width: dividerX, height: bounds.height)
            left.isHidden = width <= 0
        }
        if let right = titlebarView.subviews
            .compactMap({ $0 as? PhanttomTitlebarRightZoneView }).first {
            right.frame = NSRect(
                x: width, y: 0,
                width: max(bounds.width - width, 0), height: bounds.height)
        }
        if let divider = titlebarView.subviews
            .compactMap({ $0 as? PhanttomTitlebarDividerView }).first {
            divider.frame = NSRect(x: dividerX, y: 0, width: 1, height: bounds.height)
            divider.isHidden = width <= 0
        }
    }

    private var phanttomSidebarWidth: CGFloat {
        (contentView as? SidebarSplitView)?.currentSidebarWidth ?? 0
    }
}
