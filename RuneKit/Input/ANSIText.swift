import Foundation

/// Plain text from program output captured without a terminal.
public enum ANSIText {
    private static let escapes = try? NSRegularExpression(
        pattern: #"\x1B\[[0-?]*[ -/]*[@-~]|\x1B\][^\x07\x1B]*(?:\x07|\x1B\\)|\x1B[@-Z\\-_]"#)

    /// Removes color and cursor escape sequences, and keeps what a terminal would finally show
    /// on lines redrawn with carriage returns (progress bars).
    public static func plain(_ text: String) -> String {
        var result = text
        if let escapes {
            result = escapes.stringByReplacingMatches(in: result, range: NSRange(location: 0, length: (result as NSString).length), withTemplate: "")
        }
        result = result.replacingOccurrences(of: "\r\n", with: "\n")
        return result.components(separatedBy: "\n").map { line in
            guard line.contains("\r") else { return line }
            return line.components(separatedBy: "\r").last { !$0.isEmpty } ?? ""
        }.joined(separator: "\n")
    }
}
