//
//  MaintainInstallIdentity.swift
//  leanring-buddy
//
//  The pseudonymous id the pool counts distinct installs by. It is a random
//  UUID, never an account id or a hardware id, and it ROTATES every 90 days
//  — so the pool can tell "three machines" from "one machine three times"
//  without ever holding a stable cross-year identifier for anyone. Rotation
//  costs a little statistical fidelity (a long-lived install counts fresh
//  each quarter) and buys that no pooled row links back further than a
//  season. That trade is the point.
//

import Foundation

@MainActor
final class MaintainInstallIdentity {

    private static let idKey = "iris:maintain:install-id"
    private static let mintedAtKey = "iris:maintain:install-id-minted-at"
    private static let rotationInterval: TimeInterval = 90 * 24 * 3600

    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    var currentInstallId: UUID {
        if let stored = userDefaults.string(forKey: Self.idKey),
           let existing = UUID(uuidString: stored),
           let mintedAt = userDefaults.object(forKey: Self.mintedAtKey) as? Date,
           Date().timeIntervalSince(mintedAt) < Self.rotationInterval {
            return existing
        }
        let fresh = UUID()
        userDefaults.set(fresh.uuidString, forKey: Self.idKey)
        userDefaults.set(Date(), forKey: Self.mintedAtKey)
        return fresh
    }

    /// arm64/x86_64 — an applicability dimension, not an identity one.
    nonisolated static var machineArchitecture: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let machine = withUnsafeBytes(of: &systemInfo.machine) { raw -> String in
            let bytes = raw.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
        return machine.isEmpty ? "unknown" : machine
    }
}
