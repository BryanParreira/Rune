import Darwin
import Foundation

/// Reads live information about a child process from the kernel.
public enum ProcessInfoReader {
    /// Current working directory of `pid`, or nil if it can't be read (process gone, no permission).
    public static func currentDirectory(of pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        let result = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size)
        guard result == size else { return nil }
        let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { raw -> String in
            let bytes = raw.bindMemory(to: CChar.self)
            guard let base = bytes.baseAddress else { return "" }
            return String(cString: base)
        }
        return path.isEmpty ? nil : path
    }
}

/// Formats "user@host:~/path" tab titles.
public enum TabTitle {
    public static func abbreviate(path: String, home: String) -> String {
        let trimmedHome = home.hasSuffix("/") && home.count > 1 ? String(home.dropLast()) : home
        if path == trimmedHome { return "~" }
        if !trimmedHome.isEmpty, path.hasPrefix(trimmedHome + "/") {
            return "~" + path.dropFirst(trimmedHome.count)
        }
        return path
    }

    public static func make(user: String, host: String, path: String, home: String) -> String {
        "\(user)@\(host):\(abbreviate(path: path, home: home))"
    }

    /// Converts an OSC 7 payload ("file://host/path" or a bare path) into a path.
    public static func pathFromOSC7(_ value: String) -> String? {
        if value.hasPrefix("/") { return value }
        guard let url = URL(string: value), url.isFileURL else { return nil }
        let path = url.path
        return path.isEmpty ? nil : path
    }
}
