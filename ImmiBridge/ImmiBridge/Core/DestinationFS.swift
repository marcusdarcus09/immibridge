import Foundation
import CryptoKit

// MARK: - Destination abstraction
//
// The folder export used to talk to its destination straight through
// FileManager, which only works for a local path or a mounted network share.
// Everything that touches the destination now goes through `DestinationFS`,
// so the same export code can write to a NAS over SSH (scheme `ssh://`)
// without the share being mounted. Temp files, the Photos library and the
// manifest database stay local either way.

public func isSSHDestination(_ url: URL) -> Bool {
    url.scheme?.lowercased() == "ssh"
}

/// `ssh://user@host/absolute/path` for a remote destination.
public func makeSSHDestinationURL(target: String, remotePath: String) -> URL? {
    let t = target.trimmingCharacters(in: .whitespacesAndNewlines)
    var p = remotePath.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !t.isEmpty, !p.isEmpty else { return nil }
    if !p.hasPrefix("/") { p = "/" + p }
    while p.count > 1, p.hasSuffix("/") { p.removeLast() }
    var c = URLComponents()
    c.scheme = "ssh"
    if let at = t.lastIndex(of: "@") {
        c.user = String(t[..<at])
        c.host = String(t[t.index(after: at)...])
    } else {
        c.host = t
    }
    c.path = p
    return c.url
}

/// Path of a destination URL, local or remote, with no percent-encoding.
public func destinationPath(_ url: URL) -> String {
    url.isFileURL ? url.standardizedFileURL.path : url.path
}

/// Where the incremental/mirror manifest database lives for a destination.
/// A local folder keeps it inside `.immibridge/` as before; for a NAS over SSH
/// it stays on the Mac (SQLite can't run over an SSH pipe), one file per destination.
public func manifestDatabaseURL(for destination: URL) -> URL {
    if isSSHDestination(destination) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let digest = SHA256.hash(data: Data(destination.absoluteString.utf8))
        let key = digest.map { String(format: "%02x", $0) }.joined().prefix(16)
        return support
            .appendingPathComponent("ImmiBridge/manifests", isDirectory: true)
            .appendingPathComponent("\(key).sqlite", isDirectory: false)
    }
    return destination
        .appendingPathComponent(".immibridge", isDirectory: true)
        .appendingPathComponent("manifest.sqlite", isDirectory: false)
}

public protocol DestinationFS: AnyObject {
    func ensureDir(_ url: URL) throws
    func exists(_ url: URL) -> Bool
    /// Size and modification time (seconds since 1970) of a file, or nil if missing.
    func attributes(_ url: URL) -> (size: Int64, mtime: Double)?
    func sha256(_ url: URL) throws -> (size: UInt64, hashHex: String)
    /// Put a finished local temp file at `dst`. With `copy` the source is left in place.
    /// `src` may also be a file already at the destination (album mirroring).
    func place(_ src: URL, to dst: URL, copy: Bool) throws
    func remove(_ url: URL) throws
}

public func destinationFS(for url: URL) -> DestinationFS {
    isSSHDestination(url) ? SSHDestinationFS.shared(for: url) : LocalDestinationFS.shared
}

// MARK: - Local

public final class LocalDestinationFS: DestinationFS {
    public static let shared = LocalDestinationFS()

    public func ensureDir(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    public func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    public func attributes(_ url: URL) -> (size: Int64, mtime: Double)? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return (size, mtime)
    }

    public func sha256(_ url: URL) throws -> (size: UInt64, hashHex: String) {
        try sha256File(url)
    }

    public func place(_ src: URL, to dst: URL, copy: Bool) throws {
        if copy {
            try FileManager.default.copyItem(at: src, to: dst)
        } else {
            try atomicMove(from: src, to: dst)
        }
    }

    public func remove(_ url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }
}

// MARK: - SSH

public struct SSHError: LocalizedError {
    public let message: String
    public var errorDescription: String? { message }
}

public func shellQuote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// One multiplexed SSH connection per user@host. Every operation is a short
/// command over the shared master connection (tens of milliseconds), and the
/// user's own ~/.ssh key and config are used, so nothing new to set up.
public final class SSHSession: @unchecked Sendable {
    public let target: String          // user@host
    private let controlPath: String
    private let lock = NSLock()
    private var started = false

    private static var sessions: [String: SSHSession] = [:]
    private static let registryLock = NSLock()

    public static func shared(target: String) -> SSHSession {
        registryLock.lock(); defer { registryLock.unlock() }
        if let s = sessions[target] { return s }
        let s = SSHSession(target: target)
        sessions[target] = s
        return s
    }

