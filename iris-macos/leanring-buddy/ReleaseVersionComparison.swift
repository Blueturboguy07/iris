//
//  ReleaseVersionComparison.swift
//  leanring-buddy
//
//  Decides whether one release version is newer than another.
//
//  This exists as its own type, with its own tests, because the obvious
//  shortcut is wrong in a way that actively harms people. Comparing two version
//  strings with `<` puts `v1.10.0` *before* `v1.9.0`, because "1" sorts before
//  "9" one character at a time. Iris would then tell someone running the newest
//  build that an update is waiting, and tell someone running an old build they
//  are current. Both are lies, and the first one walks a user backwards through
//  a release they already have.
//
//  So the comparison is done properly: numerically, component by component,
//  tolerating the leading `v` that release tags carry, tolerating a different
//  number of components on each side, and applying the semver rule that a
//  pre-release sorts *below* the release it leads up to. Anything this cannot
//  read confidently returns `cannotBeCompared` rather than guessing a
//  direction, because "I do not know" is a safe answer and a wrong direction is
//  not.
//

import Foundation

/// How one version relates to another. `cannotBeCompared` is a real answer, not
/// a failure: it is what an unparseable version on either side produces.
nonisolated enum ReleaseVersionOrdering: Equatable, Sendable {
    case olderThanTheOtherVersion
    case theSameAsTheOtherVersion
    case newerThanTheOtherVersion
    case cannotBeCompared
}

