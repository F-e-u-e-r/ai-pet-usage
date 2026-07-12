import Foundation

/// 應用資料目錄與原子化 JSON 讀寫。所有狀態都存在本機 Application Support,絕不外傳。
public enum AppPaths {
    public static let appFolderName = "AIPetUsage"

    public static func dataDirectory() -> URL {
        // 測試/驗證縫:允許以環境變數指向隔離的資料目錄(系統路徑走 getpwuid,
        // 不吃 $HOME),避免對照實驗誤寫正式狀態。
        if let override = ProcessInfo.processInfo.environment["AIPET_DATA_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent(appFolderName, isDirectory: true)
    }

    public static func ensureDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}

public enum JSONCodecError: Error {
    case notADictionary
}

public enum AtomicJSON {
    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }

    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    /// 寫入暫存檔後原子替換,避免中途崩潰留下半份設定。
    public static func write<T: Encodable>(_ value: T, to url: URL) throws {
        try AppPaths.ensureDirectory(url.deletingLastPathComponent())
        let data = try encoder().encode(value)
        try data.write(to: url, options: .atomic)
    }

    public static func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder().decode(type, from: data)
    }
}

// MARK: - 跨行程互斥鎖(flock)

/// App 與 CLI 共用同一份本機資料;任何「刷新/重建索引」的寫入階段都必須持有此鎖,
/// 避免兩個行程交錯附加帳本或互相覆蓋掃描進度。
public final class FileLock {
    private let url: URL
    private var fd: Int32 = -1

    public init(url: URL) {
        self.url = url
    }

    /// 在 `timeout` 秒內嘗試取得互斥鎖;0 表示只試一次。
    public func acquire(timeout: TimeInterval) -> Bool {
        if fd < 0 {
            try? AppPaths.ensureDirectory(url.deletingLastPathComponent())
            fd = open(url.path, O_CREAT | O_RDWR, 0o644)
            guard fd >= 0 else { return false }
        }
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 { return true }
            usleep(100_000)
        } while Date() < deadline
        return false
    }

    /// 在 `timeout` 秒內嘗試取得互斥鎖;等待期間讓出 Swift concurrency 執行緒。
    public func acquireAsync(timeout: TimeInterval) async -> Bool {
        if fd < 0 {
            try? AppPaths.ensureDirectory(url.deletingLastPathComponent())
            fd = open(url.path, O_CREAT | O_RDWR, 0o644)
            guard fd >= 0 else { return false }
        }
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 { return true }
            do {
                try await Task.sleep(nanoseconds: 100_000_000)
            } catch {
                return false
            }
        } while Date() < deadline
        return false
    }

    public func release() {
        guard fd >= 0 else { return }
        flock(fd, LOCK_UN)
    }

    deinit {
        if fd >= 0 {
            flock(fd, LOCK_UN)
            close(fd)
        }
    }
}

// MARK: - 使用者本地時間格式(UI/報告/CLI 的人讀時間戳)

public enum LocalTime {
    /// `yyyy-MM-dd HH:mm:ss (UTC+8)`;半時區顯示 `UTC+5:30`。timeZone 參數化供測試注入。
    public static func format(_ date: Date, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let seconds = timeZone.secondsFromGMT(for: date)
        let sign = seconds < 0 ? "-" : "+"
        let absSeconds = abs(seconds)
        let hours = absSeconds / 3600
        let minutes = (absSeconds % 3600) / 60
        let offset = minutes == 0 ? "UTC\(sign)\(hours)" : String(format: "UTC%@%d:%02d", sign, hours, minutes)
        return "\(f.string(from: date)) (\(offset))"
    }
}

// MARK: - 快速 ISO8601 解析(執行緒安全、容忍毫秒與 ±hh:mm 時區)

public enum ISO8601 {
    /// 解析 "2026-06-29T16:33:32.124Z" / "2026-06-29T16:33:32Z" / "...+08:00"。
    public static func parse(_ s: String) -> Date? {
        var year = 0, month = 0, day = 0, hour = 0, minute = 0, second = 0
        var fraction = 0.0
        var tzOffset = 0
        let chars = Array(s.utf8)
        func digits(_ range: Range<Int>) -> Int? {
            guard range.upperBound <= chars.count else { return nil }
            var v = 0
            for i in range {
                let c = chars[i]
                guard c >= 48, c <= 57 else { return nil }
                v = v * 10 + Int(c - 48)
            }
            return v
        }
        guard let y = digits(0..<4), chars.count > 4, chars[4] == 45,
              let mo = digits(5..<7), chars.count > 7, chars[7] == 45,
              let d = digits(8..<10), chars.count > 10, chars[10] == 84 || chars[10] == 116,
              let h = digits(11..<13), chars.count > 13, chars[13] == 58,
              let mi = digits(14..<16), chars.count > 16, chars[16] == 58,
              let sec = digits(17..<19)
        else { return nil }
        year = y; month = mo; day = d; hour = h; minute = mi; second = sec
        var i = 19
        if i < chars.count, chars[i] == 46 { // '.'
            i += 1
            var frac = 0.0
            var scale = 0.1
            while i < chars.count, chars[i] >= 48, chars[i] <= 57 {
                frac += Double(chars[i] - 48) * scale
                scale /= 10
                i += 1
            }
            fraction = frac
        }
        if i < chars.count {
            switch chars[i] {
            case 90, 122: // 'Z'
                tzOffset = 0
            case 43, 45: // '+' '-'
                let sign = chars[i] == 43 ? 1 : -1
                guard let oh = digits((i + 1)..<(i + 3)) else { return nil }
                var om = 0
                if i + 3 < chars.count, chars[i + 3] == 58 {
                    om = digits((i + 4)..<(i + 6)) ?? 0
                } else {
                    om = digits((i + 3)..<(i + 5)) ?? 0
                }
                tzOffset = sign * (oh * 3600 + om * 60)
            default:
                break
            }
        }
        var comps = DateComponents()
        comps.year = year; comps.month = month; comps.day = day
        comps.hour = hour; comps.minute = minute; comps.second = second
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        guard let base = cal.date(from: comps) else { return nil }
        return base.addingTimeInterval(fraction - Double(tzOffset))
    }

    public static func format(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }
}

// MARK: - 寬鬆 JSON 物件存取(來源格式會演進,解析必須容錯)

public typealias JSONObject = [String: Any]

public extension Dictionary where Key == String, Value == Any {
    func str(_ key: String) -> String? { self[key] as? String }
    func int(_ key: String) -> Int? {
        if let v = self[key] as? Int { return v }
        if let v = self[key] as? Double { return Int(v) }
        if let v = self[key] as? NSNumber { return v.intValue }
        return nil
    }
    func double(_ key: String) -> Double? {
        if let v = self[key] as? Double { return v }
        if let v = self[key] as? Int { return Double(v) }
        if let v = self[key] as? NSNumber { return v.doubleValue }
        return nil
    }
    func obj(_ key: String) -> JSONObject? { self[key] as? JSONObject }
    func date(_ key: String) -> Date? {
        if let s = self[key] as? String { return ISO8601.parse(s) }
        return nil
    }
}
