import Sparkle
import Cocoa

extension UpdateDriver: SPUUpdaterDelegate {
    func feedURLString(for updater: SPUUpdater) -> String? {
        guard let appDelegate = NSApplication.shared.delegate as? AppDelegate else {
            return nil
        }

        // Phanttom: updates come from the fork's GitHub Releases, never from
        // Ghostty's servers — an upstream appcast would "update" users to
        // stock Ghostty and wipe out the fork. `releases/latest/download`
        // always redirects to the newest non-prerelease asset, so the feed
        // URL is stable across releases. The fork doesn't ship separate
        // tip/stable channels (yet), so both map to the same feed.
        switch appDelegate.ghostty.config.autoUpdateChannel {
        case .tip, .stable:
            return "https://github.com/NoahHendrickson/phanttom/releases/latest/download/appcast.xml"
        }
    }

    /// Called when an update is scheduled to install silently,
    /// which occurs when `auto-update = download`.
    ///
    /// When `auto-update = check`, Sparkle will call the corresponding
    /// delegate method on the responsible driver instead.
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        viewModel.state = .installing(.init(
            isAutoUpdate: true,
            retryTerminatingApplication: immediateInstallHandler,
            dismiss: { [weak viewModel] in
                viewModel?.state = .idle
            }
        ))
        return true
    }
}