    private init(target: String) {
        self.target = target
        // Unix sockets are limited to 104 bytes of path, and the per-user temp folder on
        // macOS is far longer than that, so the control socket lives under /tmp instead.
        // %C hashes user/host/port into a short name.
        let dir = URL(fileURLWithPath: "/tmp/immibridge-ssh-\(getuid())", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        self.controlPath = dir.appendingPathComponent("%C").path
    }

    private var baseArgs: [String] {
        [
            "-o", "BatchMode=yes",
            "-o", "ControlMaster=auto",
            "-o", "ControlPath=\(controlPath)",
            "-o", "ControlPersist=600",
            "-o", "ConnectTimeout=15",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=4",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "LogLevel=ERROR",
        ]
    }

    /// Opens the master connection and checks the remote shell answers.
    public func start() throws {
        lock.lock(); defer { lock.unlock() }
        if started { return }
        let r = try runLocked("echo immibridge-ok")
        guard r.status == 0, r.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "immibridge-ok" else {
            throw SSHError(message: "Cannot reach \(target) over SSH: \(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        started = true
    }

    public func stop() {
        lock.lock(); defer { lock.unlock() }
        guard started else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = ["-o", "ControlPath=\(controlPath)", "-O", "exit", target]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
        started = false
    }

    public struct Result {
        public let status: Int32
        public let stdout: String
        public let stderr: String
    }

    /// Runs a shell command on the remote host. `stdinFile` is streamed to its stdin.
    public func run(_ command: String, stdinFile: URL? = nil) throws -> Result {
        lock.lock(); defer { lock.unlock() }
        return try runLocked(command, stdinFile: stdinFile)
    }

    private func runLocked(_ command: String, stdinFile: URL? = nil) throws -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = baseArgs + [target, command]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        var input: FileHandle? = nil
        if let stdinFile {
            guard let fh = FileHandle(forReadingAtPath: stdinFile.path) else {
                throw SSHError(message: "Cannot open \(stdinFile.path) for upload")
            }
            input = fh
            p.standardInput = fh
        } else {
            p.standardInput = FileHandle.nullDevice
        }
        // Every handle opened here is closed before returning. Each export makes
        // several SSH calls, and leaking even two descriptors per call exhausted
        // the process limit ("Too many open files") a few hundred photos in.
        defer {
            try? out.fileHandleForReading.close()
            try? err.fileHandleForReading.close()
            try? input?.close()
        }
        try p.run()
        // The parent's copies of the write ends must go, or EOF never arrives once ssh exits.
        try? out.fileHandleForWriting.close()
        try? err.fileHandleForWriting.close()
        // Drain both pipes before waiting, or a chatty command can deadlock.
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return Result(
            status: p.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self)
        )
    }

    /// Quick reachability check used by the "Test" button: makes the folder and confirms it is writable.
    public func probe(remotePath: String) -> String {
        let q = shellQuote(remotePath)
        guard let r = try? run("mkdir -p \(q) && test -w \(q) && echo writable") else {
            return "ssh could not be started"
        }
        if r.status == 0, r.stdout.contains("writable") { return "Connected, folder is writable" }
        let e = r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if e.isEmpty { return "Folder is not writable on \(target)" }
        return e
    }
}

public final class SSHDestinationFS: DestinationFS {
    private let session: SSHSession
    private let basePath: String
    private let lock = NSLock()
    /// Snapshot of every file under the destination, taken once per run on first use,
    /// so incremental runs don't pay a round trip per photo just to ask "is it there?".
    private var fileCache: [String: (size: Int64, mtime: Double)]? = nil
    private var knownDirs: Set<String> = []

    private static var instances: [String: SSHDestinationFS] = [:]
    private static let registryLock = NSLock()

    static func shared(for url: URL) -> SSHDestinationFS {
        let target = (url.user.map { $0 + "@" } ?? "") + (url.host ?? "")
        let base = url.path
        let key = target + ":" + base
        registryLock.lock(); defer { registryLock.unlock() }
        if let i = instances[key] { return i }
        let i = SSHDestinationFS(session: SSHSession.shared(target: target), basePath: base)
        instances[key] = i
        return i
    }

    private init(session: SSHSession, basePath: String) {
        self.session = session
        self.basePath = basePath
    }

    public var sshSession: SSHSession { session }

    /// Forget the cached listing (start of each run).
    public func resetCache() {
        lock.lock(); defer { lock.unlock() }
        fileCache = nil
        knownDirs = []
    }

    private func path(_ url: URL) -> String { url.path }

    private func loadCacheLocked() {
        if fileCache != nil { return }
        var cache: [String: (size: Int64, mtime: Double)] = [:]
        // GNU stat is on the NAS; BusyBox find has no -printf, so stat does the printing.
        let cmd = "test -d \(shellQuote(basePath)) && find \(shellQuote(basePath)) -type f -exec stat -c '%s %Y %n' {} +"
        if let r = try? session.run(cmd), r.status == 0 {
            for line in r.stdout.split(separator: "\n") {
                let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
                guard parts.count == 3, let size = Int64(parts[0]), let mtime = Double(parts[1]) else { continue }
                cache[String(parts[2])] = (size, mtime)
            }
        }
        fileCache = cache
    }

