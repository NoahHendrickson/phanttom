import AppKit

/// Phanttom's menu additions, inserted programmatically so upstream's
/// MainMenu.xib stays untouched and AppDelegate carries a single call.
extension AppDelegate {
    /// Called from applicationDidFinishLaunching. Inserts:
    /// - "Phanttom Settings…" (⌘⇧,) above "Open Config" in the app menu
    /// - "Toggle Sidebar" (⌘B) after "Terminal Read-only" in the Terminal menu
    ///
    /// Anchor items are located by their wired actions, not outlets, so this
    /// needs nothing from AppDelegate's private storage.
    func setupPhanttomMenus() {
        if let appMenu = NSApp.mainMenu?.items.first?.submenu {
            let idx = appMenu.indexOfItem(
                withTarget: self, andAction: #selector(AppDelegate.openConfig(_:)))
            if idx >= 0 {
                let item = NSMenuItem(
                    title: "Phanttom Settings…",
                    action: #selector(openPhanttomSettings(_:)),
                    keyEquivalent: ","
                )
                item.keyEquivalentModifierMask = [.command, .shift]
                appMenu.insertItem(item, at: idx)
            }
        }

        // The Terminal menu is found via its "Terminal Read-only" item
        // (first-responder target, so target is nil here).
        let readonlySelector = #selector(Ghostty.SurfaceView.toggleReadonly(_:))
        for topItem in NSApp.mainMenu?.items ?? [] {
            guard let menu = topItem.submenu else { continue }
            let idx = menu.indexOfItem(withTarget: nil, andAction: readonlySelector)
            guard idx >= 0 else { continue }
            let item = NSMenuItem(
                title: "Toggle Sidebar",
                action: #selector(TerminalController.togglePhanttomSidebar(_:)),
                keyEquivalent: "b"
            )
            item.keyEquivalentModifierMask = [.command]
            menu.insertItem(.separator(), at: idx + 1)
            menu.insertItem(item, at: idx + 2)
            break
        }
    }

    @IBAction func openPhanttomSettings(_ sender: Any?) {
        SettingsWindowController.shared.show(ghostty: ghostty)
    }

    /// Zero-touch Claude Code integration: on every launch, silently install
    /// (or repair / update) Phanttom's hooks whenever `~/.claude` exists —
    /// no consent prompt. The only off switch is an explicit Remove… in
    /// Settings, which sets `autoInstallDisabledKey`; Set Up re-enables it.
    /// Failures are log-only here (Settings surfaces them on demand); a
    /// missing `~/.claude` or corrupt settings.json just retries next launch.
    @MainActor
    func autoSyncClaudeIntegration() {
        // Ghostty.app is the XCTest host — never install there.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return
        }

        let defaults = UserDefaults.standard
        let status = PhanttomClaudeIntegration.currentStatus()

        // One-shot migration of the pre-auto-install consent keys, so a user
        // who declined the old prompt (or removed via Settings before the
        // opt-out key existed) isn't force-reinstalled.
        let legacyValue = defaults.string(
            forKey: PhanttomClaudeIntegration.legacyConsentKey)
        let promptedKeySet = defaults.bool(
            forKey: PhanttomClaudeIntegration.setupPromptedKey)
        if legacyValue != nil || promptedKeySet {
            switch PhanttomClaudeIntegration.migrateConsent(
                legacyValue: legacyValue,
                promptedKeySet: promptedKeySet,
                status: status.status,
                statusError: status.error
            ) {
            case .disableAutoInstall:
                defaults.set(
                    true, forKey: PhanttomClaudeIntegration.autoInstallDisabledKey)
                fallthrough
            case .autoInstall:
                defaults.removeObject(
                    forKey: PhanttomClaudeIntegration.legacyConsentKey)
                defaults.removeObject(
                    forKey: PhanttomClaudeIntegration.setupPromptedKey)
            case .retryLater:
                return
            }
        }

        guard !defaults.bool(
            forKey: PhanttomClaudeIntegration.autoInstallDisabledKey)
        else { return }
        // claudeNotFound / settingsCorrupt: nothing safe to do — retry next
        // launch (once ~/.claude appears or settings.json parses again).
        guard status.error == nil else { return }

        switch status.status {
        case .notInstalled, .installedOutdated, .legacyInline:
            _ = PhanttomClaudeIntegration.performInstall()
        case .installedCurrent:
            break
        }
    }
}
