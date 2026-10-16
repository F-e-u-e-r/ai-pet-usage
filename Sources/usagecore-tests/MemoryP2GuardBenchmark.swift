import Foundation
@testable import UsageCore

// Memory P2 Option C — peak phys_footprint A/B benchmark (env-gated; NOT part of the normal suite).
//
// Activate with AIPET_P2_BENCH=1 (main.swift then runs ONLY this and exits — the normal 157k-assertion
// suite is skipped, so each benchmark process is fast and starts with fresh allocator state).
//
//   AIPET_P2_BENCH_VARIANT = old | new
//       old = canonicalizeRawLines(raw)         (Slice-retaining guard — the baseline structure)
//       new = canonicalizeRawLinesValidate(raw) (validate-only guard  — the C1 candidate)
//   AIPET_P2_BENCH_MODE    = guard | fullpath   (default guard)
//       guard    = run the guard ONCE on an in-memory raw, discard result (mimics the compaction caller)
//       fullpath = guard + compactRawPreserving on a WRITABLE COPY (end-to-end peak + duration + integrity)
//   AIPET_P2_BENCH_SIZE    = <event count>      (synthetic deterministic ledger) — e.g. 185000 ≈ ~94 MB
//   AIPET_P2_BENCH_LEDGER  = <path>             (an ISOLATED COPY of real ledger data; never the live file)
//   AIPET_P2_BENCH_REPS    = repetitions in this process (default 1; the driver script loops processes)
//
// Metric = phys_footprint via task_info(TASK_VM_INFO) = Activity Monitor "Memory" = the owner's numbers
// = watchdog/P1 primary. RSS is explicitly NOT used as a proxy (PROFILE-EVIDENCE §6). Peak is captured by
// a 1 ms background sampler while the measured call runs. One measurement per fresh process for clean
// allocator state. Each rep prints a machine-parseable RESULT line.

final class MemoryP2GuardBenchmark {

    // MARK: - phys_footprint

