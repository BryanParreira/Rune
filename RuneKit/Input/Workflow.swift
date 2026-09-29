import Foundation

/// A saved command, run from the command palette. `{{name}}` marks an argument to fill in:
/// the editor selects each placeholder in turn (Tab moves to the next one). Only plain names
/// count, so template syntax like `docker ps --format '{{.Names}}'` is left alone.
public struct Workflow: Equatable, Sendable, Identifiable {
    public var name: String
    public var command: String
    public var description: String?

    public var id: String { name + "\u{0}" + command }

    public init(name: String, command: String, description: String? = nil) {
        self.name = name
        self.command = command
        self.description = description
    }

    /// Ranges (UTF-16) of every `{{placeholder}}` in `text`, in order.
    public static func placeholderRanges(in text: String) -> [NSRange] {
        guard let regex = try? NSRegularExpression(pattern: #"\{\{\s*[A-Za-z_][A-Za-z0-9_ -]*\}\}"#) else { return [] }
        return regex.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)).map(\.range)
    }

    /// The first placeholder at or after `location`, wrapping around to the first one.
    public static func nextPlaceholder(in text: String, from location: Int) -> NSRange? {
        let ranges = placeholderRanges(in: text)
        return ranges.first { $0.location >= location } ?? ranges.first
    }

    /// Parses config.json's `workflows` array. Invalid entries are skipped with a warning.
    static func parse(_ raw: Any, warnings: inout [String]) -> [Workflow] {
        guard let items = raw as? [Any] else {
            warnings.append("workflows should be a list of {\"name\", \"command\"} objects; ignoring it")
            return []
        }
        var result: [Workflow] = []
        for (index, item) in items.enumerated() {
            guard let object = item as? [String: Any],
                  let command = (object["command"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !command.isEmpty
            else {
                warnings.append("workflows[\(index)] needs a \"command\"; skipped")
                continue
            }
            let name = (object["name"] as? String)?.trimmingCharacters(in: .whitespaces)
            let description = (object["description"] as? String)?.trimmingCharacters(in: .whitespaces)
            result.append(Workflow(name: name?.isEmpty == false ? name ?? command : command,
                                   command: command,
                                   description: description?.isEmpty == false ? description : nil))
        }
        return result
    }

    /// The JSON object written back to config.json.
    public var jsonObject: [String: Any] {
        var object: [String: Any] = ["name": name, "command": command]
        if let description { object["description"] = description }
        return object
    }
}
