import AppKit

/// Marker classes so the zone views can be found on re-sync without adding
/// stored state to TerminalWindow (extensions can't).
private final class PhanttomTitlebarLeftZoneView: NSView {}
private final class PhanttomTitlebarRightZoneView: NSView {}
private final class PhanttomTitlebarDividerView: NSView {}
private final class PhanttomSidebarToggleButton: NSButton {}
private final class PhanttomGroupingButton: NSButton {}

/// Marks the left titlebar accessory used when the sidebar is collapsed so
/// the toggle parks in AppKit's accessory lane (after traffic lights, before
/// the document icon / title) instead of overlapping them at a fixed x.
private let phanttomSidebarToggleAccessoryID =
    NSUserInterfaceItemIdentifier("PhanttomSidebarToggleAccessory")

/// Invisible left spacer matching the sidebar width (minus traffic lights)
/// so AppKit centers the document icon + title in the terminal half of the
/// titlebar while the sidebar is open — not next to the traffic lights in
/// the sidebar color zone.
private let phanttomTitleSpacerAccessoryID =
    NSUserInterfaceItemIdentifier("PhanttomTitleSpacerAccessory")

/// Approximate trailing edge of the traffic-light cluster; left accessories
/// begin after this.
private let phanttomTrafficLightsTrailingX: CGFloat = 78

extension TerminalWindow {
    /// Phanttom: splits the titlebar into two color zones aligned with the
    /// sidebar divider (Cursor-style chrome). Left = Figma sidebar `#161917`,
    /// right = Figma terminal `#101211`. The style's own full-width fill is
    /// cleared so the zones own the chrome.
    ///
    /// Called (deferred via a same-pass runloop block — see
    /// phanttomSyncAppearanceDidRun) from syncAppearance so it runs after
    /// subclass overrides repaint the titlebar but before the frame commits,
    /// and therefore survives all the redraw triggers (tab switches, tab bar
    /// recreation, settings) without a visible flash.
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
        // on Tahoe), which would sit opaquely behind our zones.
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

        left.layer?.backgroundColor = PhanttomSettings.sidebarBackgroundNS.cgColor

        // Right: solid terminal chrome, or clear when an upstream glass
        // titlebar style owns the material.
        let glassTitlebar = derivedConfig.backgroundBlur.isGlassStyle &&
            (derivedConfig.macosTitlebarStyle == .transparent || derivedConfig.macosTitlebarStyle == .tabs)
        right.layer?.backgroundColor = glassTitlebar
            ? NSColor.clear.cgColor
            : PhanttomSettings.terminalBackgroundNS.cgColor

        // Hairline continuing the sidebar's divider through the titlebar.
        // Geometry (phanttomTitlebarZoneSetWidth) leaves the divider column
        // free of BOTH zones.
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
        divider.layer?.backgroundColor = PhanttomSettings.dividerColorNS.cgColor

        // Sidebar toggle + grouping mode button (geometry in
        // phanttomTitlebarZoneSetWidth). While open, toggle sits left of
        // grouping at the divider; while collapsed, a left titlebar
        // accessory parks the toggle in AppKit's accessory lane.
        if !titlebarView.subviews.contains(where: { $0 is PhanttomSidebarToggleButton }) {
            let button = PhanttomSidebarToggleButton()
            button.isBordered = false
            button.bezelStyle = .regularSquare
            button.image = NSImage(named: "PhanttomSidebarSimple")
                ?? NSImage(
                    systemSymbolName: "sidebar.left",
                    accessibilityDescription: "Toggle Sidebar")
            button.contentTintColor = .secondaryLabelColor
            button.toolTip = "Toggle Sidebar (⌘B)"
            button.target = self
            button.action = #selector(phanttomToggleSidebar(_:))
            button.autoresizingMask = [.maxXMargin]
            titlebarView.addSubview(button)
        }
        if !titlebarView.subviews.contains(where: { $0 is PhanttomGroupingButton }) {
            let button = PhanttomGroupingButton()
            button.isBordered = false
            button.bezelStyle = .regularSquare
            button.image = NSImage(named: "PhanttomRows")
                ?? NSImage(
                    systemSymbolName: "rectangle.3.group",
                    accessibilityDescription: "Tab Grouping")
            button.contentTintColor = .secondaryLabelColor
            button.toolTip = "Tab Grouping"
            button.target = self
            button.action = #selector(phanttomShowGroupingMenu(_:))
            button.autoresizingMask = [.maxXMargin]
            titlebarView.addSubview(button)
        }