/// A version string broken into the two parts that decide precedence: the
/// numeric release components (`1.10.0`) and the pre-release identifiers that
/// may follow a hyphen (`-beta.2`).
nonisolated struct ReleaseVersion: Equatable, Sendable {
    /// `1.10.0` becomes `[1, 10, 0]`. Never empty for a successfully parsed
    /// version.
    let numericComponents: [Int]

    /// `-beta.2` becomes `["beta", "2"]`. Empty means this is a final release,
    /// which outranks every pre-release of the same numeric version.
    let preReleaseIdentifiers: [String]

    /// Reads a version string, or returns nil when it is not a version at all.
    ///
    /// Accepts: an optional leading `v` or `V` (release tags almost always carry
    /// one), any number of numeric components, an optional `-pre.release`
    /// suffix, and an optional `+buildmetadata` suffix which semver says has no
    /// effect on precedence and which is therefore discarded.
    ///
    /// Rejects anything with a non-numeric release component — `1.x.3`,
    /// `nightly`, `latest` — because a version that cannot be read is not a
    /// version that can be ranked.
    static func parse(_ rawVersionString: String) -> ReleaseVersion? {
        var remainingText = rawVersionString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !remainingText.isEmpty else {
            return nil
        }

        // The leading `v` is dropped only when a digit follows it, so a tag
        // literally named "version" is still rejected rather than read as the
        // nonsense version "ersion".
        if let firstCharacter = remainingText.first,
           firstCharacter == "v" || firstCharacter == "V" {
            let textAfterTheV = String(remainingText.dropFirst())
            if textAfterTheV.first?.isNumber == true {
                remainingText = textAfterTheV
            }
        }

        // Build metadata is explicitly ignored for precedence by the semver
        // spec, so `1.2.0+build.7` and `1.2.0` are the same release.
        if let buildMetadataSeparatorIndex = remainingText.firstIndex(of: "+") {
            remainingText = String(remainingText[remainingText.startIndex..<buildMetadataSeparatorIndex])
        }

        let numericPortion: String
        let preReleaseIdentifiers: [String]
        if let preReleaseSeparatorIndex = remainingText.firstIndex(of: "-") {
            numericPortion = String(remainingText[remainingText.startIndex..<preReleaseSeparatorIndex])
            let preReleasePortion = String(remainingText[remainingText.index(after: preReleaseSeparatorIndex)...])
            // A trailing hyphen with nothing after it is malformed rather than
            // "a release with an empty pre-release".
            guard !preReleasePortion.isEmpty else {
                return nil
            }
            let identifiers = preReleasePortion.components(separatedBy: ".")
            guard identifiers.allSatisfy({ !$0.isEmpty }) else {
                return nil
            }
            preReleaseIdentifiers = identifiers
        } else {
            numericPortion = remainingText
            preReleaseIdentifiers = []
        }

        let numericComponentStrings = numericPortion.components(separatedBy: ".")
        guard !numericComponentStrings.isEmpty else {
            return nil
        }

        var numericComponents: [Int] = []
        numericComponents.reserveCapacity(numericComponentStrings.count)
        for numericComponentString in numericComponentStrings {
            // `allSatisfy(\.isNumber)` would accept Eastern Arabic digits and
            // other non-ASCII numerals that `Int(_:)` then reads differently, so
            // the check is explicitly on ASCII digits.
            guard !numericComponentString.isEmpty,
                  numericComponentString.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let numericComponent = Int(numericComponentString) else {
                return nil
            }
            numericComponents.append(numericComponent)
        }

        return ReleaseVersion(
            numericComponents: numericComponents,
            preReleaseIdentifiers: preReleaseIdentifiers
        )
    }

    /// Compares two raw version strings. This is the only entry point callers
    /// need; parsing is an implementation detail of it.
    static func compare(
        _ leftRawVersionString: String,
        to rightRawVersionString: String
    ) -> ReleaseVersionOrdering {
        guard let leftVersion = parse(leftRawVersionString),
              let rightVersion = parse(rightRawVersionString) else {
            return .cannotBeCompared
        }
        return leftVersion.compared(to: rightVersion)
    }

    func compared(to otherVersion: ReleaseVersion) -> ReleaseVersionOrdering {
        // A missing component is a zero, which is what makes `1.2` and `1.2.0`
        // the same release rather than two different ones.
        let comparedComponentCount = max(numericComponents.count, otherVersion.numericComponents.count)
        for componentIndex in 0..<comparedComponentCount {
            let thisComponent = componentIndex < numericComponents.count
                ? numericComponents[componentIndex]
                : 0
            let otherComponent = componentIndex < otherVersion.numericComponents.count
                ? otherVersion.numericComponents[componentIndex]
                : 0
            if thisComponent < otherComponent {
                return .olderThanTheOtherVersion
            }
            if thisComponent > otherComponent {
                return .newerThanTheOtherVersion
            }
        }

        return Self.comparePreReleaseIdentifiers(
            preReleaseIdentifiers,
            to: otherVersion.preReleaseIdentifiers
        )
    }

    // MARK: - Pre-release precedence

    /// The semver pre-release rules. The one that matters most in practice is
    /// the first: `1.2.0-beta.1` is *older* than `1.2.0`, so someone on the beta
    /// is correctly told the real release is out.
    private static func comparePreReleaseIdentifiers(
        _ leftIdentifiers: [String],
        to rightIdentifiers: [String]
    ) -> ReleaseVersionOrdering {
        if leftIdentifiers.isEmpty && rightIdentifiers.isEmpty {
            return .theSameAsTheOtherVersion
        }
        if leftIdentifiers.isEmpty {
            return .newerThanTheOtherVersion
        }
        if rightIdentifiers.isEmpty {
            return .olderThanTheOtherVersion
        }

        let comparedIdentifierCount = min(leftIdentifiers.count, rightIdentifiers.count)
        for identifierIndex in 0..<comparedIdentifierCount {
            let comparisonResult = compareOnePreReleaseIdentifier(
                leftIdentifiers[identifierIndex],
                to: rightIdentifiers[identifierIndex]
            )
            switch comparisonResult {
            case .orderedAscending:
                return .olderThanTheOtherVersion
            case .orderedDescending:
                return .newerThanTheOtherVersion
            case .orderedSame:
                continue
            }
        }

        // Every shared identifier matched, so the one with more identifiers is
        // the later pre-release: `1.2.0-beta` comes before `1.2.0-beta.1`.
        if leftIdentifiers.count < rightIdentifiers.count {
            return .olderThanTheOtherVersion
        }
        if leftIdentifiers.count > rightIdentifiers.count {
            return .newerThanTheOtherVersion
        }
        return .theSameAsTheOtherVersion
    }

    private static func compareOnePreReleaseIdentifier(
        _ leftIdentifier: String,
        to rightIdentifier: String
    ) -> ComparisonResult {
        let leftNumericValue = numericValueOfIdentifier(leftIdentifier)
        let rightNumericValue = numericValueOfIdentifier(rightIdentifier)

        switch (leftNumericValue, rightNumericValue) {
        case let (.some(leftNumber), .some(rightNumber)):
            if leftNumber == rightNumber {
                return .orderedSame
            }
            return leftNumber < rightNumber ? .orderedAscending : .orderedDescending
        case (.some, .none):
            // Numeric identifiers always rank below alphanumeric ones.
            return .orderedAscending
        case (.none, .some):
            return .orderedDescending
        case (.none, .none):
            return compareInASCIIOrder(leftIdentifier, to: rightIdentifier)
        }
    }

    private static func numericValueOfIdentifier(_ identifier: String) -> Int? {
        guard identifier.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            return nil
        }
        return Int(identifier)
    }

    /// Semver asks for ASCII sort order specifically, so the comparison is on
    /// scalar values rather than on `String`'s locale-aware ordering, which
    /// would put "Beta" and "beta" in an order that depends on where the user
    /// lives.
    private static func compareInASCIIOrder(
        _ leftIdentifier: String,
        to rightIdentifier: String
    ) -> ComparisonResult {
        if leftIdentifier == rightIdentifier {
            return .orderedSame
        }
        let leftScalarValues = leftIdentifier.unicodeScalars.map(\.value)
        let rightScalarValues = rightIdentifier.unicodeScalars.map(\.value)
        return leftScalarValues.lexicographicallyPrecedes(rightScalarValues)
            ? .orderedAscending
            : .orderedDescending
    }
}
