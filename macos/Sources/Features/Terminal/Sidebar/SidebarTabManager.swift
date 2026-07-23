import AppKit
import Combine
import SwiftUI

extension Notification.Name {
    /// Posted whenever tab group membership may have changed (new tab, close,
    /// reorder). Posted from `TerminalController.relabelTabs`, which upstream
    /// already invokes on every membership change.
    static let phanttomSidebarTabsDidChange = Notification.Name("phanttomSidebarTabsDidChange")
}

// MARK: - Per-window facade (stable ObservedObject for SidebarView)

/// Per-window ObservableObject bound into `SidebarView`. Always projects the
/// current tab-group model, so a tab created before `addTabbedWindow` still
/// picks up the parent's model after it joins — without retiring the object
/// SwiftUI is observing.
@MainActor
final class SidebarTabManager: ObservableObject {
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

        var directoryName: String? {
            directory.map { "/" + ($0 as NSString).lastPathComponent }
        }

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
    @Published private(set) var terminalBackground: Color?

    private weak var window: NSWindow?
    private var model: SidebarTabGroupModel?
    private var modelCancellable: AnyCancellable?
    private var notificationObservers: [NSObjectProtocol] = []

    /// Create the per-window facade installed into `SidebarView`. Safe to call
    /// from `windowDidLoad` before the window has joined its parent's tab group.
    init(window: NSWindow) {
        self.window = window

        let center = NotificationCenter.default
        for name: Notification.Name in [
            .phanttomSidebarTabsDidChange,
            NSWindow.didBecomeKeyNotification,
            NSWindow.willCloseNotification,
        ] {
            notificationObservers.append(center.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                DispatchQueue.main.async {
                    self?.handleFacadeNotification(name, notification)
                }
            })
        }

        rebindToCurrentGroup()
    }

    deinit {
        for observer in notificationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func select(_ tab: TabItem) {
        tab.window.makeKeyAndOrderFront(nil)
    }

    func rename(_ tab: TabItem, to name: String?) {
        guard let window = tab.window as? TerminalWindow else { return }
        let trimmed = name?.trimmingCharacters(in: .whitespaces)
        window.phanttomCustomTitle = (trimmed?.isEmpty ?? true) ? nil : trimmed
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

    private func handleFacadeNotification(_ name: Notification.Name, _ notification: Notification) {
        guard let window else { return }

        if name == NSWindow.willCloseNotification,
           let closing = notification.object as? NSWindow,
           closing === window {
            modelCancellable = nil
            model = nil
            return
        }

        // Membership / key changes may mean this window's tabGroup identity
        // changed (solo → joined parent). Retarget the facade.
        rebindToCurrentGroup()
    }

    private func rebindToCurrentGroup() {
        guard let window else { return }
        let next = SidebarTabGroupModel.shared(for: window)
        if next !== model {
            model = next
            modelCancellable = Publishers.CombineLatest(next.$tabs, next.$terminalBackground)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] tabs, background in
                    guard let self else { return }
                    if self.tabs != tabs { self.tabs = tabs }
                    if self.terminalBackground != background {
                        self.terminalBackground = background
                    }
                }
        }
        pullFromModel()
    }

    private func pullFromModel() {
        guard let model else { return }
        if tabs != model.tabs { tabs = model.tabs }
        if terminalBackground != model.terminalBackground {
            terminalBackground = model.terminalBackground
        }
    }
}

// MARK: - Tab-group model (keyed by NSWindowTabGroup)

/// One model per `NSWindowTabGroup`. Owns observations and publishes the tab
/// list. Facades retarget here when a window's `tabGroup` changes after join.
@MainActor
final class SidebarTabGroupModel: ObservableObject {
    @Published private(set) var tabs: [SidebarTabManager.TabItem] = []
    @Published private(set) var terminalBackground: Color?

    private static var byGroup = [ObjectIdentifier: SidebarTabGroupModel]()

