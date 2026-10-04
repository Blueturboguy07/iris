import Foundation

/// A small deterministic PRNG (splitmix64) so every run is reproducible from
/// its seed and run index alone, exactly like the desktop harness's own
/// generator (tools/iris-user-sim/Sources/UserSimKit/SeededGenerator.swift),
/// reimplemented here rather than imported so this package never depends on
/// that tool.
public struct SeededGenerator: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) {
        // Avoid the all-zero fixed point.
        state = seed == 0 ? 0x9E3779B97F4A7C15 : seed
    }

    public mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    /// Deterministically derives a new 64-bit seed from a base seed plus a
    /// run index, so a sweep's per-run seeds never collide with each other
    /// or with a caller's own seed space, and a single failing run can be
    /// reproduced from (seed, runIndex) alone without replaying the sweep.
    public static func derivedSeed(baseSeed: UInt64, runIndex: Int) -> UInt64 {
        var mixer = SeededGenerator(seed: baseSeed ^ 0xD1B54A32D192ED03)
        for _ in 0...runIndex {
            _ = mixer.next()
        }
        return mixer.next()
    }

    /// A double in [0, 1).
    public mutating func nextUnitDouble() -> Double {
        Double(next() >> 11) * (1.0 / 9007199254740992.0) // 2^53
    }

    /// True with probability `probability` (clamped to [0, 1]).
    public mutating func nextBool(probability: Double) -> Bool {
        nextUnitDouble() < max(0, min(1, probability))
    }
}
