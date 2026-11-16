import Foundation
import Darwin

/// Ad-hoc widget mirror under `/Users/Shared/AIPetUsage/<uid>/` — opens with `O_NOFOLLOW`,
/// creates the UID directory via `mkdirat` on a validated root fd, and re-validates directory
/// identity immediately before read/write (TOCTOU hardening).
enum SharedMirrorGate {
    struct InodeIdentity: Equatable, Sendable {
        let dev: dev_t
        let ino: ino_t
    }

    static let fileName = "widget-snapshot.json"

    /// Default shared mirror root — the only root this gate will create or chmod.
    private static let defaultRootPath = "/Users/Shared/AIPetUsage"

    /// Tests may point the mirror at a temp directory (`AIPET_SHARED_MIRROR_ROOT`).
    static var rootPath: String {
        let override = ProcessInfo.processInfo.environment["AIPET_SHARED_MIRROR_ROOT"] ?? ""
        if !override.isEmpty { return override }
        return defaultRootPath
    }

    static func uidDirectoryPath() -> String {
        "\(rootPath)/\(getuid())"
    }

    static func snapshotFilePath() -> String {
        "\(uidDirectoryPath())/\(fileName)"
    }

    // MARK: - Prepare / revalidate

  /// Open root + UID dir without following symlinks; ensure `<uid>/` exists via `mkdirat`.
    static func prepareWriteContext() -> (uidDirPath: String, dirIdentity: InodeIdentity)? {
        guard ensureRootExists() else { return nil }
        guard let rootFD = openDirectoryNoFollow(rootPath) else { return nil }
        defer { close(rootFD) }
        guard validateRootDirectoryFD(rootFD) else { return nil }
        removeLegacyFlatMirrorIfPresent(rootFD: rootFD)
        let uid = "\(getuid())"
        let dirMode: mode_t = 0o700
        if mkdirat(rootFD, uid, dirMode) != 0, errno != EEXIST { return nil }
        let uidFD = openat(rootFD, uid, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard uidFD >= 0 else { return nil }
        defer { close(uidFD) }
        if !validateUIDDirectoryFD(uidFD) {
            var st = stat()
            if fstat(uidFD, &st) == 0, st.st_uid == getuid() {
                _ = fchmod(uidFD, 0o700)
            }
        }
        guard validateUIDDirectoryFD(uidFD),
              let id = inodeIdentity(fd: uidFD) else { return nil }
        return (uidDirectoryPath(), id)
    }

    static func revalidateUIDDirectory(at path: String, expected: InodeIdentity) -> Bool {
        guard path == uidDirectoryPath() || path.hasPrefix(rootPath + "/") else { return false }
        guard let fd = openDirectoryNoFollow(path) else { return false }
        defer { close(fd) }
        guard validateUIDDirectoryFD(fd),
              let id = inodeIdentity(fd: fd),
              id == expected else { return false }
        return true
    }

    // MARK: - I/O

    static func writeSnapshotJSON(_ data: Data, dirPath: String, dirIdentity: InodeIdentity) -> Bool {
        guard revalidateUIDDirectory(at: dirPath, expected: dirIdentity) else { return false }
        guard let dirFD = openDirectoryNoFollow(dirPath) else { return false }
        defer { close(dirFD) }
        guard validateUIDDirectoryFD(dirFD),
              let id = inodeIdentity(fd: dirFD),
              id == dirIdentity else { return false }

        let tmp = ".\(fileName).\(ProcessInfo.processInfo.globallyUniqueString).tmp"
        let wfd = openat(dirFD, tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard wfd >= 0 else { return false }
        let wrote: Bool = data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return false }
            var offset = 0
            var remaining = data.count
            while remaining > 0 {
                let n = write(wfd, base.advanced(by: offset), remaining)
                if n <= 0 { return false }
                offset += n
                remaining -= n
            }
            return true
        }
        guard wrote, fsync(wfd) == 0 else {
            close(wfd)
            _ = unlinkat(dirFD, tmp, 0)
            return false
        }
        close(wfd)
        if renameat(dirFD, tmp, dirFD, fileName) != 0 {
            _ = unlinkat(dirFD, tmp, 0)
            return false
        }
        let outFD = openat(dirFD, fileName, O_RDONLY | O_NOFOLLOW)
        if outFD >= 0 {
            _ = fchmod(outFD, 0o600)
            close(outFD)
        }
        return true
    }