    static func shared(for window: NSWindow) -> SidebarTabGroupModel {
        // AppKit gives every window a tab group (even solo). Keying here
        // deletes the byWindow survivor/retire merge protocol. When a new
        // tab later joins its parent, its tabGroup identity changes and the
        // per-window facade retargets to the parent's model.
        if let group = window.tabGroup {
            let key = ObjectIdentifier(group)
            if let existing = byGroup[key] {
                existing.ensureAnchor(window)
                return existing
            }
            let model = SidebarTabGroupModel(group: group, anchor: window)
            byGroup[key] = model
            model.start()
            return model
        }

        // Extremely rare: no tab group yet — key by window until one appears.
        let key = ObjectIdentifier(window)
        if let existing = byGroup[key] {
            existing.ensureAnchor(window)
            return existing
        }
        let model = SidebarTabGroupModel(group: nil, anchor: window)
        byGroup[key] = model
        model.start()
        return model
    }

    private struct WindowBag {
        var titleObservation: NSKeyValueObservation?
        var urlObservation: NSKeyValueObservation?
        var surfaceCancellables = Set<AnyCancellable>()
        var surfaceID: ObjectIdentifier?
        var pwd: String?
        var gitBranch: String?
    }

    private weak var tabGroup: NSWindowTabGroup?
    private weak var anchorWindow: NSWindow?
    private var bags = [ObjectIdentifier: WindowBag]()
    private var notificationObservers: [NSObjectProtocol] = []
    private var started = false
    private let groupKey: ObjectIdentifier

    private init(group: NSWindowTabGroup?, anchor: NSWindow) {
        self.tabGroup = group
        self.anchorWindow = anchor
        self.groupKey = group.map { ObjectIdentifier($0) } ?? ObjectIdentifier(anchor)
    }

    deinit {
        for observer in notificationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func ensureAnchor(_ window: NSWindow) {
        if anchorWindow == nil { anchorWindow = window }
    }

    private func start() {
        guard !started else { return }
        started = true

        let center = NotificationCenter.default
        for name: Notification.Name in [
            .phanttomSidebarTabsDidChange,
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification,
            NSWindow.willCloseNotification,
        ] {
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
            DispatchQueue.main.async {
                self?.handleBell(notification)
            }
        })

        refresh()
    }

    private func shutdown() {
        for observer in notificationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        notificationObservers.removeAll()
        bags.removeAll()
        Self.byGroup.removeValue(forKey: groupKey)
    }

    private func handleNotification(_ name: Notification.Name, _ notification: Notification) {
        let windows = currentWindows()
        guard !windows.isEmpty else {
            shutdown()
            return
        }

        if name == NSWindow.willCloseNotification,
           let closing = notification.object as? NSWindow {
            guard windows.contains(where: { $0 === closing })
                    || bags[ObjectIdentifier(closing)] != nil else { return }
            let id = ObjectIdentifier(closing)
            if let pwd = bags[id]?.pwd {
                Task { await GitBranchCache.shared.invalidate(pwd) }
            }
            bags.removeValue(forKey: id)
            let remaining = currentWindows().filter { $0 !== closing }
            if remaining.isEmpty {
                shutdown()
                return
            }
            refresh()
            return
        }

        // Ignore events outside this tab group.
        if let source = notification.object as? NSWindow {
            let inGroup = windows.contains(where: { $0 === source })
                || (tabGroup != nil && source.tabGroup === tabGroup)
            guard inGroup else { return }
        }

        if name == NSWindow.didBecomeKeyNotification,
           let key = notification.object as? TerminalWindow,
           windows.contains(where: { $0 === key }) {
            // Selection clears done/attention — transition here, not in refresh.
            key.phanttomDone = false
            key.phanttomAttention = false
        }

        refresh()
    }

    private func handleBell(_ notification: Notification) {
        let windows = currentWindows()
        guard !windows.isEmpty else { return }
        guard let controller = notification.object as? BaseTerminalController,
              let bellWindow = controller.window as? TerminalWindow,
              windows.contains(where: { $0 === bellWindow }) else { return }

        let hasBell = notification.userInfo?[
            Notification.Name.terminalWindowHasBellKey] as? Bool ?? false
        let selected = tabGroup?.selectedWindow ?? windows[0]
        if hasBell, bellWindow !== selected {
            bellWindow.phanttomAttention = true
        }
        refresh()
    }

    // MARK: - Project only

    private func currentWindows() -> [NSWindow] {
        if let tabGroup, !tabGroup.windows.isEmpty {
            return tabGroup.windows
        }
        if let anchorWindow {
            return [anchorWindow]
        }
        return []
    }

