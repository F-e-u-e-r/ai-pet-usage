import Darwin
import Foundation

/// Optional user-maintained JWT for Cursor dashboard API — **no Keychain in this app**.
/// User pastes a dashboard JWT into the bearer file (or sets `CURSOR_ACCESS_TOKEN`).
public enum CursorBearerFile {
    public static let defaultFileName = "cursor-dashboard-bearer.txt"
    private static let maxBytes = 8192

    /// Bearer **files** with a readable JWT (same rules as `loadAccessToken`), in resolution order — no env var / state DB.
    public static func discoverReadableFilePaths(explicitPath: String?) -> [String] {
        var paths: [String] = []
        func add(_ path: String?) {
            guard let path, !paths.contains(path), readToken(at: path) != nil else { return }
            paths.append(path)
        }
        if let explicit = explicitPath {
            let trimmed = explicit.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, let path = normalizedPath(trimmed) { add(path) }
        }
        if let env = ProcessInfo.processInfo.environment["CURSOR_DASHBOARD_BEARER_FILE"],
           let path = normalizedPath(env) { add(path) }
        add(AppPaths.dataDirectory().appendingPathComponent(defaultFileName).path)
        return paths
    }

    public static func defaultBearerFilePath() -> String {
        AppPaths.dataDirectory().appendingPathComponent(defaultFileName).path
    }

    public static func loadAccessToken(explicitPath: String?) -> String? {
        if let raw = explicitPath {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                guard let path = normalizedPath(trimmed) else { return nil }
                return readToken(at: path)
            }
        }
        if let env = ProcessInfo.processInfo.environment["CURSOR_DASHBOARD_BEARER_FILE"],
           let path = normalizedPath(env), let t = readToken(at: path) { return t }
        let defaultURL = AppPaths.dataDirectory().appendingPathComponent(defaultFileName)
        return readToken(at: defaultURL.path)
    }

    private static func normalizedPath(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: trimmed).standardizedFileURL.path
    }

    private static func readToken(at path: String) -> String? {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return nil }
        let size = Int(st.st_size)
        guard size > 0, size <= maxBytes else { return nil }
        // Prefer owner-only files; still read 0640/0644 if user chose looser perms (their file).
        var data = Data(count: size)
        let ok: Bool = data.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return false }
            var offset = 0
            while offset < size {
                let n = read(fd, base.advanced(by: offset), size - offset)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { return false }
                offset += n
            }
            return true
        }
        guard ok, let text = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("\n"), trimmed.count <= maxBytes else { return nil }
        if trimmed.hasPrefix("cursor-safe-storage:") { return nil }
        return trimmed
    }
}