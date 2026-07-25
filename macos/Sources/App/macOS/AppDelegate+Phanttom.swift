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

    /// One-time consent for an agent hook install. Returns true when the user
    /// wants the hooks.
    ///
    /// Asked once per agent directory (`~/.claude`, `~/.cursor`), never again
    /// — the answer is recorded beside the config it governs so it is shared
    /// by the Debug and release builds, which auto-install into the same
    /// place. After the answer, launch-time repair/update stays silent: the
    /// user is being asked whether Phanttom may modify another tool's
    /// configuration, not to approve each write.
    @MainActor
    private func askAgentIntegrationConsent(
        agent: String,
        configPath: String,
        details: String
    ) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Set up Phanttom's \(agent) integration?"
        alert.informativeText = """
            \(details)

            This writes \(configPath) and a helper script beside it (your \
            current config is backed up first). The hooks run for every \
            \(agent) session on this Mac, and stay silent outside Phanttom.

            You can change this any time in Phanttom Settings.
            """
        alert.addButton(withTitle: "Set Up")
        alert.addButton(withTitle: "Not Now")
        alert.alertStyle = .informational
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Claude Code integration: install (or repair / update) Phanttom's hooks
    /// whenever `~/.claude` exists. The first time — and only the first time —
    /// this asks; after that, repair and update run silently on every launch.
    /// The off switch is an explicit Remove… in Settings, which writes the
    /// shared opt-out marker beside settings.json; Set Up removes it.
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
                // Defer the whole migration while `~/.claude` is absent: the
                // marker can't be written yet, and clearing the old keys now
                // would silently drop the user's opt-out.
                guard PhanttomClaudeIntegration.migrateOptOutFromDefaults(
                    wasDisabled: true)
                else { return }
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

        // One-shot move of the pre-marker UserDefaults opt-out into the
        // shared marker file. Only clear the key once the move has actually
        // happened — it defers while ~/.claude is absent.
        if defaults.bool(forKey: PhanttomClaudeIntegration.autoInstallDisabledKey),
           PhanttomClaudeIntegration.migrateOptOutFromDefaults(wasDisabled: true) {
            defaults.removeObject(
                forKey: PhanttomClaudeIntegration.autoInstallDisabledKey)
        }

        guard !PhanttomClaudeIntegration.isAutoInstallDisabled() else { return }
        // claudeNotFound / settingsCorrupt: nothing safe to do — retry next
        // launch (once ~/.claude appears or settings.json parses again).
        guard status.error == nil else { return }

        if !PhanttomClaudeIntegration.hasAskedAutoInstall() {
            if status.status == .notInstalled {
                let granted = askAgentIntegrationConsent(
                    agent: "Claude Code",
                    configPath: "~/.claude/settings.json",
                    details: "Phanttom can show live agent status in the "
                        + "sidebar — working / done / needs-you — plus the "
                        + "agent's working directory and the model label. It "
                        + "also names each tab after the first prompt of a "
                        + "session, which puts that text in the window title."
                )
                // Record the answer before acting on it: an install that then
                // fails must not re-ask on the next launch.
                PhanttomClaudeIntegration.setAskedAutoInstall(true)
                guard granted else {
                    PhanttomClaudeIntegration.setAutoInstallDisabled(true)
                    return
                }
            } else {
                // Hooks are already here (an earlier build installed them, or
                // they were set up by hand). The question is moot — record it
                // as answered so it is never asked, and keep repairing.
                PhanttomClaudeIntegration.setAskedAutoInstall(true)
            }
        }

        switch status.status {
        case .notInstalled, .installedOutdated, .legacyInline:
            _ = PhanttomClaudeIntegration.performInstall()
        case .installedCurrent:
            break
        }
    }
    /// Cursor Agent integration, mirroring `autoSyncClaudeIntegration`: asked
    /// once, then installed / repaired / updated on every launch whenever
    /// `~/.cursor` exists. The off switch is an explicit Remove… in Settings,
    /// which writes the shared opt-out marker beside hooks.json; Set Up
    /// removes it.
    ///
    /// No key migration here (unlike Claude): this integration has never
    /// shipped a prompt, nor a released defaults-backed opt-out, so there is
    /// no prior decision to honor.
    @MainActor
    func autoSyncCursorIntegration() {
        // Ghostty.app is the XCTest host — never install there.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return
        }

        guard !PhanttomCursorIntegration.isAutoInstallDisabled() else { return }

        // cursorNotFound / hooksCorrupt / cliConfigCorrupt: nothing safe to do
        // — retry next launch (once ~/.cursor appears or the JSON parses).
        let status = PhanttomCursorIntegration.currentStatus()
        guard status.error == nil else { return }

        if !PhanttomCursorIntegration.hasAskedAutoInstall() {
            if status.status == .notInstalled {
                let granted = askAgentIntegrationConsent(
                    agent: "Cursor Agent",
                    configPath: "~/.cursor/hooks.json and "
                        + "~/.cursor/cli-config.json",
                    details: "Phanttom can show live agent status in the "
                        + "sidebar — working / done — plus the agent's "
                        + "working directory and the model label."
                )
                PhanttomCursorIntegration.setAskedAutoInstall(true)
                guard granted else {
                    PhanttomCursorIntegration.setAutoInstallDisabled(true)
                    return
                }
            } else {
                PhanttomCursorIntegration.setAskedAutoInstall(true)
            }
        }

        switch status.status {
        case .notInstalled, .installedOutdated:
            _ = PhanttomCursorIntegration.performInstall()
        case .installedCurrent:
            break
        }
    }
}