    func refresh() {
        let tabWindows = currentWindows()
        guard !tabWindows.isEmpty else {
            shutdown()
            return
        }

        let selected = tabGroup?.selectedWindow ?? tabWindows[0]
        syncMembership(tabWindows)

        var newTabs: [SidebarTabManager.TabItem] = []
        for w in tabWindows {
            let id = ObjectIdentifier(w)
            let controller = w.windowController as? BaseTerminalController
            let surface = controller?.focusedSurface
            let pwd = surface?.pwd ?? w.representedURL?.path
            let isSelected = w === selected
            let isWorking = surface?.progressReport != nil
            let terminalWindow = w as? TerminalWindow
            let bag = bags[id]

            if let pwd {
                updateGitBranch(for: id, pwd: pwd)
            }

            let kind = terminalWindow?.phanttomAgentKind ?? .terminal
            let status: SidebarTabManager.TabStatus
            if isWorking {
                status = .working
            } else if terminalWindow?.phanttomDone == true {
                status = .done
            } else if terminalWindow?.phanttomAttention == true {
                status = .attention
            } else {
                status = .idle
            }

            newTabs.append(SidebarTabManager.TabItem(
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

    // MARK: - Membership / event-driven transitions

    private func syncMembership(_ tabWindows: [NSWindow]) {
        let ids = Set(tabWindows.map { ObjectIdentifier($0) })
        for id in bags.keys where !ids.contains(id) {
            if let pwd = bags[id]?.pwd {
                Task { await GitBranchCache.shared.invalidate(pwd) }
            }
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
        bag.titleObservation = window.observe(\.title) { [weak self] w, _ in
            DispatchQueue.main.async {
                if let tw = w as? TerminalWindow {
                    self?.applyTitlePolicy(to: tw)
                }
                self?.refresh()
            }
        }
        bag.urlObservation = window.observe(\.representedURL) { [weak self] _, _ in
            DispatchQueue.main.async { self?.refresh() }
        }
        // Apply once for the title already present at bag creation.
        if let tw = window as? TerminalWindow {
            applyTitlePolicy(to: tw)
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
            .sink { [weak self] report in
                DispatchQueue.main.async {
                    self?.handleProgress(
                        window: window,
                        isWorking: report != nil
                    )
                    self?.refresh()
                }
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

        // Seed working-edge state for the current report (don't wait for the
        // next Combine event — the surface may already be mid-progress).
        handleProgress(window: window, isWorking: surface.progressReport != nil)
    }

    private func handleProgress(window: NSWindow, isWorking: Bool) {
        guard let terminalWindow = window as? TerminalWindow else { return }
        let selected = tabGroup?.selectedWindow
        let isSelected = window === selected

        if isWorking {
            terminalWindow.phanttomWasWorking = true
        } else if terminalWindow.phanttomWasWorking {
            terminalWindow.phanttomWasWorking = false
            if !isSelected {
                terminalWindow.phanttomDone = true
            }
        }
        if isSelected {
            terminalWindow.phanttomDone = false
            terminalWindow.phanttomAttention = false
        }
    }

    private func applyTitlePolicy(to window: TerminalWindow) {
        let before = TabTitleState(
            kind: window.phanttomAgentKind,
            autoTitle: window.phanttomAutoTitle
        )
        let next = TabTitlePolicy.apply(title: window.title, to: before)
        window.phanttomAgentKind = next.kind
        window.phanttomAutoTitle = next.autoTitle
    }

    private func updateGitBranch(for id: ObjectIdentifier, pwd: String) {
        guard var bag = bags[id] else { return }
        let pwdChanged = bag.pwd != pwd
        if pwdChanged {
            if let old = bag.pwd {
                Task { await GitBranchCache.shared.invalidate(old) }
            }
            bag.pwd = pwd
            bags[id] = bag
        }

        let known = bag.gitBranch
        let requestedPwd = pwd
        Task {
            _ = await GitBranchCache.shared.branch(
                at: requestedPwd,
                known: known,
                force: pwdChanged
            ) { [weak self] value in
                guard let self, var bag = self.bags[id] else { return }
                // Stale completion: tab has since cd'd elsewhere.
                guard bag.pwd == requestedPwd else { return }
                guard bag.gitBranch != value else { return }
                bag.gitBranch = value
                self.bags[id] = bag
                self.refresh()
            }
        }
    }
}
