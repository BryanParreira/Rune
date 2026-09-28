import Foundation
import SystemConfiguration

/// Names for the current machine and user, discovered at runtime.
public enum HostIdentity {
    /// Full hostname from gethostname(3). On macOS this often reflects the current
    /// network (e.g. a DHCP-assigned name), so it isn't stable across networks.
    public static func networkHostname() -> String {
        var buffer = [CChar](repeating: 0, count: Int(MAXHOSTNAMELEN) + 1)
        guard gethostname(&buffer, buffer.count - 1) == 0 else { return "localhost" }
        let name = String(cString: buffer)
        return name.isEmpty ? "localhost" : name
    }

    /// The machine's stable Bonjour name from System Settings → Sharing
    /// (e.g. "Studio" / "Alexs-MacBook-Pro"), independent of the network.
    public static func localHostName() -> String? {
        guard let name = SCDynamicStoreCopyLocalHostName(nil) as String?, !name.isEmpty else { return nil }
        return name
    }

    /// Hostname without domain, e.g. "studio".
    public static func shortHostname(_ full: String) -> String {
        full.split(separator: ".", maxSplits: 1).first.map(String.init) ?? full
    }

    /// Name shown in tab titles.
    public static func displayHostname() -> String {
        localHostName() ?? shortHostname(networkHostname())
    }

    /// Names used to match `hosts` entries in config, lowest priority first, so a more
    /// specific entry overrides a more general one. The stable local host name wins.
    public static func configMatchNames(network: String = networkHostname(), local: String? = localHostName()) -> [String] {
        var names: [String] = []
        for name in [shortHostname(network), network, local].compactMap({ $0 }) where !names.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            names.append(name)
        }
        return names
    }

    public static func userName(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let user = environment["USER"], !user.isEmpty { return user }
        return NSUserName()
    }
}