    static func physFootprintBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), intPtr, &count)
            }
        }
        return kr == KERN_SUCCESS ? info.phys_footprint : 0
    }

    private static func mb(_ bytes: UInt64) -> String {
        String(format: "%.1f", Double(bytes) / 1_048_576.0)
    }

    // MARK: - 1 ms peak sampler (background thread)

    final class PeakSampler {
        private let lock = NSLock()
        private var _peak: UInt64 = 0
        private var _run = true
        func peak() -> UInt64 { lock.lock(); defer { lock.unlock() }; return _peak }
        func stop() { lock.lock(); _run = false; lock.unlock() }
        func start() {
            let t = Thread {
                while true {
                    self.lock.lock(); let run = self._run; self.lock.unlock()
                    if !run { break }
                    let cur = MemoryP2GuardBenchmark.physFootprintBytes()
                    self.lock.lock(); if cur > self._peak { self._peak = cur }; self.lock.unlock()
                    usleep(1000)   // 1 ms
                }
            }
            t.stackSize = 1 << 20
            t.start()
        }
    }

    // MARK: - deterministic synthetic ledger (multi-provider / model / project / cost / fractional ts)

    static func synthesizeLedger(events n: Int) -> Data {
        let models = ["opus", "sonnet", "haiku", "grok-code", "gpt-5"]
        let encoder = AtomicJSON.encoder()
        var out = Data()
        out.reserveCapacity(n * 520)
        for i in 0..<n {
            let ts = Date(timeIntervalSince1970: 1_700_000_000 + Double(i))
            let e = UsageEvent(
                id: "evt-\(i)", providerId: "p\(i % 4)",
                projectId: "proj-\(i % 9)", projectName: "Project \(i % 9)",
                modelId: models[i % models.count], timestamp: ts,
                tokens: TokenBreakdown(input: i % 1000, output: i % 500, cacheRead: i % 100),
                sourceKind: "bench", sourcePath: "/bench/\(i % 50).jsonl",
                providerCostUSD: Double(i % 7) * 0.001)
            if let line = try? encoder.encode(e) { out.append(line); out.append(0x0A) }
        }
        return out
    }

    // MARK: - one measured run

    /// Mode `guard`: run the selected guard ONCE on `raw`, discard the result. Returns (peak, settled, ms, ok).
    private func measureGuard(variant: String, raw: Data) -> (peak: UInt64, settled: UInt64, ms: Double, ok: Bool) {
        let sampler = PeakSampler(); sampler.start()
        let base = Self.physFootprintBytes()
        _ = base   // baseline printed by caller
        let t0 = Date()
        var ok = false
        if variant == "old" {
            if case .success = CanonicalLedgerV1.canonicalizeRawLines(raw) { ok = true }
        } else {
            ok = (CanonicalLedgerV1.canonicalizeRawLinesValidate(raw) == nil)
        }
        let ms = Date().timeIntervalSince(t0) * 1000
        let peak = max(sampler.peak(), Self.physFootprintBytes())
        sampler.stop()
        usleep(50_000)
        let settled = Self.physFootprintBytes()
        return (peak, settled, ms, ok)
    }

    /// Mode `fullpath`: guard(variant) + compactRawPreserving on a writable COPY. Mutating (copy only).
    private func measureFullPath(variant: String, ledgerURL: URL) -> (peak: UInt64, settled: UInt64, ms: Double, ok: Bool, result: String) {
        guard let raw = try? Data(contentsOf: ledgerURL) else { return (0, 0, 0, false, "read-failed") }
        let ledger = UsageLedger(fileURL: ledgerURL)
        let now = Date()
        let sampler = PeakSampler(); sampler.start()
        let t0 = Date()
        var guardOK = false
        if variant == "old" {
            if case .success = CanonicalLedgerV1.canonicalizeRawLines(raw) { guardOK = true }
        } else {
            guardOK = (CanonicalLedgerV1.canonicalizeRawLinesValidate(raw) == nil)
        }
        var result = "guard-suspect"
        if guardOK {
            // retentionDays 可配置(default 92 = production):真實帳本下丟最舊少數、保留 ~全部 ⇒
            // newData ≈ 全檔 + re-decode ≈ 全事件陣列 = 代表性的 compact-phase transients(勿用 0:全丟會低估)。
            let retention = Int(ProcessInfo.processInfo.environment["AIPET_P2_BENCH_RETENTION"] ?? "92") ?? 92
            let r = ledger.compactRawPreserving(retentionDays: retention, now: now, raw: raw)
            result = "\(r)"
        }
        let ms = Date().timeIntervalSince(t0) * 1000
        let peak = max(sampler.peak(), Self.physFootprintBytes())
        sampler.stop()
        usleep(50_000)
        let settled = Self.physFootprintBytes()
        return (peak, settled, ms, guardOK, result)
    }

    // MARK: - env driver

    func runFromEnvironmentAndExit() -> Never {
        let env = ProcessInfo.processInfo.environment
        let variant = env["AIPET_P2_BENCH_VARIANT"] ?? "new"
        let mode = env["AIPET_P2_BENCH_MODE"] ?? "guard"
        let reps = Int(env["AIPET_P2_BENCH_REPS"] ?? "1") ?? 1
        let ledgerPathEnv = env["AIPET_P2_BENCH_LEDGER"]
        let size = Int(env["AIPET_P2_BENCH_SIZE"] ?? "185000") ?? 185000

        FileHandle.standardError.write(Data("P2BENCH start variant=\(variant) mode=\(mode) reps=\(reps) size=\(size) ledger=\(ledgerPathEnv ?? "<synthetic>")\n".utf8))

        for rep in 0..<reps {
            if mode == "fullpath" {
                // fullpath mutates the file ⇒ work on a FRESH per-rep copy (never the source given).
                let src: URL
                var srcBytes = 0
                if let p = ledgerPathEnv { src = URL(fileURLWithPath: p) }
                else {
                    // materialise a synthetic ledger to a temp file as the source.
                    let d = Self.synthesizeLedger(events: size)
                    srcBytes = d.count
                    let s = FileManager.default.temporaryDirectory.appendingPathComponent("p2bench-src-\(UUID().uuidString).jsonl")
                    try? d.write(to: s); src = s
                }
                let copyDir = FileManager.default.temporaryDirectory.appendingPathComponent("p2bench-\(UUID().uuidString)")
                try? FileManager.default.createDirectory(at: copyDir, withIntermediateDirectories: true)
                let copy = copyDir.appendingPathComponent("ledger.jsonl")
                try? FileManager.default.copyItem(at: src, to: copy)
                srcBytes = (try? Data(contentsOf: copy).count) ?? srcBytes
                let base = Self.physFootprintBytes()
                let m = measureFullPath(variant: variant, ledgerURL: copy)
                print("RESULT mode=fullpath variant=\(variant) size=\(size) bytes=\(srcBytes) rep=\(rep) baselineMB=\(Self.mb(base)) peakMB=\(Self.mb(m.peak)) deltaMB=\(Self.mb(m.peak >= base ? m.peak - base : 0)) settledMB=\(Self.mb(m.settled)) ms=\(String(format: "%.1f", m.ms)) ok=\(m.ok) compact=\(m.result)")
                try? FileManager.default.removeItem(at: copyDir)
            } else {
                let raw: Data
                var bytes = 0
                if let p = ledgerPathEnv, let d = try? Data(contentsOf: URL(fileURLWithPath: p)) { raw = d }
                else { raw = Self.synthesizeLedger(events: size) }
                bytes = raw.count
                let base = Self.physFootprintBytes()   // raw already resident ⇒ delta isolates the guard
                let m = measureGuard(variant: variant, raw: raw)
                print("RESULT mode=guard variant=\(variant) size=\(size) bytes=\(bytes) rep=\(rep) baselineMB=\(Self.mb(base)) peakMB=\(Self.mb(m.peak)) deltaMB=\(Self.mb(m.peak >= base ? m.peak - base : 0)) settledMB=\(Self.mb(m.settled)) ms=\(String(format: "%.1f", m.ms)) ok=\(m.ok)")
            }
        }
        FileHandle.standardError.write(Data("P2BENCH done\n".utf8))
        exit(0)
    }
}
