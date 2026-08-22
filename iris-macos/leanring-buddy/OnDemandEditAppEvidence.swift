//
//  OnDemandEditAppEvidence.swift
//  leanring-buddy
//
//  Runtime evidence for an on-demand edit, gathered the moment the run starts:
//  what the RUNNING app is doing right now. Until this existed the edit agent
//  worked blind — it never saw the screen the user was describing and never
//  saw a line the app logged, and had to deduce runtime behavior cold from
//  source (the Aug 22 accessibility bug is the canonical case: the app's own
//  log showed the stale permission check directly).
//
//  Two pieces, both best-effort and both optional:
//    - a screenshot of the app's frontmost window (ScreenCaptureKit — the same
//      framework and Screen Recording grant the chat pipeline already uses),
//      attached to the opening turn as a real image block on the reader's own
//      model route;
//    - a scrubbed tail of the app's unified-log output plus an excerpt of its
//      most recent crash report, appended to the opening message as text.
//
//  Both text sources were widened after the agent kept receiving evidence
//  that contained no cause. The log predicate now also covers
//  `com.apple.TCC` and `com.apple.syspolicy` — a permission denial or a
//  Gatekeeper verdict is logged by THOSE subsystems, never by the app, which
//  only sees a silent nil — and the read passes `--info`, without which
//  those subsystems' lines are filtered out before the predicate sees them.
//  The crash-report excerpt is taken around the termination/exception line
//  rather than off the top of the file, because a modern .ips report opens
//  with a long JSON header and the old head-of-file excerpt was routinely
//  all header and no reason. It is also the one place the jail cannot help:
//  `/usr/bin/log` refuses to run sandboxed, so this read happens here, on
//  Iris's side of the jail, and travels to the model as text.
//
//  Privacy posture: everything model-bound is scrubbed with the same scrubber
//  every other egress path uses, it travels ONLY on the reader's own BYO model
//  route (the funded proxy structurally cannot run edits), and the gathering
//  happens strictly inside a run the reader explicitly started and consented
//  to. A missing permission, a not-running app, or a slow `log show` yields
//  nil — never an error the run can feel.
//

import AppKit
import Foundation
import ScreenCaptureKit

/// What was gathered for one run. Either field may be nil; the run proceeds
/// identically either way (just blinder).
struct OnDemandEditRuntimeEvidence: Sendable {
    let runtimeLogText: String?
    let appWindowScreenshotPNG: Data?
}

@MainActor
enum OnDemandEditAppEvidence {

    /// How far back the unified-log read looks. Long enough to catch the
    /// behavior the reader just saw; short enough that `log show` stays fast.
    static let unifiedLogLookbackMinutes = 10
    /// The most log lines kept, from the END (where the just-seen behavior is).
    static let maximumLogLines = 120
    /// Character caps keeping the opening message sane.
    static let maximumLogCharacters = 5000
    static let maximumCrashReportCharacters = 2500
    /// How much of a crash report is kept around the line that says WHY the
    /// process died. A modern .ips report opens with a long JSON header
    /// (hardware model, OS build, timestamps, code-signing ids), so the first
    /// 2500 characters were routinely all header and no cause — the excerpt
    /// arrived at the model saying nothing. A window around the termination
    /// line carries the reason, the exception, and the top of the crashing
    /// thread's stack instead.
    static let crashReportLinesKeptBeforeTerminationMarker = 8
    static let crashReportLinesKeptAfterTerminationMarker = 32
    /// A crash report older than this says nothing about the current problem.
    static let crashReportMaximumAgeSeconds: TimeInterval = 24 * 60 * 60
    /// The widest the attached screenshot may be, in pixels — plenty to read
    /// UI text, small enough to stay a few hundred KB.
    static let maximumScreenshotPixelWidth = 1400

    // MARK: - The one-call entry the coordinator's seam uses

    /// Gather both pieces concurrently. `macBundleId` may be nil (an app publik
    /// has no bundle id for) — then only nothing can be gathered, honestly.
    static func gather(macBundleId: String?) async -> OnDemandEditRuntimeEvidence {
        guard let macBundleId, !macBundleId.isEmpty else {
            return OnDemandEditRuntimeEvidence(runtimeLogText: nil, appWindowScreenshotPNG: nil)
        }
        async let screenshotPNG = captureFrontWindowPNG(macBundleId: macBundleId)
        async let runtimeLogText = recentRuntimeLogText(macBundleId: macBundleId)
        return await OnDemandEditRuntimeEvidence(
            runtimeLogText: runtimeLogText,
            appWindowScreenshotPNG: screenshotPNG
        )
    }

    // MARK: - Unified log + crash report (text)

