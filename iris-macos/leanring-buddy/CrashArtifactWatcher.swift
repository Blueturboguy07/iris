//
//  CrashArtifactWatcher.swift
//  leanring-buddy
//
//  The always-on, zero-cost layer of maintain mode: notices when macOS writes
//  a crash report for one of our apps. Nothing here polls, screenshots, or
//  spends a token — ReportCrash does the work and this file listens.
//
//  Two co-equal paths, deliberately redundant:
//
//    fast     the distributed notification `com.apple.ReportCrash.crash`,
//             which fires the instant a report is written and names the file.
//             It is PRIVATE API surface — undocumented, and free to vanish in
//             any macOS release — so it is never the only path.
//
//    sure     a kqueue watch on ~/Library/Logs/DiagnosticReports. Public,
//             stable, slightly slower. If the notification path goes silent
//             in some future macOS, this one still fires and nothing above
//             this file notices the difference.
//
//  Both paths funnel through one dedupe (by file path), so a crash seen by
//  both reports once. Reading the reports directory needs no TCC grant for
//  the logged-in user's own reports; a read failure is surfaced as a
//  capability signal, never a crash of our own.
//

import AppKit
import Foundation

/// One crash artifact, parsed and matched to a catalog app.
struct DetectedCrashArtifact: Sendable {
    let fileURL: URL
    let report: ParsedCrashReport
    /// Set when the crashed process matched an installed catalog app.
    let catalogAppSlug: String
    let catalogAppStack: BreakAppStack
    /// True when an NSWorkspace termination for the same app landed within
    /// the correlation window — timing evidence only, never a diagnosis.
    let correlatedWithTermination: Bool
}

/// How the watcher decides whether a crash report belongs to one of ours.
/// `AppInventoryService` provides the real answer; tests provide a fake.
@MainActor
protocol CrashArtifactAppMatching: AnyObject {
    /// Returns (slug, stack) when the process name or bundle id names an
    /// installed catalog app; nil for everything else on the machine.
    func catalogApp(forProcessName processName: String, bundleIdentifier: String?) -> (slug: String, stack: BreakAppStack)?
}

@MainActor
final class CrashArtifactWatcher {

    /// New artifacts land here, on the main actor. The incident coordinator
    /// owns what happens next (ask the user, never act on its own).
    var onCrashArtifactDetected: ((DetectedCrashArtifact) -> Void)?

    private let appMatcher: CrashArtifactAppMatching
    private let reportsDirectoryURL: URL

    /// Paths already delivered, so the notification and the kqueue path
    /// cannot double-report one crash. Bounded; a session that sees hundreds
    /// of crashes has bigger problems than this set's memory.
    private var deliveredReportPaths: Set<String> = []
    private static let maximumRememberedPaths = 512

    /// App names that terminated recently, with when — the correlation
    /// window for `correlatedWithTermination`.
    private var recentTerminationsByProcessName: [String: Date] = [:]
    private static let terminationCorrelationWindow: TimeInterval = 20

    private var directoryDescriptor: CInt = -1
    private var directorySource: DispatchSourceFileSystemObject?
    private var distributedObserver: NSObjectProtocol?
    private var terminationObserver: NSObjectProtocol?

    /// Files present before the watch started are old news: asking a user
    /// about a crash from last week teaches them to ignore the asks.
    private var pathsPresentAtStart: Set<String> = []

    init(
        appMatcher: CrashArtifactAppMatching,
        reportsDirectoryURL: URL = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DiagnosticReports")
    ) {
        self.appMatcher = appMatcher
        self.reportsDirectoryURL = reportsDirectoryURL
    }

