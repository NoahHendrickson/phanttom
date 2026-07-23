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

    /// One-time prompt when Claude Code is present but Phanttom's hooks are
    /// not installed (or only the legacy hand-installed form remains).
    @MainActor
    func maybePromptClaudeIntegrationSetup() {
        // Ghostty.app is the XCTest host — never prompt (or install) there.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return
        }

        let key = PhanttomClaudeIntegration.setupPromptedKey
        guard !UserDefaults.standard.bool(forKey: key) else { return }

        let result = PhanttomClaudeIntegration.currentStatus()
        if result.error == .claudeNotFound {
            return
        }
        switch result.status {
        case .notInstalled, .legacyInline:
            break
        case .installedCurrent, .installedOutdated:
            return
        }

        // Set regardless of choice — one prompt, ever.
        UserDefaults.standard.set(true, forKey: key)

        let alert = NSAlert()
        alert.messageText = "Set Up Claude Code Integration?"
        alert.informativeText =
            "Phanttom can install hooks so Claude Code tabs get pixel rain, " +
            "auto-naming, agent directory tracking, and a model label. " +
            "This writes ~/.claude/settings.json (with a backup)."
        alert.addButton(withTitle: "Set Up")
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Not Now")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            _ = PhanttomClaudeIntegration.performInstall()
        case .alertSecondButtonReturn:
            SettingsWindowController.shared.show(ghostty: ghostty)
        default:
            break
        }
    }
}
