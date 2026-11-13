import AppKit

/// Optional root helper that lets the app see CPU, memory and disk use of system processes.
/// It is a small launchd daemon, started on demand through a socket, that answers one
/// read-only request ("snapshot") and exits after 30 s without requests.
enum RootHelper {
    static let label = "local.MacMonIndicator.helper"
    static let helperPath = "/Library/PrivilegedHelperTools/\(label)"
    static let plistPath = "/Library/LaunchDaemons/\(label).plist"
    static let defaultSocket = "/var/run/\(label).sock"
    /// For testing the helper without installing it.
    static var socketPath: String { ProcessInfo.processInfo.environment["MACMON_INDICATOR_HELPER_SOCKET"] ?? defaultSocket }

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: plistPath) && FileManager.default.fileExists(atPath: helperPath)
    }

    private static func shq(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    private static func runAsAdmin(_ command: String) -> String? {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        var err: NSDictionary?
        NSAppleScript(source: "do shell script \"\(escaped)\" with administrator privileges")?.executeAndReturnError(&err)
        guard let err else { return nil }
        if (err[NSAppleScript.errorNumber] as? Int) == -128 { return "Cancelled." }
        return err[NSAppleScript.errorMessage] as? String ?? "Unknown error."
    }

    /// Installs the helper. Shows the macOS admin password prompt. Returns an error message on failure.
    static func install() -> String? {
        guard let src = Bundle.main.url(forAuxiliaryExecutable: "macmon-indicator-helper")?.path else {
            return "Helper binary is missing from the app bundle. Rebuild with `make app`."
        }
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\
        <plist version="1.0"><dict><key>Label</key><string>\(label)</string>\
        <key>ProgramArguments</key><array><string>\(helperPath)</string><string>--uid</string><string>\(getuid())</string></array>\
        <key>Sockets</key><dict><key>Listener</key><dict><key>SockPathName</key><string>\(defaultSocket)</string>\
        <key>SockPathMode</key><integer>438</integer></dict></dict></dict></plist>
        """
        let cmd = [
            "/bin/mkdir -p /Library/PrivilegedHelperTools",
            "(/bin/launchctl bootout system/\(label) 2>/dev/null; true)",
            "/usr/bin/install -o root -g wheel -m 755 \(shq(src)) \(shq(helperPath))",
            "/usr/bin/printf '%s' \(shq(plist)) > \(shq(plistPath))",
            "/usr/sbin/chown root:wheel \(shq(plistPath))",
            "/bin/chmod 644 \(shq(plistPath))",
            "/bin/launchctl bootstrap system \(shq(plistPath))",
        ].joined(separator: " && ")
        return runAsAdmin(cmd)
    }

    /// Removes the helper. Shows the macOS admin password prompt.
    static func uninstall() -> String? {
        let cmd = "(/bin/launchctl bootout system/\(label) 2>/dev/null; true) && /bin/rm -f \(shq(plistPath)) \(shq(helperPath)) \(shq(defaultSocket))"
        return runAsAdmin(cmd)
    }

    struct Process {
        var name: String
        var cpuNs: UInt64
        var kernelNs: UInt64?
        var mem: Double
        var diskRead: UInt64
        var diskWritten: UInt64
        var disk: UInt64? { diskRead &+ diskWritten }
        // Version 3 and later:
        var startUs: UInt64?      // start time, microseconds since 1970
        var energyNj: UInt64?     // CPU energy used so far
        var pcoreNs: UInt64?      // CPU time on performance cores
        var maxMem: Double?       // highest memory footprint over its life
        var path: String?
    }

    /// The helper version this app ships; an installed one below it lacks some columns.
    static let currentVersion = 3

    /// Asks the helper for a snapshot of all processes. Returns nil if it is not reachable.
    /// Version 1 (an older installed helper) has no kernel time; versions 1 and 2 have no start
    /// time, energy, P-core time, peak memory or path.
    static func snapshot() -> (version: Int, processes: [pid_t: Process])? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var tv = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = Array(socketPath.utf8)
        guard path.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: path) }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard rc == 0 else { return nil }
        let req = Array("snapshot\n".utf8)
        guard write(fd, req, req.count) == req.count else { return nil }

        var data = Data()
        var buf = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            data.append(buf, count: n)
        }
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let version = text.hasPrefix("v3\n") ? 3 : text.hasPrefix("v2\n") ? 2 : text.hasPrefix("v1\n") ? 1 : 0
        guard version > 0 else { return nil }
        // v3: pid \t cpu_ns \t kernel_ns \t footprint \t disk_read \t disk_write \t start_us \t energy_nj \t
        //     pcore_ns \t max_footprint \t name \t path
        // v2: pid \t cpu_ns \t kernel_ns \t footprint \t disk_read \t disk_write \t name
        // v1: the same without kernel_ns
        let n = [1: 6, 2: 7, 3: 12][version]!, k = version >= 2 ? 1 : 0
        var out: [pid_t: Process] = [:]
        for line in text.split(separator: "\n").dropFirst() {
            let f = line.split(separator: "\t", maxSplits: n - 1, omittingEmptySubsequences: false)
            guard f.count == n, let pid = pid_t(f[0]), let cpu = UInt64(f[1]), let mem = Double(f[2 + k]),
                  let r = UInt64(f[3 + k]), let w = UInt64(f[4 + k]) else { continue }
            var p = Process(name: String(f[version == 3 ? 10 : 5 + k]), cpuNs: cpu, kernelNs: k == 1 ? UInt64(f[2]) : nil,
                            mem: mem, diskRead: r, diskWritten: w)
            if version >= 3 {
                p.startUs = UInt64(f[6]).flatMap { $0 > 0 ? $0 : nil }
                p.energyNj = UInt64(f[7])
                p.pcoreNs = UInt64(f[8])
                p.maxMem = Double(f[9])
                p.path = f[11].isEmpty ? nil : String(f[11])
            }
            out[pid] = p
        }
        return (version, out)
    }
}
