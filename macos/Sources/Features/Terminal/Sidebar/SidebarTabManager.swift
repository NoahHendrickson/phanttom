import AppKit
import Combine
import SwiftUI

extension Notification.Name {
    /// Posted whenever tab group membership may have changed (new tab, close,
    /// reorder). Posted from `TerminalController.relabelTabs`, which upstream
    /// already invokes on every membership change.
    static let phanttomSidebarTabsDidChange = Notification.Name("phanttomSidebarTabsDidChange")
}

/// Observes one native tab group and publishes tab metadata for every sidebar
/// in that group. One instance is shared across sibling tab windows (see
/// `shared(for:)`); sidebars are projectors of this model.
///
/// Event-driven: membership via `.phanttomSidebarTabsDidChange`, title/pwd via
/// per-window KVO (kept until the window leaves), progress/background via
/// per-surface Combine, selection via key-window notifications. No polling.
/// Status and title policy state live on each `TerminalWindow`.
@MainActor
final class SidebarTabManager: ObservableObject {
    /// Activity state shown on the trailing edge of the tab row.
    enum TabStatus: Equatable {
        case idle
        case working
        case done
        case attention
    }

    struct TabItem: Identifiable, Equatable {
        let id: ObjectIdentifier
        let title: String
        let customTitle: String?
        let autoTitle: String?
        let directory: String?
        let gitBranch: String?
        let kind: PhanttomTabKind
        let status: TabStatus
        let isSelected: Bool
        let window: NSWindow

        var displayTitle: String {
            TabTitlePolicy.displayTitle(
                title: title,
                customTitle: customTitle,
                autoTitle: autoTitle,
                kind: kind
            )
        }

        /// The last path component of the pwd, "/name" style per the design.
        var directoryName: String? {
            directory.map { "/" + ($0 as NSString).lastPathComponent }
        }

        /// Full pwd with ~ abbreviation, for compact terminal rows.
        var abbreviatedDirectory: String? {
            directory.map { ($0 as NSString).abbreviatingWithTildeInPath }
        }

        static func == (lhs: TabItem, rhs: TabItem) -> Bool {
            lhs.id == rhs.id && lhs.title == rhs.title
                && lhs.customTitle == rhs.customTitle
                && lhs.autoTitle == rhs.autoTitle
                && lhs.directory == rhs.directory
                && lhs.gitBranch == rhs.gitBranch
                && lhs.kind == rhs.kind
                && lhs.status == rhs.status
                && lhs.isSelected == rhs.isSelected
        }
    }

    @Published private(set) var tabs: [TabItem] = []

    /// Live background of the selected tab's surface — source of truth for
    /// Match Terminal mode.
    @Published private(set) var terminalBackground: Color?

    // MARK: - Shared registry (one manager per tab group)

    private static var byWindow = [ObjectIdentifier: SidebarTabManager]()

    /// Return the manager for this window's tab group, creating or merging as
    /// needed so every sibling sidebar observes the same object.
    static func shared(for window: NSWindow) -> SidebarTabManager {
        let siblings = window.tabbedWindows ?? [window]
        var survivor: SidebarTabManager?

        for sibling in siblings {
            guard let existing = byWindow[ObjectIdentifier(sibling)] else { continue }
            if let survivor {
                if existing !== survivor {
                    existing.retire()
                    byWindow[ObjectIdentifier(sibling)] = survivor
                }
            } else {
                survivor = existing
            }
        }

        let manager = survivor ?? SidebarTabManager()
        manager.anchorWindow = window
        let isNewSibling = manager.bags[ObjectIdentifier(window)] == nil
        for sibling in siblings {
            byWindow[ObjectIdentifier(sibling)] = manager
        }
        if survivor == nil {
            manager.start()
        } else if isNewSibling {
            // New sibling joined an existing group — pick it up immediately.
            manager.refresh()
        }
        return manager
    }

    // MARK: - Per-window observation bags

    private struct WindowBag {
        var titleObservation: NSKeyValueObservation?
        var urlObservation: NSKeyValueObservation?
        var surfaceCancellables = Set<AnyCancellable>()
        /// Last focused surface identity we subscribed to.
        var surfaceID: ObjectIdentifier?
        var pwd: String?
        var gitBranch: String?
    }

    private weak var anchorWindow: NSWindow?
    private var bags = [ObjectIdentifier: WindowBag]()
    private var notificationObservers: [NSObjectProtocol] = []
    private var started = false
    private var retired = false

    private init() {}

