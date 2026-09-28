import Foundation
import RuneKit

/// The AI conversation shown above a tab's input. ⌘↵ while it's open asks a follow-up;
/// closing it starts fresh. Nothing here ever runs a command; the UI asks the user first.
final class AIConversation: ObservableObject {
    enum State: Equatable {
        case hidden
        /// AI isn't usable yet; the card shows onboarding for the current Ollama status.
        case setup
        case waiting
        case streaming
        case done
        case failed(String)
    }

    struct Exchange: Identifiable, Equatable {
        let id = UUID()
        var prompt: String
        var reply: String
    }

    @Published private(set) var state: State = .hidden
    @Published private(set) var prompt = ""
    @Published private(set) var reply = ""
    @Published private(set) var isThinking = false
    @Published private(set) var model = ""
    /// Label for the attached block, e.g. "make (exit 2)".
    @Published private(set) var contextLabel: String?
    /// Earlier exchanges in this conversation (oldest first).
    @Published private(set) var earlier: [Exchange] = []
    /// Shrunk to a one-line bar so command output has room (e.g. after running a command).
    @Published var isCollapsed = false

    /// Messages sent so far (user turns include the environment summary).
    private var history: [OllamaClient.ChatMessage] = []
    private var pendingUserMessage: OllamaClient.ChatMessage?
    private var task: Task<Void, Never>?

    /// Keep the prompt small enough for local models: the last few exchanges only.
    static let maxRememberedExchanges = 6

    var isActive: Bool { state == .waiting || state == .streaming }
    var isVisible: Bool { state != .hidden }
    /// True when ⌘↵ should continue this conversation rather than start a new one.
    var canFollowUp: Bool {
        switch state {
        case .done, .failed: return !history.isEmpty || !reply.isEmpty
        default: return false
        }
    }

    /// The segments of the current reply, for rendering.
    var segments: [AIPrompt.Segment] { AIPrompt.segments(from: reply) }
    /// First complete command in the current reply (⌘↵ on an empty input runs it).
    var command: String? { AIPrompt.extractCommand(from: reply) }

    func showSetup(prompt: String) {
        cancel()
        self.prompt = prompt
        reply = ""
        state = .setup
    }

    func ask(_ context: AIContext, model: String, client: OllamaClient, disableThinking: Bool,
             contextLabel: String?, followUp: Bool) {
        cancel()
        if followUp {
            if !reply.isEmpty { earlier.append(Exchange(prompt: prompt, reply: reply)) }
        } else {
            history.removeAll()
            earlier.removeAll()
        }
        prompt = context.request
        reply = ""
        isThinking = false
        isCollapsed = false
        self.model = model
        self.contextLabel = contextLabel ?? (followUp ? self.contextLabel : nil)
        state = .waiting

        let messages = AIPrompt.messages(for: context, history: history)
        pendingUserMessage = messages.last

        task = Task { @MainActor [weak self] in
            do {
                for try await event in client.chat(model: model, messages: messages, disableThinking: disableThinking) {
                    guard let self else { return }
                    switch event {
                    case .thinking:
                        self.isThinking = true
                    case .content(let text):
                        self.isThinking = false
                        self.state = .streaming
                        self.reply += text
                    case .done:
                        break
                    }
                }
                guard let self, self.isActive else { return }
                self.finishTurn()
                self.state = .done
            } catch is CancellationError {
                // Stopped by the user.
            } catch {
                guard let self, self.isActive else { return }
                self.state = .failed(Self.describe(error))
            }
        }
    }

    /// Stops generation (Esc) but keeps what arrived so far.
    func stop() {
        guard isActive else { return }
        task?.cancel()
        task = nil
        if reply.isEmpty {
            state = earlier.isEmpty ? .hidden : .done
        } else {
            finishTurn()
            state = .done
        }
    }

    /// Keeps the conversation (for follow-ups) but gets out of the way.
    func collapse() {
        guard isVisible, state != .setup else {
            if state == .setup { dismiss() }
            return
        }
        isCollapsed = true
    }

    func expand() {
        isCollapsed = false
    }

    func dismiss() {
        cancel()
        isCollapsed = false
        history.removeAll()
        earlier.removeAll()
        reply = ""
        state = .hidden
    }

    private func finishTurn() {
        guard let user = pendingUserMessage else { return }
        history.append(user)
        history.append(OllamaClient.ChatMessage(role: "assistant", content: reply))
        let maxMessages = Self.maxRememberedExchanges * 2
        if history.count > maxMessages { history.removeFirst(history.count - maxMessages) }
        pendingUserMessage = nil
    }

    private func cancel() {
        task?.cancel()
        task = nil
    }

    private static func describe(_ error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cannotConnectToHost, .networkConnectionLost, .cannotFindHost, .timedOut:
                return "Couldn't reach Ollama. Is it running?"
            default:
                return urlError.localizedDescription
            }
        }
        return error.localizedDescription
    }
}
