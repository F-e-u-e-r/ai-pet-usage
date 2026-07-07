import Foundation

/// 決定性可注入的 RNG(SplitMix64):測試以固定 seed 驗證 micro-animation 排程。
public struct SeededRandom: RandomNumberGenerator, Sendable {
    private var state: UInt64
    public init(seed: UInt64) { state = seed }
    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// 寵物動畫狀態機(spec「Pixel Pet Optimization」):
///  - looping 狀態:沿用各狀態的 frames × fps(絕對時間取幀,與舊行為一致)
///  - one-shot 轉場:離開舊狀態先播 exit(貓 focus-end),進入新狀態先播 enter
///    (貓 focus-start)——一律由 mood 變化「決定性」觸發,絕不隨機
///  - micro-animation:眨眼/耳動/尾尖/鬍鬚,以隨機間隔插播在安靜的 loop 狀態,
///    只負責 personality,不承載狀態語意;walk/sleep/eat/jump 期間不插播
///  - reduce-motion / quiet:回傳該狀態的靜態代表姿勢,不播轉場、不播 pulse
///
/// 呼叫端(PetView 的 TimelineView)每 tick 呼叫 `frame(...)`;
/// 內部狀態(轉場佇列、micro 排程)由本類自行推進,無 SwiftUI 依賴。
public final class PixelAnimator {
    public private(set) var species: PetSpecies
    public private(set) var currentState: PixelAnimState

    private struct Playing {
        var frames: [[String]]
        var fps: Double
        var startedAt: Date
    }

    /// 待播的 one-shot 轉場狀態(exit → enter 順序)。
    private var pendingTransitions: [PixelAnimState] = []
    private var activeTransition: Playing?
    private var activeMicro: Playing?
    /// 各 micro-animation 的下次觸發時刻。
    private var nextMicroAt: [String: Date] = [:]
    private var seeded: SeededRandom?

    public init(species: PetSpecies = .dog, initialState: PixelAnimState = .idle, seed: UInt64? = nil) {
        self.species = species
        self.currentState = initialState
        self.seeded = seed.map(SeededRandom.init)
    }

    private func random(in range: ClosedRange<Double>) -> Double {
        if var g = seeded {
            let v = Double.random(in: range, using: &g)
            seeded = g
            return v
        }
        return Double.random(in: range)
    }

    private func reset(to state: PixelAnimState) {
        currentState = state
        pendingTransitions = []
        activeTransition = nil
        activeMicro = nil
        nextMicroAt = [:]
    }

    /// 取得當下應顯示的幀。`target` 由 mood 決定性推導(PixelPets.animState)。
    public func frame(species newSpecies: PetSpecies,
                      target: PixelAnimState,
                      sprite: PixelSprite,
                      at now: Date,
                      reduceMotion: Bool,
                      speed: Double = 1) -> [String] {
        if newSpecies != species {
            species = newSpecies
            reset(to: target)
        }

        if reduceMotion {
            // 靜態代表姿勢:狀態仍可由造型+姿勢+顏色讀出(spec 無障礙要求)
            reset(to: target)
            return PixelPets.staticPose(sprite: sprite, state: target)
        }

        if target != currentState {
            var queue: [PixelAnimState] = []
            if let exit = PixelPets.exitTransition(species: species, from: currentState) {
                queue.append(exit)
            }
            if let enter = PixelPets.enterTransition(species: species, to: target) {
                queue.append(enter)
            }
            reset(to: target)
            pendingTransitions = queue
        }

        // one-shot 轉場佇列(可能連播 exit → enter)
        while true {
            if activeTransition == nil, !pendingTransitions.isEmpty {
                let st = pendingTransitions.removeFirst()
                activeTransition = Playing(frames: sprite.frames(for: st),
                                           fps: PixelPets.fps(for: st), startedAt: now)
            }
            guard let shot = activeTransition else { break }
            let idx = Int(now.timeIntervalSince(shot.startedAt) * shot.fps)
            if idx >= 0, idx < shot.frames.count { return shot.frames[idx] }
            activeTransition = nil
            if pendingTransitions.isEmpty { break }
        }

        // micro-animation:播放中優先;結束後回 loop
        if let m = activeMicro {
            let idx = Int(now.timeIntervalSince(m.startedAt) * m.fps)
            if idx >= 0, idx < m.frames.count { return m.frames[idx] }
            activeMicro = nil
        }
        let micros = PixelPets.microAnimations(species: species, state: currentState)
        if !micros.isEmpty {
            for m in micros {
                if let due = nextMicroAt[m.name] {
                    if now >= due, activeMicro == nil {
                        activeMicro = Playing(frames: m.frames, fps: m.fps, startedAt: now)
                        nextMicroAt[m.name] = now.addingTimeInterval(random(in: m.interval))
                    }
                } else {
                    // 進入狀態後首次排程
                    nextMicroAt[m.name] = now.addingTimeInterval(random(in: m.interval))
                }
            }
            if let m = activeMicro {
                let idx = Int(now.timeIntervalSince(m.startedAt) * m.fps)
                if idx >= 0, idx < m.frames.count { return m.frames[idx] }
                activeMicro = nil
            }
        }

        // 一般 loop:絕對時間取幀(與既有行為一致,不因插播漂移)
        let frames = sprite.frames(for: currentState)
        guard !frames.isEmpty else { return [] }
        let fps = PixelPets.fps(for: currentState) * max(0.1, speed)
        let idx = Int(now.timeIntervalSinceReferenceDate * fps) % frames.count
        return frames[max(0, idx)]
    }
}