    deinit {
        // NotificationCenter observers must be removed; bags/KVO drop with self.
        for observer in notificationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func start() {
        guard !started else { return }
        started = true

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
            ) { [weak self] notification in
                DispatchQueue.main.async {
                    self?.handleNotification(name, notification)
                }
            })
        }

        notificationObservers.append(center.addObserver(
            forName: .terminalWindowBellDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            Task { @MainActor in
                self.handleBell(notification)
            }
        })

        refresh()
    }

    private func retire() {
        guard !retired else { return }
        retired = true
        for observer in notificationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        notificationObservers.removeAll()
        bags.removeAll()
        // Drop registry entries that still point at us.
        Self.byWindow = Self.byWindow.filter { $0.value !== self }
    }

    private func handleNotification(_ name: Notification.Name, _ notification: Notification) {
        guard !retired else { return }

        if name == NSWindow.willCloseNotification,
           let closing = notification.object as? NSWindow {
            let id = ObjectIdentifier(closing)
            // Ignore closes outside this tab group.
            guard Self.byWindow[id] === self || bags[id] != nil else { return }
            bags.removeValue(forKey: id)
            Self.byWindow.removeValue(forKey: id)
            if Self.byWindow.values.contains(where: { $0 === self }) == false {
                retire()
                return
            }
            refresh()
            return
        }

        // Ignore events from windows that aren't (and weren't) in our group.
        if let source = notification.object as? NSWindow {
            let id = ObjectIdentifier(source)
            let inGroup = Self.byWindow[id] === self
                || (source.tabbedWindows ?? [source]).contains {
                    Self.byWindow[ObjectIdentifier($0)] === self
                }
            guard inGroup else { return }
        }

        // Re-bind siblings in case a new tab joined after creating its own
        // manager in windowDidLoad. May retire this instance if we lost merge.
        if let anchor = anchorWindow ?? (notification.object as? NSWindow) {
            _ = Self.shared(for: anchor)
        }
        guard !retired else { return }
        refresh()
    }

    private func handleBell(_ notification: Notification) {
        guard !retired else { return }
        guard let controller = notification.object as? BaseTerminalController,
              let bellWindow = controller.window as? TerminalWindow else {
            refresh()
            return
        }
        // Only care about bells in our tab group.
        guard Self.byWindow[ObjectIdentifier(bellWindow)] === self else { return }

        let hasBell = notification.userInfo?[
            Notification.Name.terminalWindowHasBellKey] as? Bool ?? false
        let selected = bellWindow.tabGroup?.selectedWindow
        if hasBell, bellWindow !== selected {
            bellWindow.phanttomAttention = true
        }
        refresh()
    }

    // MARK: - Actions

    func select(_ tab: TabItem) {
        tab.window.makeKeyAndOrderFront(nil)
    }

    /// Set (or clear, with nil/empty) a user-assigned tab name. Stored on the
    /// window; the change notification refreshes every sidebar in the group.
    func rename(_ tab: TabItem, to name: String?) {
        guard let window = tab.window as? TerminalWindow else { return }
        let trimmed = name?.trimmingCharacters(in: .whitespaces)
        window.phanttomCustomTitle = (trimmed?.isEmpty ?? true) ? nil : trimmed
        // Clearing the name also re-arms first-prompt auto-naming.
        if window.phanttomCustomTitle == nil { window.phanttomAutoTitle = nil }
        NotificationCenter.default.post(name: .phanttomSidebarTabsDidChange, object: window)
    }

    func close(_ tab: TabItem) {
        if let controller = tab.window.windowController as? TerminalController {
            controller.closeTab(nil)
        } else {
            tab.window.performClose(nil)
        }
    }

    // MARK: - Refresh (project window state → tabs[])

    func refresh() {
        guard !retired else { return }
        guard let window = anchorWindow ?? tabs.first?.window else { return }

        // Note: native tab bar hiding lives in TerminalWindow.sidebarActive.
        // Never toggle the tab bar from here.

        let tabWindows = window.tabbedWindows ?? [window]
        let selected = window.tabGroup?.selectedWindow ?? window

        syncMembership(tabWindows)

        var newTabs: [TabItem] = []
        for w in tabWindows {
            let id = ObjectIdentifier(w)
            let controller = w.windowController as? BaseTerminalController
            let surface = controller?.focusedSurface
            let pwd = surface?.pwd ?? w.representedURL?.path
            let isSelected = w === selected
            let isWorking = surface?.progressReport != nil

            let terminalWindow = w as? TerminalWindow
            if let terminalWindow {
                applyTitlePolicy(to: terminalWindow)
                updateStatus(
                    on: terminalWindow,
                    isWorking: isWorking,
                    isSelected: isSelected
                )
            }

            let bag = bags[id]
            // Keep bag pwd in sync and resolve git off the hot path.
            if let pwd {
                updateGitBranch(for: id, pwd: pwd)
            }

            let kind = terminalWindow?.phanttomAgentKind ?? .terminal
            let status = status(
                isWorking: isWorking,
                done: terminalWindow?.phanttomDone ?? false,
                attention: terminalWindow?.phanttomAttention ?? false
            )

            newTabs.append(TabItem(
                id: id,
                title: w.title,
                customTitle: terminalWindow?.phanttomCustomTitle,
                autoTitle: terminalWindow?.phanttomAutoTitle,
                directory: pwd,
                gitBranch: bag?.gitBranch,
                kind: kind,
                status: status,
                isSelected: isSelected,
                window: w
            ))
        }

        if newTabs != tabs { tabs = newTabs }

        let selectedSurface = (selected.windowController as? BaseTerminalController)?.focusedSurface
        let liveBackground = selectedSurface?.backgroundColor
        if liveBackground != terminalBackground { terminalBackground = liveBackground }
    }

    // MARK: - Membership / observations

    private func syncMembership(_ tabWindows: [NSWindow]) {
        let ids = Set(tabWindows.map { ObjectIdentifier($0) })
        for id in bags.keys where !ids.contains(id) {
            bags.removeValue(forKey: id)
        }
        for w in tabWindows {
            let id = ObjectIdentifier(w)
            if bags[id] == nil {
                bags[id] = makeBag(for: w)
            }
            syncSurfaceSubscriptions(for: w)
        }
    }

    private func makeBag(for window: NSWindow) -> WindowBag {
        var bag = WindowBag()
        bag.titleObservation = window.observe(\.title) { [weak self] _, _ in
            DispatchQueue.main.async { self?.refresh() }
        }
        bag.urlObservation = window.observe(\.representedURL) { [weak self] _, _ in
            DispatchQueue.main.async { self?.refresh() }
        }
        return bag
    }

    private func syncSurfaceSubscriptions(for window: NSWindow) {
        let id = ObjectIdentifier(window)
        guard var bag = bags[id] else { return }
        guard let controller = window.windowController as? BaseTerminalController,
              let surface = controller.focusedSurface else {
            if bag.surfaceID != nil {
                bag.surfaceCancellables.removeAll()
                bag.surfaceID = nil
                bags[id] = bag
            }
            return
        }

        let surfaceID = ObjectIdentifier(surface)
        guard bag.surfaceID != surfaceID else { return }

        bag.surfaceCancellables.removeAll()
        bag.surfaceID = surfaceID
        surface.$progressReport
            .dropFirst()
            .removeDuplicates { $0 == nil && $1 == nil }
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.refresh() }
            }
            .store(in: &bag.surfaceCancellables)
        surface.$backgroundColor
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.refresh() }
            }
            .store(in: &bag.surfaceCancellables)
        bags[id] = bag
    }

    private func updateGitBranch(for id: ObjectIdentifier, pwd: String) {
        guard var bag = bags[id] else { return }
        if bag.pwd == pwd { return }
        bag.pwd = pwd
        bags[id] = bag
        let known = bag.gitBranch
        Task {
            _ = await GitBranchCache.shared.branch(at: pwd, known: known) { [weak self] value in
                guard let self, var bag = self.bags[id] else { return }
                guard bag.gitBranch != value else { return }
                bag.gitBranch = value
                self.bags[id] = bag
                self.refresh()
            }
        }
    }

    // MARK: - Window-owned policy / status

    private func applyTitlePolicy(to window: TerminalWindow) {
        // Sticky agent kind is optional on the window: nil means plain terminal.
        let before = TabTitleState(
            kind: window.phanttomAgentKind,
            autoTitle: window.phanttomAutoTitle
        )
        let next = TabTitlePolicy.apply(title: window.title, to: before)
        window.phanttomAgentKind = next.kind
        window.phanttomAutoTitle = next.autoTitle
    }

    private func updateStatus(
        on window: TerminalWindow,
        isWorking: Bool,
        isSelected: Bool
    ) {
        if isWorking {
            window.phanttomWasWorking = true
        } else if window.phanttomWasWorking {
            window.phanttomWasWorking = false
            if !isSelected {
                window.phanttomDone = true
            }
        }
        if isSelected {
            window.phanttomDone = false
            window.phanttomAttention = false
        }
    }

    private func status(
        isWorking: Bool,
        done: Bool,
        attention: Bool
    ) -> TabStatus {
        if isWorking { return .working }
        if done { return .done }
        if attention { return .attention }
        return .idle
    }
}
