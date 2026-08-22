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

    /// `log show` over the lookback window for this process, tail-bounded and
    /// scrubbed. The predicate ORs the process name with the bundle id as
    /// subsystem, so apps that log through os_log subsystems are caught too.
    private static func unifiedLogTail(processName: String, macBundleId: String) async -> String? {
        let predicate = "process == \"\(processName)\" OR subsystem == \"\(macBundleId)\""
        let output = await runProcessCollectingOutput(
            executablePath: "/usr/bin/log",
            arguments: [
                "show",
                "--last", "\(unifiedLogLookbackMinutes)m",
                "--style", "compact",
                "--predicate", predicate,
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
    /// window, excerpted from the TOP (an .ips report's header + exception
    /// info lead the file) and scrubbed.
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
        return String(GuideAutopilotOutputBuffer.scrubbed(contents).prefix(maximumCrashReportCharacters))
    }

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
