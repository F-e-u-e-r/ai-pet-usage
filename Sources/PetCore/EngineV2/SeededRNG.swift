import Foundation

/// 決定性種子 RNG — xorshift64\*(§5 凍結規格,一字不差):
/// `state ^= state >> 12; state ^= state << 25; state ^= state >> 27; return state &* 2685821657736338717`。
/// 初始 state = seed;seed 不得為 0(xorshift 的 0 是吸收態),傳 0 時以固定非零常數替代。
public struct SeededRNG: RandomNumberGenerator, Sendable {
    public private(set) var state: UInt64

    public init(seed: UInt64) {
        // 0 為非法種子:以固定 odd 常數替代,維持決定性(不擲骰、不 crash)。
        state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
    }

    public mutating func next() -> UInt64 {
        state ^= state >> 12
        state ^= state << 25
        state ^= state >> 27
        return state &* 2_685_821_657_736_338_717
    }
}