    static func readSnapshotJSON() -> Data? {
        let dirPath = uidDirectoryPath()
        guard let dirFD = openDirectoryNoFollow(dirPath) else { return nil }
        defer { close(dirFD) }
        guard validateUIDDirectoryFD(dirFD) else { return nil }
        let fd = openat(dirFD, fileName, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return nil }
        _ = fcntl(fd, F_SETFL, 0)
        guard st.st_uid == getuid() else { return nil }
        let size = Int(st.st_size)
        guard size >= 0, size <= 4_194_304 else { return nil }
        var data = Data(count: size)
        let ok: Bool = data.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return false }
            var offset = 0
            while offset < size {
                let n = read(fd, base.advanced(by: offset), size - offset)
                if n <= 0 { return false }
                offset += n
            }
            return true
        }
        return ok ? data : nil
    }

    /// Path-level policy checks (used for non-shared mirrors and quick guards).
    static func sharedPathOwnedByCurrentUser(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        guard path == rootPath || path.hasPrefix(rootPath + "/") else { return true }
        if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { return false }
        guard FileManager.default.fileExists(atPath: path) else { return true }
        if path == rootPath {
            guard let fd = openDirectoryNoFollow(path) else { return false }
            defer { close(fd) }
            return validateRootDirectoryFD(fd)
        }
        guard let fd = openDirectoryNoFollow(path) else { return false }
        defer { close(fd) }
        return validateUIDDirectoryFD(fd)
    }

    // MARK: - Darwin helpers

    private static func removeLegacyFlatMirrorIfPresent(rootFD: Int32) {
        var st = stat()
        guard fstatat(rootFD, fileName, &st, 0) == 0 else { return }
        guard (st.st_mode & S_IFMT) == S_IFREG, st.st_uid == getuid() else { return }
        _ = unlinkat(rootFD, fileName, 0)
    }

    private static func ensureRootExists() -> Bool {
        // Overridden roots (`AIPET_SHARED_MIRROR_ROOT`, e.g. tests) are never created or
        // chmod'ed — they must already exist and pass root validation, else skip the mirror.
        guard rootPath == defaultRootPath else {
            guard let fd = openDirectoryNoFollow(rootPath) else { return false }
            defer { close(fd) }
            return validateRootDirectoryFD(fd)
        }
        var st = stat()
        let missing = lstat(rootPath, &st) != 0
        if !missing {
            guard (st.st_mode & S_IFMT) != S_IFLNK else { return false }
        } else {
            guard errno == ENOENT else { return false }
            try? FileManager.default.createDirectory(
                atPath: rootPath,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: 0o1777)]
            )
            guard FileManager.default.fileExists(atPath: rootPath) else { return false }
        }
        guard let fd = openDirectoryNoFollow(rootPath) else { return false }
        defer { close(fd) }
        var fst = stat()
        guard fstat(fd, &fst) == 0 else { return false }
        if fst.st_uid == 0 || fst.st_uid == getuid() {
            _ = fchmod(fd, 0o1777)
        }
        return true
    }

    private static func openDirectoryNoFollow(_ path: String) -> Int32? {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { return nil }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else {
            close(fd)
            return nil
        }
        return fd
    }

    private static func inodeIdentity(fd: Int32) -> InodeIdentity? {
        var st = stat()
        guard fstat(fd, &st) == 0 else { return nil }
        return InodeIdentity(dev: st.st_dev, ino: st.st_ino)
    }

    private static func validateRootDirectoryFD(_ fd: Int32) -> Bool {
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { return false }
        let mode = st.st_mode & 0o7777
        let sticky = (mode & 0o1000) != 0
        let worldWritable = (mode & 0o002) != 0
        guard sticky && worldWritable else { return false }
        // Multi-user: prefer root-owned sticky `/Users/Shared` pattern; allow self-owned for dev installs.
        return st.st_uid == 0 || st.st_uid == getuid()
    }

    private static func validateUIDDirectoryFD(_ fd: Int32) -> Bool {
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { return false }
        guard st.st_uid == getuid() else { return false }
        let mode = st.st_mode & 0o0777
        return mode == 0o700
    }
}