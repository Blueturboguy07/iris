#if os(iOS)
import IrisMobileShellCore
import SwiftUI

@MainActor
final class NativeShellUsageModel: ObservableObject {
    enum ControlAction: Sendable { case enable, pause, resume, revokeAndDelete }

    @Published private(set) var snapshot: NativeUsageSnapshot?
    @Published private(set) var isChanging = false
    @Published private(set) var errorMessage: String?
    private let service: NativeUsageService?

    init(service: NativeUsageService?) {
        self.service = service
        snapshot = service?.snapshot()
    }

    func refresh() { snapshot = service?.snapshot() }

    func perform(_ action: ControlAction) {
        guard let service, !isChanging else { return }
        isChanging = true
        errorMessage = nil
        Task {
            do {
                let updated = try await Task.detached(priority: .utility) {
                    switch action {
                    case .enable: try service.grantConsent()
                    case .pause: try service.pause()
                    case .resume: try service.resume()
                    case .revokeAndDelete: try service.revokeAndDelete()
                    }
                    return service.snapshot()
                }.value
                snapshot = updated
            } catch {
                snapshot = service.snapshot()
                errorMessage = "The local usage setting could not be saved. Recording is not assumed to be enabled."
            }
            isChanging = false
        }
    }
}

struct NativeShellUsageSection: View {
    @ObservedObject var model: NativeShellUsageModel
    @State private var showCounts = false
    @State private var confirmDelete = false

    var body: some View {
        Section("Local usage") {
            if let snapshot = model.snapshot {
                Label(status(snapshot.consentState), systemImage: snapshot.consentState == .enabled ? "chart.bar" : "hand.raised")
                    .accessibilityIdentifier("iris.usage.status")
                Text("Optional, on this device only. Records shell setup and app-load outcomes with local app identifiers. No screenshots, typing, app content, or uploads. It does not observe actions inside downloaded apps.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("Storage is capped. Old detail and summaries are pruned during later collection, not by a background timer while the app is idle or closed. Turn off & delete removes the local records immediately when the action completes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if snapshot.storeHealth != .healthy {
                    Text("Local usage records are unavailable. Existing records are not silently replaced; explicit deletion is available below.")
                        .font(.footnote)
                        .accessibilityIdentifier("iris.usage.unavailable")
                }

                switch snapshot.consentState {
                case .disabled:
                    Button("Turn on local usage") { model.perform(.enable) }
                        .accessibilityIdentifier("iris.usage.enable")
                        .disabled(model.isChanging || snapshot.storeHealth != .healthy)
                case .enabled:
                    Button("Pause local usage") { model.perform(.pause) }
                        .accessibilityIdentifier("iris.usage.pause")
                        .disabled(model.isChanging)
                case .paused:
                    Text("Paused. Pending events were cleared; previously saved records remain until deleted or expired.")
                        .font(.caption)
                    Button("Resume local usage") { model.perform(.resume) }
                        .accessibilityIdentifier("iris.usage.resume")
                        .disabled(model.isChanging || snapshot.storeHealth != .healthy)
                case .unknown:
                    Text("Consent could not be verified. Recording stays off.").font(.footnote)
                }

                if snapshot.consentState != .disabled || snapshot.storeHealth != .healthy {
                    Button("Turn off & delete local usage", role: .destructive) { confirmDelete = true }
                        .accessibilityIdentifier("iris.usage.delete")
                        .disabled(model.isChanging)
                        .confirmationDialog("Turn off usage tracking and delete this shell's local usage records?", isPresented: $confirmDelete, titleVisibility: .visible) {
                            Button("Turn off & delete", role: .destructive) { model.perform(.revokeAndDelete) }
                                .accessibilityIdentifier("iris.usage.confirm-delete")
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text("Downloaded apps and their package files are not deleted. This does not claim forensic erasure from device backups.")
                        }
                }

                Button(showCounts ? "Refresh local counts" : "Inspect local counts") {
                    model.refresh()
                    showCounts = true
                }
                .accessibilityIdentifier("iris.usage.inspect")
                .disabled(model.isChanging)

                if showCounts {
                    counts(snapshot)
                }
            } else {
                Text("Usage observation is not configured. Nothing is collected.").font(.footnote)
            }

            if model.isChanging { ProgressView("Saving local setting…") }
            if let errorMessage = model.errorMessage {
                Text(errorMessage).font(.footnote)
                    .accessibilityIdentifier("iris.usage.error")
            }
        }
    }

    @ViewBuilder
    private func counts(_ snapshot: NativeUsageSnapshot) -> some View {
        LabeledContent("Pending events", value: "\(snapshot.pendingEventCount)")
            .accessibilityIdentifier("iris.usage.pending")
        LabeledContent("Retained events", value: "\(snapshot.retainedRawEventCount)")
            .accessibilityIdentifier("iris.usage.retained")
        LabeledContent("Saved summary days", value: "\(snapshot.retainedSummaryDayCount)")
        Text("Saved counts are a snapshot, not a live activity monitor. Missing outcomes and dropped records do not imply inactivity or successful use.")
            .font(.caption)
            .foregroundStyle(.secondary)
        let counters = snapshot.counters
        Text("Queue loss: \(counters.droppedQueueFull) · Rate-limited: \(counters.droppedRateLimited) · Stale consent: \(counters.droppedStaleConsentEpoch)")
            .font(.caption)
            .accessibilityIdentifier("iris.usage.loss")
        ForEach(Array(snapshot.dailySummaries.suffix(3).enumerated()), id: \.offset) { _, day in
            DisclosureGroup("\(dayLabel(day.dayOrdinalUTC)): \(day.eventCounts.count) action categories") {
                ForEach(Array(day.eventCounts.prefix(32).enumerated()), id: \.offset) { _, count in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(eventLabel(count.eventKind))
                        Text("\(count.identity.appId) · \(count.outcome?.rawValue ?? "observed") · \(count.count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if day.eventCounts.count > 32 {
                    Text("Showing the first 32 categories for this day.").font(.caption)
                }
            }
        }
    }

    private func status(_ state: NativeUsageConsentState) -> String {
        switch state {
        case .disabled: return "Off · no collection"
        case .enabled: return "On · local only · no uploads"
        case .paused: return "Paused · no collection"
        case .unknown: return "Unavailable · collection off"
        }
    }

    private func dayLabel(_ ordinal: Int64) -> String {
        let date = Date(timeIntervalSince1970: Double(ordinal) * 86_400)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "MMM d, yyyy 'UTC'"
        return formatter.string(from: date)
    }

    private func eventLabel(_ kind: NativeUsageEventKind) -> String {
        switch kind {
        case .catalogLoadAttempt: return "Catalogue requested"
        case .catalogLoadOutcome: return "Catalogue result"
        case .downloadAttempt: return "Download requested"
        case .downloadOutcome: return "Download result"
        case .reviewAttempt: return "Package review requested"
        case .reviewOutcome: return "Package review result"
        case .stageAttempt: return "Setup requested"
        case .stageOutcome: return "Setup result"
        case .activateAttempt: return "Activation requested"
        case .activateOutcome: return "Activation result"
        case .openRequest: return "App open requested"
        case .openLoaded: return "App page finished loading"
        case .openLoadEnded: return "App open did not finish"
        case .closeAttempt: return "App close requested"
        case .closeOutcome: return "App view closed"
        }
    }
}
#endif
