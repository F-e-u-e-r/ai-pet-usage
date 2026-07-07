import Foundation

/// JSONL 檔案的增量讀取:從既有位移續讀、只回傳「完整行」,並以位元組層級預過濾,
/// 避免對無關的大行(附件、快照)做 JSON 解析。
public enum JSONLScanner {

    public struct LineHit {
        public let data: Data
        /// 行起點在檔案中的位移,可作為穩定事件識別的一部分。
        public let byteOffset: Int64
    }

    /// 讀取 `url` 中自 `offset` 起的新行。`quickFilters` 為 UTF-8 子字串,
    /// 行內至少命中一個才交給 `handler`。回傳新的位移(最後一個完整行之後)。
    @discardableResult
    public static func scan(url: URL, from offset: Int64, quickFilters: [String],
                            handler: (LineHit) -> Void) throws -> Int64 {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let fileSize = (try? handle.seekToEnd()) ?? 0
        var start = offset
        if start > fileSize { start = 0 } // 檔案被截斷/重寫 → 從頭重讀
        try handle.seek(toOffset: UInt64(start))

        let filters = quickFilters.map { Data($0.utf8) }
        let chunkSize = 4 * 1024 * 1024
        var carry = Data()
        var carryStart = start
        var consumed = start

        while true {
            guard let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty else { break }
            carry.append(chunk)

            var lineStartIndex = carry.startIndex
            var lineStartOffset = carryStart
            var searchFrom = carry.startIndex
            while let nl = carry[searchFrom...].firstIndex(of: 0x0A) {
                let line = carry[lineStartIndex..<nl]
                let lineLen = Int64(carry.distance(from: lineStartIndex, to: nl)) + 1
                if !line.isEmpty, matches(line, filters: filters) {
                    handler(LineHit(data: Data(line), byteOffset: lineStartOffset))
                }
                lineStartOffset += lineLen
                consumed = lineStartOffset
                lineStartIndex = carry.index(after: nl)
                searchFrom = lineStartIndex
            }
            if lineStartIndex > carry.startIndex {
                carry.removeSubrange(carry.startIndex..<lineStartIndex)
                carryStart = consumed
            }
        }
        return consumed
    }

    private static func matches(_ line: Data.SubSequence, filters: [Data]) -> Bool {
        if filters.isEmpty { return true }
        for f in filters where line.range(of: f) != nil { return true }
        return false
    }

    /// 列出目錄底下(遞迴)符合副檔名的檔案與其大小。
    public static func listFiles(root: URL, pathExtension: String) -> [(url: URL, size: Int64)] {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                                     options: [.skipsHiddenFiles]) else { return [] }
        var out: [(URL, Int64)] = []
        for case let url as URL in en {
            guard url.pathExtension == pathExtension else { continue }
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            out.append((url, Int64(values?.fileSize ?? 0)))
        }
        return out
    }
}
