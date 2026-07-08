import Foundation
import CoreServices

/// FSEvents 目錄樹監看:對 `dirs` 啟動一個 stream;僅當變更路徑命中 `triggers`(等於或位於其下)
/// 才在 debounce 後觸發 `onChange`。以「路徑白名單」過濾,可安全監看含我方寫入檔的目錄
/// (如 App Support 內的帳本/設定與 statusline 同目錄)而不會自我觸發 refresh。
///
/// 執行緒模型:stream / pending / triggers 一律 queue-confined;C callback 只透過 Unmanaged
/// 取回 self,不傳遞非 Sendable 物件。生命週期由持有者(AppModel)以 start/stop 管理。
final class FileWatcher {
    private let queue = DispatchQueue(label: "dev.aipetusage.filewatch")
    private var stream: FSEventStreamRef?     // queue-confined
    private var pending: DispatchWorkItem?    // queue-confined
    private var triggers: [String] = []       // queue-confined:觸發白名單(等於或位於其下)
    private let debounce: TimeInterval
    private let onChange: @Sendable () -> Void

    init(debounce: TimeInterval = 1.0, onChange: @escaping @Sendable () -> Void) {
        self.debounce = debounce
        self.onChange = onChange
    }

    var isActive: Bool { queue.sync { stream != nil } }

    /// 以 `dirs` 重啟監看(先停舊 stream);變更路徑命中 `triggers` 才觸發。dirs 為空或建立失敗回 false。
    @discardableResult
    func start(dirs: [String], triggers: [String]) -> Bool {
        queue.sync { startLocked(dirs: dirs, triggers: triggers) }
    }

    func stop() { queue.sync { stopLocked() } }

    deinit { queue.sync { stopLocked() } }

    // MARK: - queue-confined

    private func startLocked(dirs: [String], triggers: [String]) -> Bool {
        stopLocked()
        guard !dirs.isEmpty else { return false }
        self.triggers = triggers
        var context = FSEventStreamContext(version: 0,
                                           info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, eventPaths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
            let paths = (unsafeBitCast(eventPaths, to: NSArray.self) as? [String]) ?? []
            watcher.handle(changedPaths: paths)
        }
        // FileEvents:回報「檔案層」路徑;否則 FSEvents 只給父目錄,精確 statusline 檔 trigger
        //   永遠不命中(provider 目錄前綴 trigger 仍可,但單獨的 statusline 更新會漏)。
        // UseCFTypes:eventPaths 以 CFArray<CFString> 交付,方便取回 [String] 做路徑白名單過濾。
        // IgnoreSelf:順帶忽略我方進程自身寫入(白名單已足夠,這是額外保險 + 降低喚醒次數)。
        let flags = UInt32(kFSEventStreamCreateFlagNoDefer
                           | kFSEventStreamCreateFlagIgnoreSelf
                           | kFSEventStreamCreateFlagUseCFTypes
                           | kFSEventStreamCreateFlagFileEvents)
        guard let s = FSEventStreamCreate(nil, callback, &context, dirs as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                                          0.5, flags) else { return false }
        FSEventStreamSetDispatchQueue(s, queue)
        guard FSEventStreamStart(s) else {
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
            return false
        }
        stream = s
        return true
    }

    private func stopLocked() {
        pending?.cancel()
        pending = nil
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
    }

    /// 已在 queue 上:任一變更路徑命中白名單(等於某觸發路徑,或位於其目錄樹下)才 debounce 觸發。
    private func handle(changedPaths: [String]) {
        let hit = changedPaths.contains { path in
            triggers.contains { path == $0 || path.hasPrefix($0 + "/") }
        }
        guard hit else { return }
        pending?.cancel()
        let work = DispatchWorkItem { [onChange] in onChange() }
        pending = work
        queue.asyncAfter(deadline: .now() + debounce, execute: work)
    }
}