        phanttomTitlebarZoneSetWidth(width ?? phanttomSidebarWidth)
    }

    @objc private func phanttomToggleSidebar(_ sender: Any?) {
        (contentView as? SidebarSplitView)?.toggleSidebar()
    }

    /// The grouping button's menu: a mode chooser, not a bare toggle, so
    /// the current state is legible (checkmark) and future grouping modes
    /// have somewhere to live.
    @objc private func phanttomShowGroupingMenu(_ sender: NSButton) {
        let grouped = PhanttomSettings.shared.sidebarGroupByProject
        let menu = NSMenu()
        let on = NSMenuItem(
            title: "Group by Project",
            action: #selector(phanttomEnableGrouping(_:)),
            keyEquivalent: "")
        on.target = self
        on.state = grouped ? .on : .off
        menu.addItem(on)
        let off = NSMenuItem(
            title: "No Grouping",
            action: #selector(phanttomDisableGrouping(_:)),
            keyEquivalent: "")
        off.target = self
        off.state = grouped ? .off : .on
        menu.addItem(off)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -4), in: sender)
    }

    /// The setting is @Published app-wide state: every window's sidebar
    /// re-renders instantly, and the Settings window checkbox stays in sync.
    @objc private func phanttomEnableGrouping(_ sender: Any?) {
        PhanttomSettings.shared.sidebarGroupByProject = true
    }

    @objc private func phanttomDisableGrouping(_ sender: Any?) {
        PhanttomSettings.shared.sidebarGroupByProject = false
    }

    /// Cheap geometry-only update used during divider drags and the
    /// collapse/expand animation; the full sync above handles colors.
    func phanttomTitlebarZoneSetWidth(_ width: CGFloat) {
        guard let titlebarView = titlebarContainer?
            .firstDescendant(withClassName: "NSTitlebarView") else { return }
        let bounds = titlebarView.bounds

        // Mirror the split view's geometry exactly: sidebar pane
        // [0, width - 1), divider column [width - 1, width), terminal from
        // width. The divider column gets NEITHER zone behind it.
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
        // Toggle left of grouping while the sidebar is open. When collapsed
        // (or mid-expand too narrow), hide the in-zone button and park a
        // left titlebar accessory so AppKit keeps it clear of the document
        // icon / title. Grouping stays hidden until there's room again.
        let size: CGFloat = 20
        let gap: CGFloat = 4
        let trailingPad: CGFloat = 6
        let groupingX = max(dividerX - size - trailingPad, 0)
        let besideGroupingX = max(groupingX - size - gap, 0)
        let parkToggle = width <= 0 || besideGroupingX < phanttomTrafficLightsTrailingX
        if let toggle = titlebarView.subviews
            .compactMap({ $0 as? PhanttomSidebarToggleButton }).first {
            toggle.frame = NSRect(
                x: besideGroupingX,
                y: (bounds.height - size) / 2,
                width: size, height: size)
            toggle.isHidden = parkToggle
        }
        if let grouping = titlebarView.subviews
            .compactMap({ $0 as? PhanttomGroupingButton }).first {
            grouping.frame = NSRect(
                x: groupingX,
                y: (bounds.height - size) / 2,
                width: size, height: size)
            grouping.isHidden = parkToggle
        }
        phanttomSetSidebarToggleAccessoryParked(parkToggle)
        phanttomSetTitleSpacerAccessory(
            sidebarWidth: width, active: !parkToggle && width > 0)
    }

    /// Install or remove the collapsed-state left accessory. A free-floating
    /// button at a fixed x lands on the document icon + title (`~`); the
    /// accessory lane is the layout slot AppKit reserves for that.
    private func phanttomSetSidebarToggleAccessoryParked(_ parked: Bool) {
        guard styleMask.contains(.titled) else { return }
        let existing = titlebarAccessoryViewControllers.first {
            $0.identifier == phanttomSidebarToggleAccessoryID
        }
        if !parked {
            if let existing,
               let idx = titlebarAccessoryViewControllers.firstIndex(of: existing) {
                removeTitlebarAccessoryViewController(at: idx)
            }
            return
        }
        // Spacer and toggle accessory both want .left; drop spacer first.
        phanttomSetTitleSpacerAccessory(sidebarWidth: 0, active: false)
        if existing != nil { return }

        guard let image = NSImage(named: "PhanttomSidebarSimple")
            ?? NSImage(
                systemSymbolName: "sidebar.left",
                accessibilityDescription: "Toggle Sidebar") else { return }

        let button = NSButton(image: image, target: self, action: #selector(phanttomToggleSidebar(_:)))
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = "Toggle Sidebar (⌘B)"
        button.frame = NSRect(x: 8, y: 1, width: 20, height: 20)
        button.autoresizingMask = [.minYMargin, .maxYMargin]

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 36, height: 22))
        container.addSubview(button)

        let accessory = NSTitlebarAccessoryViewController()
        accessory.identifier = phanttomSidebarToggleAccessoryID
        accessory.view = container
        accessory.layoutAttribute = .left
        addTitlebarAccessoryViewController(accessory)
    }

    /// Left spacer so AppKit's title layout treats the sidebar strip as
    /// occupied and centers the folder icon + directory label in the
    /// terminal half of the titlebar.
    private func phanttomSetTitleSpacerAccessory(sidebarWidth: CGFloat, active: Bool) {
        guard styleMask.contains(.titled) else { return }
        let existing = titlebarAccessoryViewControllers.first {
            $0.identifier == phanttomTitleSpacerAccessoryID
        }
        if !active {
            if let existing,
               let idx = titlebarAccessoryViewControllers.firstIndex(of: existing) {
                removeTitlebarAccessoryViewController(at: idx)
            }
            return
        }

        let spacerWidth = max(0, sidebarWidth - phanttomTrafficLightsTrailingX)
        if let existing {
            existing.view.frame.size.width = spacerWidth
            existing.view.needsLayout = true
            return
        }

        // Don't stack under the parked toggle accessory.
        if titlebarAccessoryViewControllers.contains(where: {
            $0.identifier == phanttomSidebarToggleAccessoryID
        }) {
            return
        }

        let container = NSView(frame: NSRect(x: 0, y: 0, width: spacerWidth, height: 22))
        container.wantsLayer = false
        let accessory = NSTitlebarAccessoryViewController()
        accessory.identifier = phanttomTitleSpacerAccessoryID
        accessory.view = container
        accessory.layoutAttribute = .left
        addTitlebarAccessoryViewController(accessory)
    }

    private var phanttomSidebarWidth: CGFloat {
        (contentView as? SidebarSplitView)?.currentSidebarWidth ?? 0
    }
}
