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

    /// Rune Agent: working toward `goal` one approved command at a time.
    struct Agent: Equatable {
        var goal: String
        /// Steps whose commands have run.
        var step = 0
        /// The command the user approved and that's running now.
        var runningCommand: String?
    }
    @Published private(set) var agent: Agent?
    var isAgent: Bool { agent != nil }
    /// The current reply read as an agent step.
    var agentStep: AgentPrompt.Step? { isAgent && state == .done ? AgentPrompt.step(from: reply) : nil }
    /// The model and client in use, for the agent's next turns.
    private var session: (model: String, client: OllamaClient, disableThinking: Bool)?

    /// Messages sent so far (user turns include the environment summary).
    private var history: [OllamaClient.ChatMessage] = []
    /// Tokens received but not yet shown; flushed to `reply` ~20 times a second so long
    /// answers don't re-render (and re-parse Markdown) on every token.
    private var pendingText = ""
    private var flushScheduled = false
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
        // A question ends agent mode; its conversation stays for follow-ups.
        agent = nil
        stream(messages: AIPrompt.messages(for: context, history: followUp ? history : []), prompt: context.request,
               model: model, client: client, disableThinking: disableThinking, contextLabel: contextLabel, followUp: followUp)
    }

    // MARK: Agent

    func startAgent(_ context: AIContext, model: String, client: OllamaClient, disableThinking: Bool, contextLabel: String?) {
        let messages = AIPrompt.messages(system: AgentPrompt.systemPrompt, history: [], user: AgentPrompt.goalMessage(for: context))
        stream(messages: messages, prompt: context.request, model: model, client: client,
               disableThinking: disableThinking, contextLabel: contextLabel, followUp: false)
        agent = Agent(goal: context.request)
    }

    /// The user approved the proposed command; its result is expected next.
    func agentWillRun(_ command: String) {
        agent?.runningCommand = command
        agent?.step += 1
    }

    /// The approved command finished: send its result for the next step.
    func agentStepFinished(output: String, exitCode: Int32?) {
        guard let current = agent, let command = current.runningCommand else { return }
        agent?.runningCommand = nil
        let message = AgentPrompt.resultMessage(goal: current.goal, command: command, exitCode: exitCode,
                                                output: output, step: current.step)
        continueAgent(with: message, label: "Step \(current.step) · \(command)")
    }

    /// The user skipped the proposed command.
    func agentSkip(_ command: String) {
        guard let current = agent else { return }
        continueAgent(with: AgentPrompt.skippedMessage(goal: current.goal, command: command), label: "Skipped · \(command)")
    }

    func stopAgent() {
        stop()
        agent = nil
    }

    private func continueAgent(with message: String, label: String) {
        guard let current = agent, let session else { return }
        let messages = AIPrompt.messages(system: AgentPrompt.systemPrompt, history: history, user: message)
        stream(messages: messages, prompt: current.goal, model: session.model, client: session.client,
               disableThinking: session.disableThinking, contextLabel: label, followUp: true)
        agent = current
    }

    private func stream(messages: [OllamaClient.ChatMessage], prompt newPrompt: String, model: String, client: OllamaClient,
                        disableThinking: Bool, contextLabel: String?, followUp: Bool) {
        cancel()
        session = (model, client, disableThinking)
        if followUp {
            if !reply.isEmpty { earlier.append(Exchange(prompt: prompt, reply: reply)) }
        } else {
            history.removeAll()
            earlier.removeAll()
        }
        prompt = newPrompt
        reply = ""
        isThinking = false
        isCollapsed = false
        self.model = model
        self.contextLabel = contextLabel ?? (followUp ? self.contextLabel : nil)
        state = .waiting

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
                        if self.state != .streaming { self.state = .streaming }
                        self.pendingText += text
                        self.scheduleFlush()
                    case .done:
                        break
                    }
                }
                guard let self, self.isActive else { return }
                self.flushPending()
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

    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.flushPending()
        }
    }

    private func flushPending() {
        flushScheduled = false
        guard !pendingText.isEmpty else { return }
        reply += pendingText
        pendingText = ""
    }

    /// Stops generation (Esc) but keeps what arrived so far.
    func stop() {
        guard isActive else { return }
        task?.cancel()
        task = nil
        flushPending()
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
        agent = nil
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
        pendingText = ""
        flushScheduled = false
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