    func start() {
        pathsPresentAtStart = Set(listCurrentReportPaths())

        // Fast path: the private notification. userInfo carries the paths in
        // "logfiles"; shape unverified across releases, so everything about
        // it is optional and the kqueue path below is the guarantee.
        distributedObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.ReportCrash.crash"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self else { return }
                let paths = (notification.userInfo?["logfiles"] as? [String])
                    ?? (notification.userInfo?["logfiles"] as? String).map { [$0] }
                    ?? []
                for path in paths where path.hasSuffix(".ips") {
                    self.considerReport(atPath: path)
                }
                // Whatever the payload shape, a scan is cheap and certain.
                self.scanForNewReports()
            }
        }

        // Sure path: a kqueue vnode source on the directory. A new report is
        // a directory write; the scan diff finds which file it was.
        directoryDescriptor = open(reportsDirectoryURL.path, O_EVTONLY)
        if directoryDescriptor >= 0 {
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: directoryDescriptor,
                eventMask: .write,
                queue: .main
            )
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.scanForNewReports() }
            }
            source.setCancelHandler { [descriptor = directoryDescriptor] in
                close(descriptor)
            }
            source.resume()
            directorySource = source
        }

        // Termination timing, for correlation only. The notification carries
        // no exit status — treating it as a crash signal on its own would
        // fire on every normal quit.
        terminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self,
                      let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      let name = application.localizedName else { return }
                self.recentTerminationsByProcessName[name] = Date()
                self.pruneOldTerminations()
            }
        }
    }

    func stop() {
        if let distributedObserver {
            DistributedNotificationCenter.default().removeObserver(distributedObserver)
        }
        distributedObserver = nil
        if let terminationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(terminationObserver)
        }
        terminationObserver = nil
        directorySource?.cancel()
        directorySource = nil
        directoryDescriptor = -1
    }

    // MARK: - Scanning and delivery

    private func listCurrentReportPaths() -> [String] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: reportsDirectoryURL, includingPropertiesForKeys: nil
        )) ?? []
        return contents.map(\.path).filter { $0.hasSuffix(".ips") }
    }

    private func scanForNewReports() {
        for path in listCurrentReportPaths()
        where !pathsPresentAtStart.contains(path) && !deliveredReportPaths.contains(path) {
            considerReport(atPath: path)
        }
    }

    private func considerReport(atPath path: String) {
        guard !deliveredReportPaths.contains(path), !pathsPresentAtStart.contains(path) else { return }
        rememberDelivered(path)

        // ReportCrash may still be flushing when the notification lands; a
        // half-written file parses as garbage. One short retry covers it.
        guard let text = try? String(contentsOfFile: path, encoding: .utf8),
              let report = try? BreakSignatureService.parseCrashReport(fromIPSText: text) else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self,
                          let text = try? String(contentsOfFile: path, encoding: .utf8),
                          let report = try? BreakSignatureService.parseCrashReport(fromIPSText: text) else { return }
                    self.deliverIfCatalogApp(report: report, path: path)
                }
            }
            return
        }
        deliverIfCatalogApp(report: report, path: path)
    }

    private func deliverIfCatalogApp(report: ParsedCrashReport, path: String) {
        // Everything on this machine crashes sometimes; only our apps are
        // maintain mode's business. Anything else is dropped unread beyond
        // the header — no storage, no signal, no memory of it.
        guard let match = appMatcher.catalogApp(
            forProcessName: report.appName,
            bundleIdentifier: report.bundleIdentifier
        ) else {
            // Traced, because "the matcher said no" and "the watcher never
            // saw the file" are indistinguishable from silence — and the
            // first live test lost an hour to exactly that. Name only; the
            // report itself stays unread past the header.
            irisTrace("maintain: crash artifact ignored (\(report.appName) is not an installed catalog app)")
            return
        }

        let correlated = recentTerminationsByProcessName[report.appName].map {
            Date().timeIntervalSince($0) < Self.terminationCorrelationWindow
        } ?? false

        irisTrace("maintain: crash artifact for \(match.slug) at \(path.hasSuffix(".ips") ? (path as NSString).lastPathComponent : "?") correlated=\(correlated)")
        onCrashArtifactDetected?(DetectedCrashArtifact(
            fileURL: URL(fileURLWithPath: path),
            report: report,
            catalogAppSlug: match.slug,
            catalogAppStack: match.stack,
            correlatedWithTermination: correlated
        ))
    }

    private func rememberDelivered(_ path: String) {
        deliveredReportPaths.insert(path)
        if deliveredReportPaths.count > Self.maximumRememberedPaths {
            deliveredReportPaths.removeAll()
            pathsPresentAtStart = Set(listCurrentReportPaths())
        }
    }

    private func pruneOldTerminations() {
        let cutoff = Date().addingTimeInterval(-Self.terminationCorrelationWindow * 2)
        recentTerminationsByProcessName = recentTerminationsByProcessName.filter { $0.value > cutoff }
    }
}
