import SwiftUI

/// The agent card's title label, which types a freshly assigned auto-name in
/// one character at a time.
///
/// Only the arrival of a NEW auto-name animates (`animatedValue` — the tab
/// state's `autoTitle`, set from the user's prompt by the agent hook). Every
/// other title change the sidebar makes — a rename, the shell reclaiming the
/// tab, the glyph-stripped surface title flickering as an agent redraws — is
/// applied instantly: those fire constantly during a session, and animating
/// them would leave the row permanently retyping itself.
///
/// The row keeps its SwiftUI identity across refreshes (`ForEach` over
/// `TabItem.id`, the tab window's `ObjectIdentifier`), so the `@State` here
/// survives the republished lists an in-flight reveal rides on.
struct SidebarTypewriterTitle: View {
    let text: String
    /// The auto-name whose arrival should animate. Nil for a tab that has
    /// none; when it is non-nil but not what the row shows (a user rename
    /// outranks the auto-name) nothing animates either.
    let animatedValue: String?
    let size: CGFloat

    /// Per-character delay, and the ceiling the whole reveal is squeezed
    /// into so a long prompt doesn't type for seconds.
    private static let step: Duration = .milliseconds(22)
    private static let maxDuration: Duration = .milliseconds(650)

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// What is on screen: the full title, or a prefix mid-reveal.
    @State private var shown: String = ""
    /// The title currently being typed — nil when idle. Also drives the
    /// caret, and keeps a redundant sync (both `text` and `animatedValue`
    /// changing in the same pass) from restarting the reveal.
    @State private var typing: String?
    /// The last `animatedValue` reacted to, so an auto-name types once no
    /// matter how many refreshes republish it.
    @State private var settled: String?
    @State private var task: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 3) {
            Text(shown)
                .font(SidebarFont.font(size: size))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
            if typing != nil {
                // Caret, only while typing. Dropping it on completion can't
                // shift the title: the label is leading-aligned.
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.white.opacity(0.7))
                    .frame(width: 2, height: size * 0.85)
            }
        }
        .onAppear {
            // First layout adopts whatever the tab already shows: a row
            // scrolling back into view must not retype an old name.
            shown = text
            settled = animatedValue
        }
        .onChange(of: text) { _ in sync() }
        .onChange(of: animatedValue) { _ in sync() }
        .onDisappear(perform: cancel)
    }

    private func sync() {
        let target = text
        // A brand-new auto-name, and the row is actually showing it rather
        // than a custom name that outranks it.
        let isFreshAutoName = animatedValue != nil
            && animatedValue == target
            && animatedValue != settled
        settled = animatedValue

        // Already typing exactly this — let it finish.
        if typing == target { return }

        guard isFreshAutoName, !reduceMotion, target.count > 1 else {
            cancel()
            shown = target
            return
        }
        start(target)
    }

    private func start(_ target: String) {
        task?.cancel()
        let characters = Array(target)
        let step = min(Self.step, Self.maxDuration / characters.count)
        typing = target
        shown = ""
        task = Task { @MainActor in
            for index in characters.indices {
                if Task.isCancelled { return }
                self.shown = String(characters[...index])
                do { try await Task.sleep(for: step) } catch { return }
            }
            self.typing = nil
            self.task = nil
        }
    }

    private func cancel() {
        task?.cancel()
        task = nil
        typing = nil
    }
}
