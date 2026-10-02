import Foundation

/// OSC 52 (clipboard access from programs): `52;<targets>;<base64 data>` writes, and
/// `52;<targets>;?` asks the terminal to send the clipboard back.
public enum OSC52 {
    /// True for a request to read the clipboard (the data field is `?`).
    public static func isReadRequest(_ payload: ArraySlice<UInt8>) -> Bool {
        guard let separator = payload.lastIndex(of: UInt8(ascii: ";")) else {
            return payload.elementsEqual("?".utf8)
        }
        return payload[payload.index(after: separator)...].elementsEqual("?".utf8)
    }

    /// The text a write request puts on the clipboard (nil for reads and malformed data).
    public static func textToWrite(_ payload: ArraySlice<UInt8>) -> String? {
        guard !isReadRequest(payload) else { return nil }
        let data = payload.lastIndex(of: UInt8(ascii: ";")).map { payload[payload.index(after: $0)...] } ?? payload
        guard let decoded = Data(base64Encoded: Data(data)) else { return nil }
        return String(data: decoded, encoding: .utf8)
    }
}
