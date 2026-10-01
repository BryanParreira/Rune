import AppIntents
import AppKit
import RuneKit

// Actions for the Shortcuts app (and Spotlight, Siri, and launchers that run shortcuts).
// Everything runs on this Mac.

/// A folder as is; a file stands for the folder it's in.
private func folderPath(_ url: URL) -> String {
    var isDirectory: ObjCBool = false
    FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
    return isDirectory.boolValue ? url.path : url.deletingLastPathComponent().path
}

struct OpenFolderInRuneIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Folder in Rune"
    static let description = IntentDescription("Opens a folder in a new Rune tab.")
    static let openAppWhenRun = true

    @Parameter(title: "Folder")
    var folder: IntentFile

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let path = folder.fileURL.map(folderPath), let app = NSApp.delegate as? AppDelegate else {
            throw RuneIntentError.message("Rune couldn't open that folder.")
        }
        app.openTab(directory: path, command: nil, run: false)
        NSApp.activate()
        return .result()
    }
}

struct TypeCommandInRuneIntent: AppIntent {
    static let title: LocalizedStringResource = "Type Command in Rune"
    static let description = IntentDescription(
        "Opens a new Rune tab with a command typed in its input. It only runs when Run Immediately is on.")
    static let openAppWhenRun = true

    @Parameter(title: "Command")
    var command: String

    @Parameter(title: "Folder")
    var folder: IntentFile?

    @Parameter(title: "Run Immediately", default: false)
    var run: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Type \(\.$command) in Rune") {
            \.$folder
            \.$run
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let app = NSApp.delegate as? AppDelegate else { throw RuneIntentError.message("Rune isn't ready yet.") }
        app.openTab(directory: folder?.fileURL.map(folderPath) ?? NSHomeDirectory(), command: command, run: run)
        NSApp.activate()
        return .result()
    }
}

struct GetLastOutputIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Last Output from Rune"
    static let description = IntentDescription(
        "The output of the last command in the Rune pane you're looking at. Secrets stay hidden if Rune hides them.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard let session = (NSApp.delegate as? AppDelegate)?.frontSession else {
            throw RuneIntentError.message("No Rune window is open.")
        }
        return .result(value: session.latestOutputAsShown())
    }
}

struct SearchRecallIntent: AppIntent {
    static let title: LocalizedStringResource = "Search Rune Recall"
    static let description = IntentDescription(
        "Finds commands you ran (and their output) in Rune Recall, which is stored only on this Mac.")

    @Parameter(title: "Search For")
    var query: String

    @Parameter(title: "Limit", default: 10, inclusiveRange: (1, 100))
    var limit: Int

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[String]> {
        let entries = await withCheckedContinuation { continuation in
            RecallService.shared.search(query, limit: limit) { continuation.resume(returning: $0) }
        }
        return .result(value: entries.map(\.command))
    }
}

enum RuneIntentError: Error, CustomLocalizedStringResourceConvertible {
    case message(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .message(let text): return "\(text)"
        }
    }
}

struct RuneShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: GetLastOutputIntent(), phrases: ["Get last output from \(.applicationName)"],
                    shortTitle: "Last Output", systemImageName: "doc.on.doc")
        AppShortcut(intent: TypeCommandInRuneIntent(), phrases: ["Type a command in \(.applicationName)"],
                    shortTitle: "Type Command", systemImageName: "terminal")
        AppShortcut(intent: SearchRecallIntent(), phrases: ["Search \(.applicationName) Recall"],
                    shortTitle: "Search Recall", systemImageName: "clock.arrow.circlepath")
    }
}
