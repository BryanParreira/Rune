import AppKit
import RuneKit

/// Keeps one shell started in the background so new tabs, splits and windows open instantly
/// instead of waiting a second or more for the user's zsh startup files. The spare is only
/// handed out once it has drawn its first prompt; a tab for another folder gets it moved there
/// quietly (see `TerminalSession.moveIdleShell`).
final class SessionPool {
    static let shared = SessionPool()

    private var spare: TerminalSession?
    private var spareKey: StartKey?
    private var refill: DispatchWorkItem?
    /// Size the spare's terminal is laid out at before its shell starts.
    var preferredSize = NSSize(width: 960, height: 580)

    /// Settings that are fixed when a shell starts. A spare started with different values
    /// is thrown away instead of handed out.
    private struct StartKey: Equatable {
        let shell: String?
        let inputMode: InputStyle
        let honorPrompt: Bool
        let scrollback: Int

        init(_ config: RuneConfig) {
            shell = config.shell
            inputMode = config.inputMode
            honorPrompt = config.honorPrompt
            scrollback = config.scrollback
        }
    }

    private init() {}

    /// A ready shell for `directory`, or nil (the caller starts one as usual).
    func take(snapshot: ConfigSnapshot, directory: String) -> TerminalSession? {
        defer { scheduleRefill(snapshot: snapshot) }
        guard let session = spare, spareKey == StartKey(snapshot.config),
              session.state == .running, session.hasPrompted, session.integration == .active
        else {
            discard()
            return nil
        }
        spare = nil
        spareKey = nil
        session.apply(snapshot)
        session.moveIdleShell(to: directory)
        return session
    }

    /// Starts a new spare shortly, once the app is idle again.
    func scheduleRefill(snapshot: ConfigSnapshot) {
        refill?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.fill(snapshot: ConfigStore.current?.snapshot ?? snapshot) }
        refill = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    /// Drops the spare (e.g. after settings that affect new shells changed).
    func discard() {
        spare?.closeContent()
        spare = nil
        spareKey = nil
    }

    private func fill(snapshot: ConfigSnapshot) {
        let key = StartKey(snapshot.config)
        if let spare, spareKey == key, spare.state == .running { return }
        discard()
        let directory = RecentDirectories.shared.paths.first ?? NSHomeDirectory()
        let session = TerminalSession(snapshot: snapshot, directory: directory)
        session.view.frame = NSRect(origin: .zero, size: preferredSize)
        session.view.layoutSubtreeIfNeeded()
        session.start()
        spare = session
        spareKey = key
    }
}
