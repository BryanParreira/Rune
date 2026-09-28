import Foundation
import RuneKit

/// One AI exchange shown above a tab's input: the question, the streamed answer, and the
/// suggested command. Nothing here ever runs a command; the UI asks the user first.
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

    @Published private(set) var state: State = .hidden
    @Published private(set) var prompt = ""
    @Published private(set) var reply = ""
    @Published private(set) var isThinking = false
    @Published private(set) var model = ""
    @Published private(set) var command: String?
    /// Label for the attached block, e.g. "make (exit 2)".
    @Published private(set) var contextLabel: String?

    private var task: Task<Void, Never>?

    var isActive: Bool { state == .waiting || state == .streaming }
    var isVisible: Bool { state != .hidden }

    func showSetup(prompt: String) {
        cancel()
        self.prompt = prompt
        reply = ""
        command = nil
        state = .setup
    }

    func ask(_ context: AIContext, model: String, client: OllamaClient, disableThinking: Bool, contextLabel: String?) {
        cancel()
        prompt = context.request
        reply = ""
        command = nil
        isThinking = false
        self.model = model
        self.contextLabel = contextLabel
        state = .waiting
        let messages = AIPrompt.messages(for: context)

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
                        self.command = AIPrompt.extractCommand(from: self.reply)
                    case .done:
                        break
                    }
                }
                guard let self, self.isActive else { return }
                self.state = .done
                self.command = AIPrompt.extractCommand(from: self.reply)
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
        state = reply.isEmpty ? .hidden : .done
        command = AIPrompt.extractCommand(from: reply)
    }

    func dismiss() {
        cancel()
        state = .hidden
    }

    private func cancel() {
        task?.cancel()
        task = nil
    }

    /// Reply text without the fenced command (shown separately as a card).
    var explanation: String {
        var lines: [String] = []
        var inFence = false
        for line in reply.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                inFence.toggle()
                continue
            }
            if !inFence { lines.append(line) }
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
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
