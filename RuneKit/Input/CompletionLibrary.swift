import Foundation

/// Completion specs for hundreds of command-line tools, converted from Fig's open-source
/// specs (see scripts/import-fig-specs.mjs): subcommands, flags, descriptions and fixed
/// argument values. Rune's own specs (`CommandSpecs`) come first; these fill in the rest.
/// Loaded once in the background; until then only Rune's own specs answer.
public final class CompletionLibrary: @unchecked Sendable {
    public static let shared = CompletionLibrary()

    private let lock = NSLock()
    /// Command name → its JSON node, until first asked for.
    private var raw: [String: Any] = [:]
    private var converted: [String: CommandSpec] = [:]
    public private(set) var isLoaded = false

    public init() {}

    /// Reads the bundled (raw-DEFLATE compressed JSON) file. Safe to call from any thread.
    public func load(contentsOf url: URL) {
        guard let compressed = try? Data(contentsOf: url),
              let json = try? (compressed as NSData).decompressed(using: .zlib) as Data else { return }
        load(json: json)
    }

    public func load(json: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else { return }
        lock.lock()
        raw = object
        converted.removeAll()
        isLoaded = true
        lock.unlock()
    }

    public var commandCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return raw.count
    }

    /// The spec for a command, if the library has one.
    public func spec(named name: String) -> CommandSpec? {
        lock.lock()
        defer { lock.unlock() }
        if let spec = converted[name] { return spec }
        guard let node = raw[name] as? [String: Any] else { return nil }
        let spec = Self.convert(node, fallbackName: name)
        converted[name] = spec
        return spec
    }

    /// `{n: [names], d: description, s: [subcommands], o: [[[names], description]], a: "f"|"d"|[values]}`
    static func convert(_ node: [String: Any], fallbackName: String) -> CommandSpec {
        let names = node["n"] as? [String] ?? [fallbackName]
        var spec = CommandSpec(name: names.first ?? fallbackName)
        spec.aliases = Array(names.dropFirst())
        spec.description = node["d"] as? String
        if let subcommands = node["s"] as? [[String: Any]] {
            spec.subcommands = subcommands.map { convert($0, fallbackName: "") }.filter { !$0.name.isEmpty }
        }
        if let options = node["o"] as? [[Any]] {
            for option in options {
                guard let optionNames = option.first as? [String] else { continue }
                let description = option.count > 1 ? option[1] as? String ?? "" : ""
                spec.flags += optionNames.map { CommandSpec.Flag(name: $0, description: description) }
            }
        }
        // Files and folders ("f", "d") are left to path completion; fixed values are offered.
        if let values = node["a"] as? [String], !values.isEmpty {
            spec.values = { _, _ in values }
        }
        return spec
    }
}
