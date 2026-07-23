import AppKit
import Combine

extension Notification.Name {
    /// Posted whenever tab group membership may have changed (new tab, close,
    /// reorder). Posted from `TerminalController.relabelTabs`, which upstream
    /// already invokes on every membership change.
    static let phanttomSidebarTabsDidChange = Notification.Name("phanttomSidebarTabsDidChange")
}

/// Observes the tab group of a window and publishes tab metadata for the
/// sidebar. Event-driven: membership changes arrive via
/// `.phanttomSidebarTabsDidChange` (piggybacking on `relabelTabs`), title and
/// pwd changes via KVO on each tab window, and selection changes via key-window
/// notifications. No polling.
@MainActor
final class SidebarTabManager: ObservableObject {
    struct TabItem: Identifiable, Equatable {
        let id: ObjectIdentifier
        let title: String
        let directory: String?
        let isSelected: Bool
        let window: NSWindow

        /// The last path component of the pwd, for compact display.
        var directoryName: String? {
            directory.map { ($0 as NSString).lastPathComponent }
        }

        static func == (lhs: TabItem, rhs: TabItem) -> Bool {
            lhs.id == rhs.id && lhs.title == rhs.title
                && lhs.directory == rhs.directory
                && lhs.isSelected == rhs.isSelected
        }
    }

    @Published private(set) var tabs: [TabItem] = []

    private weak var window: NSWindow?
    private var notificationObservers: [NSObjectProtocol] = []
    private var windowObservations: [NSKeyValueObservation] = []
    private var tabBarObservation: NSKeyValueObservation?
    private weak var observedTabGroup: NSWindowTabGroup?

    init(window: NSWindow) {
        self.window = window

        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            .phanttomSidebarTabsDidChange,
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification,
            NSWindow.willCloseNotification,
        ]
        for name in names {
            notificationObservers.append(center.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                // Wait a runloop turn: tab group state (membership, selection)
                // settles after these notifications fire.
                DispatchQueue.main.async { self?.refresh() }
            })
        }

        refresh()
    }

    deinit {
        notificationObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    // MARK: - Actions

    func select(_ tab: TabItem) {
        tab.window.makeKeyAndOrderFront(nil)
    }

    func close(_ tab: TabItem) {
        // Route through the controller so close confirmation logic applies.
        if let controller = tab.window.windowController as? TerminalController {
            controller.closeTab(nil)
        } else {
            tab.window.performClose(nil)
        }
    }

    // MARK: - Refresh

    func refresh() {
        guard let window else { return }

        // The sidebar replaces the native tab bar: watch the tab group and
        // re-hide the bar the moment AppKit shows it. KVO (rather than a
        // check here) because the bar often appears after our events fire.
        // The group object changes when windows merge/split, so re-observe.
        if let group = window.tabGroup, group !== observedTabGroup {
            observedTabGroup = group
            tabBarObservation = group.observe(
                \.isTabBarVisible, options: [.initial, .new]
            ) { [weak self] _, _ in
                DispatchQueue.main.async {
                    // Re-check visibility at execution time: with one manager
                    // per window in the group, the first to run hides the bar
                    // and the rest bail here instead of re-toggling it.
                    guard let self,
                          let window = self.window,
                          let group = window.tabGroup,
                          group.isTabBarVisible else { return }
                    window.toggleTabBar(nil)
                }
            }
        }

        let tabWindows = window.tabbedWindows ?? [window]
        let selected = window.tabGroup?.selectedWindow ?? window

        let newTabs = tabWindows.map { w in
            TabItem(
                id: ObjectIdentifier(w),
                title: w.title,
                directory: w.representedURL?.path,
                isSelected: w === selected,
                window: w
            )
        }
        if newTabs != tabs { tabs = newTabs }

        // Re-register KVO for title/pwd changes on the current membership.
        windowObservations = tabWindows.flatMap { w in
            [
                w.observe(\.title) { [weak self] _, _ in
                    DispatchQueue.main.async { self?.refresh() }
                },
                w.observe(\.representedURL) { [weak self] _, _ in
                    DispatchQueue.main.async { self?.refresh() }
                },
            ]
        }
    }
}