    public func ensureDir(_ url: URL) throws {
        let p = path(url)
        lock.lock(); defer { lock.unlock() }
        if knownDirs.contains(p) { return }
        let r = try session.run("mkdir -p \(shellQuote(p))")
        guard r.status == 0 else { throw SSHError(message: "mkdir failed for \(p): \(r.stderr)") }
        knownDirs.insert(p)
    }

    public func exists(_ url: URL) -> Bool {
        let p = path(url)
        lock.lock(); defer { lock.unlock() }
        if p.hasPrefix(basePath + "/") {
            loadCacheLocked()
            return fileCache?[p] != nil
        }
        guard let r = try? session.run("test -e \(shellQuote(p))") else { return false }
        return r.status == 0
    }

    public func attributes(_ url: URL) -> (size: Int64, mtime: Double)? {
        let p = path(url)
        lock.lock(); defer { lock.unlock() }
        if p.hasPrefix(basePath + "/") {
            loadCacheLocked()
            if let hit = fileCache?[p] { return hit }
        }
        guard let r = try? session.run("stat -c '%s %Y' \(shellQuote(p))"), r.status == 0 else { return nil }
        let parts = r.stdout.split(separator: " ")
        guard parts.count == 2, let size = Int64(parts[0]), let mtime = Double(parts[1].trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return (size, mtime)
    }

    public func sha256(_ url: URL) throws -> (size: UInt64, hashHex: String) {
        let p = path(url)
        let r = try session.run("stat -c %s \(shellQuote(p)) && sha256sum \(shellQuote(p))")
        guard r.status == 0 else { throw SSHError(message: "Cannot hash \(p): \(r.stderr)") }
        let lines = r.stdout.split(separator: "\n")
        guard lines.count >= 2, let size = UInt64(lines[0].trimmingCharacters(in: .whitespaces)),
              let hash = lines[1].split(separator: " ").first, hash.count == 64 else {
            throw SSHError(message: "Unexpected hash output for \(p)")
        }
        return (size, String(hash))
    }

    public func place(_ src: URL, to dst: URL, copy: Bool) throws {
        let d = path(dst)
        let tmp = d + ".immibridge-partial"
        if isSSHDestination(src) {
            // Album mirroring: copy a file that is already on the NAS.
            let s = path(src)
            let r = try session.run("cp -p \(shellQuote(s)) \(shellQuote(tmp)) && mv -f \(shellQuote(tmp)) \(shellQuote(d)) && stat -c '%s %Y' \(shellQuote(d))")
            guard r.status == 0 else { throw SSHError(message: "Remote copy failed for \(d): \(r.stderr)") }
            noteWritten(d, statLine: r.stdout)
            return
        }
        guard let localAttrs = try? FileManager.default.attributesOfItem(atPath: src.path),
              let localSize = (localAttrs[.size] as? NSNumber)?.int64Value else {
            throw SSHError(message: "Cannot read \(src.path)")
        }
        // Stream the file through ssh, land it under a temporary name, rename when complete,
        // and read back the size so a short transfer is caught before it is trusted.
        let mtime = Int((localAttrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? Date().timeIntervalSince1970)
        let cmd = "cat > \(shellQuote(tmp)) && touch -d @\(mtime) \(shellQuote(tmp)) 2>/dev/null; mv -f \(shellQuote(tmp)) \(shellQuote(d)) && stat -c '%s %Y' \(shellQuote(d))"
        let r = try session.run(cmd, stdinFile: src)
        guard r.status == 0 else {
            _ = try? session.run("rm -f \(shellQuote(tmp))")
            throw SSHError(message: "Upload failed for \(d): \(r.stderr)")
        }
        let remoteSize = Int64(r.stdout.split(separator: " ").first.map(String.init) ?? "") ?? -1
        guard remoteSize == localSize else {
            _ = try? session.run("rm -f \(shellQuote(d))")
            throw SSHError(message: "Upload of \(d) is incomplete (\(remoteSize) of \(localSize) bytes)")
        }
        noteWritten(d, statLine: r.stdout)
        if !copy {
            try? FileManager.default.removeItem(at: src)
        }
    }

    private func noteWritten(_ p: String, statLine: String) {
        let parts = statLine.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
        lock.lock(); defer { lock.unlock() }
        if fileCache != nil, parts.count == 2, let size = Int64(parts[0]), let mtime = Double(parts[1]) {
            fileCache?[p] = (size, mtime)
        }
    }

    public func remove(_ url: URL) throws {
        let p = path(url)
        let r = try session.run("rm -f \(shellQuote(p))")
        guard r.status == 0 else { throw SSHError(message: "Delete failed for \(p): \(r.stderr)") }
        lock.lock(); defer { lock.unlock() }
        fileCache?[p] = nil
    }
}
