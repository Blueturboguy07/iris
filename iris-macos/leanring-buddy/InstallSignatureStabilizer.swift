//
//  InstallSignatureStabilizer.swift
//  leanring-buddy
//
//  WHY GUIDE-INSTALLED APPS KEEP LOSING THEIR PERMISSIONS, AND CONSUMER
//  APPS DON'T.
//
//  Founder report: "this permissions bug seems to happen a lot across my apps
//  ... i dont find this bug with many consumer apps."
//
//  Measured on this machine, in the real build output a guide installs:
//
//    hickeyfield/target/release/bundle/macos/Hickeyfield.app
//      Signature=adhoc
//      designated => cdhash H"b63d556d479e5517b0ce036a150e04cb89be0d3b"
//
//  A consumer app's TCC identity is a RULE — "signed by this team, with this
//  bundle id" — which every future build also satisfies, so grants survive
//  updates forever. `tauri build` (and cargo, and an unconfigured electron
//  build) signs AD-HOC: no certificate, so macOS falls back to identifying the
//  app by the HASH OF THAT EXACT BINARY. Rebuild it, update it, let Iris edit
//  it, and the hash changes — TCC sees a brand-new app and every grant is
//  gone. Two ad-hoc builds one byte apart were measured carrying different
//  designated requirements; the same bundle signed twice with a real
//  certificate carries the same one.
//
//  Iris already solved this for the EDIT path: `IrisLocalSigningIdentity`
//  signs rebuilt apps with the user's Developer ID when present, else a
//  persistent self-signed certificate — which is why the WhimprFlow clone's
//  bundle shows a stable Developer ID requirement while Hickeyfield's shows a
//  cdhash. The fix existed and simply never ran on the INSTALL path. This file
//  is that one missing call.
//
//  WHEN IT RUNS MATTERS MORE THAN THAT IT RUNS. The moment is right after the
//  install step lands the bundle and before the open step launches it — the
//  reader grants permissions on FIRST LAUNCH, and a grant given to an ad-hoc
//  app that is later re-signed is lost all over again. Signing first means the
//  very first grant is made against the stable identity.
//

import Foundation

@MainActor
enum InstallSignatureStabilizer {

    /// What happened, for the log and for the tests.
    enum Outcome: Equatable, Sendable {
        /// The app already carries a certificate-anchored identity; re-signing
        /// a good signature would only risk breaking it.
        case alreadyStable(designatedRequirement: String)
        /// Was ad-hoc or unsigned; now signed with the stable identity.
        case stabilized
        /// No identity could be resolved, or signing failed. The install is
        /// NOT harmed — the app runs exactly as it would have without Iris —
        /// but its grants will not survive a rebuild, and the reason is kept.
        case couldNotStabilize(reason: String)
    }

    /// Whether this designated requirement is the kind that loses its grants.
    ///
    /// Pure, so it is testable without signing anything. An ad-hoc signature
    /// has no certificate, so codesign falls back to `designated => cdhash
    /// H"…"` — an identity satisfied by exactly one binary, which is the whole
    /// bug. A certificate-anchored requirement names the cert chain instead
    /// and never mentions a cdhash. No requirement at all (an unsigned bundle)
    /// needs stabilizing for the same reason ad-hoc does.
    nonisolated static func identityNeedsStabilizing(designatedRequirement: String?) -> Bool {
        guard let designatedRequirement, !designatedRequirement.isEmpty else { return true }
        return designatedRequirement.contains("cdhash")
    }

    /// Give an installed app the stable signing identity, if and only if it
    /// needs one.
    ///
    /// Deliberately conservative in both directions: an app that already has a
    /// certificate-anchored identity — the founder's own Developer ID builds,
    /// or any app installed from a signed download — is left byte-for-byte
    /// alone, and a failure to resolve or apply the identity leaves the ad-hoc
    /// app exactly as the build produced it. This can only ever upgrade an
    /// identity that was going to be thrown away on the next rebuild anyway.
    static func stabilize(bundleAtPath bundlePath: String) async -> Outcome {
        let currentRequirement = await IrisLocalSigningIdentity.designatedRequirement(
            ofBundleAtPath: bundlePath
        )
        guard identityNeedsStabilizing(designatedRequirement: currentRequirement) else {
            return .alreadyStable(designatedRequirement: currentRequirement ?? "")
        }

        guard let identity = await IrisLocalSigningIdentity.resolveStableIdentity(
            requestConsentToCreateLocalCertificate: { true }
        ) else {
            return .couldNotStabilize(
                reason: "no stable signing identity could be resolved on this Mac"
            )
        }

        let signing = await IrisLocalSigningIdentity.signApplicationBundle(
            atPath: bundlePath, identity: identity
        )
        switch signing {
        case .signed:
            return .stabilized
        case .failed(let reason):
            return .couldNotStabilize(reason: reason)
        }
    }
}
