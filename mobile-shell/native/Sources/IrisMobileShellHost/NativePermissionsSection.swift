#if os(iOS)
import IrisMobileShellCore
import SwiftUI

/// Plain-language control for one app's remembered phone-capability
/// decisions. Shown next to what the app discloses it might ask for
/// (`NativeCapabilityDisclosure`). Changing a choice here writes through the
/// store immediately and takes effect on the app's next request; it never
/// touches iOS's own camera permission for the whole Iris app, which stays
/// under iOS Settings.
public struct NativePermissionsSection: View {
    private let identity: NativeShellAppIdentity
    private let requestedCapabilities: [String]
    private let store: NativePermissionStore
    @State private var decisions: [String: NativePermissionDecision] = [:]

    public init(identity: NativeShellAppIdentity, requestedCapabilities: [String], store: NativePermissionStore) {
        self.identity = identity
        self.requestedCapabilities = requestedCapabilities
        self.store = store
    }

    private var eligibleCapabilities: [String] {
        // Only capabilities this exact revision still declares; an app that
        // dropped a capability in an update has nothing to show or revoke.
        Self.knownCapabilities.filter { requestedCapabilities.contains($0) }
    }

    public var body: some View {
        let capabilities = eligibleCapabilities
        if !capabilities.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(capabilities, id: \.self) { capability in
                    row(for: capability)
                }
            }
            .onAppear(perform: refresh)
            .accessibilityIdentifier("iris.permissions.section")
        }
    }

    @ViewBuilder
    private func row(for capability: String) -> some View {
        let decision = decisions[capability] ?? .notDecided
        VStack(alignment: .leading, spacing: 4) {
            Text(Self.label(for: capability)).font(.subheadline).fontWeight(.medium)
            Text(Self.statusText(decision)).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                if decision != .granted {
                    Button("Allow") { set(.granted, capability: capability) }
                        .accessibilityIdentifier("iris.permissions.allow.\(capability)")
                }
                if decision != .denied {
                    Button("Don't allow") { set(.denied, capability: capability) }
                        .accessibilityIdentifier("iris.permissions.deny.\(capability)")
                }
                if decision != .notDecided {
                    Button("Ask again next time") { set(.notDecided, capability: capability) }
                        .accessibilityIdentifier("iris.permissions.reset.\(capability)")
                }
            }
            .font(.caption)
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .accessibilityIdentifier("iris.permissions.row.\(capability)")
        .accessibilityElement(children: .combine)
    }

    private func set(_ decision: NativePermissionDecision, capability: String) {
        do {
            try store.setDecision(decision, for: capability, identity: identity)
            refresh()
        } catch {
            // The store already failed closed (kept the previous decision on
            // disk); reflect exactly what is actually stored rather than
            // guessing that the tap succeeded.
            refresh()
        }
    }

    private func refresh() {
        var next: [String: NativePermissionDecision] = [:]
        for capability in eligibleCapabilities {
            next[capability] = store.decision(for: capability, identity: identity)
        }
        decisions = next
    }

    /// Every capability this screen knows how to explain and remember a
    /// decision for. A capability absent here is never shown, even if it
    /// happens to be requested; `NativeCapabilityDisclosure` still discloses
    /// it plainly.
    private static let knownCapabilities: [String] = [NativePermissionCapability.camera]

    private static func label(for capability: String) -> String {
        switch capability {
        case NativePermissionCapability.camera: return "Camera"
        default: return capability
        }
    }

    private static func statusText(_ decision: NativePermissionDecision) -> String {
        switch decision {
        case .granted: return "Allowed for this app."
        case .denied: return "Not allowed for this app."
        case .notDecided: return "Not decided yet. Iris will ask the first time this app tries to use it."
        }
    }
}
#endif
