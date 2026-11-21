import Darwin
import Foundation

// Owner: core agent. libproc and termios helpers.

enum ProcessInspector {
    /// Current working directory of a pid (proc_pidinfo PROC_PIDVNODEPATHINFO), nil on failure.
    static func currentDirectory(of pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { raw -> String in
            let bytes = raw.bindMemory(to: UInt8.self)
            let length = bytes.firstIndex(of: 0) ?? bytes.count
            return String(decoding: bytes[..<length], as: UTF8.self)
        }
        return path.isEmpty ? nil : path
    }

    /// Foreground process group of the pty master fd (tcgetpgrp), nil on failure.
    static func foregroundProcessGroup(ptyFD: Int32) -> pid_t? {
        guard ptyFD >= 0 else { return nil }
        let group = tcgetpgrp(ptyFD)
        return group > 0 ? group : nil
    }

    /// Symlink-free absolute path (realpath), nil when it does not exist. Unlike Foundation's
    /// resolvingSymlinksInPath it keeps the /private prefix, which is what libproc and Claude Code report.
    static func physicalPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Short process name (proc_name), nil on failure.
    static func processName(of pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(MAXCOMLEN) * 2 + 1)
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        let name = String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        if name.isEmpty { return nil }
        // The native Claude Code install runs a binary named after its version (~/.local/share/claude/versions/2.1.329).
        if name.allSatisfy({ $0.isNumber || $0 == "." }) && name.contains(".") { return "claude" }
        return name
    }
}