    /// The app's recent log tail + newest crash-report excerpt, composed and
    /// scrubbed. Nil when neither source produced anything.
    static func recentRuntimeLogText(macBundleId: String) async -> String? {
        let processName = executableName(forBundleId: macBundleId)
        let logTail = await unifiedLogTail(processName: processName, macBundleId: macBundleId)
        let crashExcerpt = recentCrashReportExcerpt(processName: processName)
        return composedRuntimeContext(logTail: logTail, crashReportExcerpt: crashExcerpt)
    }

    /// The pure composition the tests pin: sections only for what exists, nil
    /// when both are empty so the caller appends nothing.
    nonisolated static func composedRuntimeContext(
        logTail: String?, crashReportExcerpt: String?
    ) -> String? {
        var sections: [String] = []
        if let logTail, !logTail.isEmpty {
            sections.append("App log tail (most recent last):\n\(logTail)")
        }
        if let crashReportExcerpt, !crashReportExcerpt.isEmpty {
            sections.append("Most recent crash report (excerpt):\n\(crashReportExcerpt)")
        }
        return sections.isEmpty ? nil : sections.joined(separator: "\n\n")
    }

    /// The app's CFBundleExecutable — the `process` name the unified log and
    /// the crash-report filenames both key on. Falls back to the running app's
    /// name, then the bundle id's last component.
    private static func executableName(forBundleId macBundleId: String) -> String {
        if let applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: macBundleId),
           let bundle = Bundle(url: applicationURL),
           let executable = bundle.infoDictionary?["CFBundleExecutable"] as? String,
           !executable.isEmpty {
            return executable
        }
        if let running = NSRunningApplication
            .runningApplications(withBundleIdentifier: macBundleId).first,
           let name = running.localizedName, !name.isEmpty {
            return name
        }
        return macBundleId.components(separatedBy: ".").last ?? macBundleId
    }

    /// The predicate `log show` runs with. Pure and nonisolated so the shape
    /// is pinned by tests rather than by reading the command in the debugger.
    ///
    /// Four ORed terms, because the line that explains a failure is rarely
    /// logged by the app itself: the app's own process and os_log subsystem,
    /// plus `com.apple.TCC` (the subsystem that records a permission denial —
    /// the app sees only a silent nil) and `com.apple.syspolicy` (Gatekeeper,
    /// notarization, and quarantine verdicts, which the app never sees at
    /// all).
    nonisolated static func unifiedLogPredicate(
        processName: String, macBundleId: String
    ) -> String {
        let terms = [
            "process == \"\(processName)\"",
            "subsystem == \"\(macBundleId)\"",
            "subsystem == \"com.apple.TCC\"",
            "subsystem == \"com.apple.syspolicy\"",
        ]
        return terms.joined(separator: " OR ")
    }

    /// `log show` over the lookback window for this process, tail-bounded and
    /// scrubbed. The predicate ORs the process name with the bundle id as
    /// subsystem, so apps that log through os_log subsystems are caught too.
    private static func unifiedLogTail(processName: String, macBundleId: String) async -> String? {
        let output = await runProcessCollectingOutput(
            executablePath: "/usr/bin/log",
            arguments: [
                "show",
                "--last", "\(unifiedLogLookbackMinutes)m",
                "--style", "compact",
                // Without --info the unified log returns only default-level
                // messages, and the two subsystems that explain a permission
                // or Gatekeeper failure log almost everything at info level —
                // so the interesting lines were being filtered out before the
                // predicate ever saw them.
                "--info",
                "--predicate", unifiedLogPredicate(
                    processName: processName, macBundleId: macBundleId
                ),
            ],
            timeoutSeconds: 20
        )
        guard let output else { return nil }
        let meaningfulLines = output
            .components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .suffix(maximumLogLines)
        guard !meaningfulLines.isEmpty else { return nil }
        let joined = meaningfulLines.joined(separator: "\n")
        return String(GuideAutopilotOutputBuffer.scrubbed(joined).suffix(maximumLogCharacters))
    }

    /// The newest DiagnosticReports file for this process within the age
    /// window, excerpted around the line that says why the process died, and
    /// scrubbed.
    private static func recentCrashReportExcerpt(processName: String) -> String? {
        let reportsDirectory = (NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/Logs/DiagnosticReports")
        guard let fileNames = try? FileManager.default
            .contentsOfDirectory(atPath: reportsDirectory) else { return nil }

        let candidates = fileNames
            .filter { $0.hasPrefix(processName + "-") || $0.hasPrefix(processName + ".") }
            .compactMap { fileName -> (path: String, modified: Date)? in
                let path = (reportsDirectory as NSString).appendingPathComponent(fileName)
                guard let modified = (try? FileManager.default
                    .attributesOfItem(atPath: path))?[.modificationDate] as? Date else { return nil }
                return (path, modified)
            }
            .filter { Date().timeIntervalSince($0.modified) <= crashReportMaximumAgeSeconds }
            .sorted { $0.modified > $1.modified }

        guard let newest = candidates.first,
              let contents = try? String(contentsOfFile: newest.path, encoding: .utf8) else {
            return nil
        }
        let terminationRegion = terminationRegionExcerpt(fromCrashReportText: contents)
        return String(
            GuideAutopilotOutputBuffer.scrubbed(terminationRegion)
                .prefix(maximumCrashReportCharacters)
        )
    }

    /// The lines of a crash report that say WHY it crashed.
    ///
    /// Finds the first line mentioning any termination marker and returns a
    /// window around it. Falls back to the whole text (the caller still caps
    /// it, so that is the old head-of-file behavior) when no marker is
    /// present — better a header than nothing, and a report shaped in a way
    /// this does not recognize should degrade, not disappear.
    nonisolated static func terminationRegionExcerpt(
        fromCrashReportText reportText: String
    ) -> String {
        let lines = reportText.components(separatedBy: .newlines)
        guard let firstMarkerLineIndex = lines.firstIndex(where: { line in
            let lowercasedLine = line.lowercased()
            return crashReportTerminationMarkers.contains { marker in
                lowercasedLine.contains(marker.lowercased())
            }
        }) else {
            return reportText
        }

        let windowStart = max(0, firstMarkerLineIndex - crashReportLinesKeptBeforeTerminationMarker)
        let windowEnd = min(
            lines.count,
            firstMarkerLineIndex + crashReportLinesKeptAfterTerminationMarker + 1
        )
        return lines[windowStart..<windowEnd].joined(separator: "\n")
    }

    /// The phrases that mark the part of a crash report worth reading. Every
    /// one of them names a cause: why the OS killed it, what exception was
    /// raised, which library failed to load, an architecture mismatch, a Rust
    /// panic, or which thread went down.
    nonisolated static let crashReportTerminationMarkers = [
        "Termination Reason",
        "Exception Type",
        "exception",
        "Library not loaded",
        "incompatible architecture",
        "panicked at",
        "Crashed Thread",
    ]

    /// A tiny direct process runner. Deliberately NOT `MaintainShellRunner`
    /// (that is the repo-confined verification runner) and not the pty shell
    /// (that is interactive theater): `log show` is Iris's own read of system
    /// state, argv-array invoked with no shell at all.
    private static func runProcessCollectingOutput(
        executablePath: String, arguments: [String], timeoutSeconds: TimeInterval
    ) async -> String? {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()

            let timeoutWork = DispatchWorkItem {
                if process.isRunning { process.terminate() }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds, execute: timeoutWork)

            process.terminationHandler = { _ in
                timeoutWork.cancel()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: String(data: data, encoding: .utf8))
            }
            do {
                try process.run()
            } catch {
                timeoutWork.cancel()
                continuation.resume(returning: nil)
            }
        }
    }

    // MARK: - Window screenshot (image)

    /// A PNG of the app's frontmost on-screen window, scaled to at most
    /// `maximumScreenshotPixelWidth`. Nil when the app has no visible window,
    /// Screen Recording is not granted, or capture fails for any reason.
    static func captureFrontWindowPNG(macBundleId: String) async -> Data? {
        guard let shareableContent = try? await SCShareableContent
            .excludingDesktopWindows(true, onScreenWindowsOnly: true) else { return nil }

        // The app's largest on-screen window — the one the reader means. Tiny
        // windows (status items, tooltips) are skipped by the area sort.
        let appWindows = shareableContent.windows.filter { window in
            window.owningApplication?.bundleIdentifier == macBundleId
                && window.isOnScreen
                && window.frame.width >= 200 && window.frame.height >= 150
        }
        guard let window = appWindows.max(by: {
            $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height
        }) else { return nil }

        let configuration = SCStreamConfiguration()
        let scale = min(1.0, CGFloat(maximumScreenshotPixelWidth) / window.frame.width)
        configuration.width = Int(window.frame.width * scale)
        configuration.height = Int(window.frame.height * scale)
        configuration.showsCursor = false

        guard let capturedImage = try? await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(desktopIndependentWindow: window),
            configuration: configuration
        ) else { return nil }

        let bitmapRepresentation = NSBitmapImageRep(cgImage: capturedImage)
        return bitmapRepresentation.representation(using: .png, properties: [:])
    }
}
