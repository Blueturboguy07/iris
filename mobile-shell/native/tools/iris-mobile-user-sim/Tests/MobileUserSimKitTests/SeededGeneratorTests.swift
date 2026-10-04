import XCTest
@testable import MobileUserSimKit

final class SeededGeneratorTests: XCTestCase {
    func testSameSeedProducesSameSequence() {
        var a = SeededGenerator(seed: 42)
        var b = SeededGenerator(seed: 42)
        for _ in 0..<50 {
            XCTAssertEqual(a.next(), b.next())
        }
    }

    func testDifferentSeedsProduceDifferentSequences() {
        var a = SeededGenerator(seed: 1)
        var b = SeededGenerator(seed: 2)
        let sequenceA = (0..<20).map { _ in a.next() }
        let sequenceB = (0..<20).map { _ in b.next() }
        XCTAssertNotEqual(sequenceA, sequenceB)
    }

    func testDerivedSeedIsDeterministicAndVariesByRunIndex() {
        let baseSeed: UInt64 = 20260926
        let seedForRun3First = SeededGenerator.derivedSeed(baseSeed: baseSeed, runIndex: 3)
        let seedForRun3Second = SeededGenerator.derivedSeed(baseSeed: baseSeed, runIndex: 3)
        XCTAssertEqual(seedForRun3First, seedForRun3Second, "the same (baseSeed, runIndex) must always derive the same seed")

        var seenSeeds = Set<UInt64>()
        for runIndex in 0..<100 {
            seenSeeds.insert(SeededGenerator.derivedSeed(baseSeed: baseSeed, runIndex: runIndex))
        }
        XCTAssertEqual(seenSeeds.count, 100, "derived seeds across 100 run indices must not collide")
    }

    func testNextUnitDoubleStaysInRange() {
        var generator = SeededGenerator(seed: 7)
        for _ in 0..<1000 {
            let value = generator.nextUnitDouble()
            XCTAssertGreaterThanOrEqual(value, 0)
            XCTAssertLessThan(value, 1)
        }
    }

    func testNextBoolRespectsExtremeProbabilities() {
        var generator = SeededGenerator(seed: 99)
        for _ in 0..<50 {
            XCTAssertFalse(generator.nextBool(probability: 0))
        }
        for _ in 0..<50 {
            XCTAssertTrue(generator.nextBool(probability: 1))
        }
    }
}
