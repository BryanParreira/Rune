import Foundation

/// Whether Rune's shell integration is talking to us.
public enum IntegrationState: Equatable, Sendable {
    /// Shell is starting; we don't know yet.
    case pending
    /// Marks are arriving.
    case active
    /// Not zsh, or the integration never reported in. Rune behaves as a plain terminal.
    case unavailable
}

/// Where keystrokes go and what the input area looks like.
public enum InputMode: Equatable, Sendable {
    /// The input editor owns the keyboard (shell is idle at a prompt, or still starting).
    case editor
    /// A command is running: keystrokes go to the PTY; the editor is shown dimmed.
    case runningCommand
    /// A full-screen app (vim, htop, less) is on the alternate screen: editor hidden.
    case fullscreenApp
    /// No integration: behave like a classic terminal, editor hidden.
    case plainTerminal

    public var editorVisible: Bool { self == .editor || self == .runningCommand }
    public var keystrokesToTerminal: Bool { self != .editor }
}

public enum InputRouter {
    public static func mode(integration: IntegrationState, alternateScreen: Bool, commandRunning: Bool) -> InputMode {
        if alternateScreen { return .fullscreenApp }
        switch integration {
        case .unavailable: return .plainTerminal
        case .pending: return .editor
        case .active: return commandRunning ? .runningCommand : .editor
        }
    }
}
