//
//  GroundingLabMain.swift
//  grounding-lab
//
//  Entry point, argument parsing, and the startup permission gate.
//

import ApplicationServices
import CoreGraphics
import Foundation

struct CommandLineOptions {
    var subcommand: String = ""
    var bundleIdentifier: String?
    var useFrontmostApplication = false
    var outputDirectory: URL?
    var datasetPath: String?
    var resultsPath: String?
    var arms: [String] = ["ax"]
    /// Cost control: never spend more than this many targets' worth of API
    /// calls unless the caller says so. 0 disables the cap.
    var limit: Int = 40
    var model: String = "claude-haiku-4-5"
    var hitPaddingInPoints: Double = Scoring.defaultHitPaddingInPoints
    var settleSeconds: Double = 1.2
}

@main
struct GroundingLabMain {

    static func main() async {
        do {
            let options = try parseArguments(Array(CommandLine.arguments.dropFirst()))
            switch options.subcommand {
            case "capture":
                try requirePermissions(needsScreenRecording: true)
                try await CaptureCommand.run(options: options)
            case "run":
                // The ax arm reads the accessibility tree; the claude arms only
                // read a PNG off disk. Screen recording is only required when a
                // fresh capture happens, so `run` checks accessibility only.
                try requirePermissions(needsScreenRecording: false)
                try await RunCommand.run(options: options)
            case "help", "--help", "-h", "":
                printUsage()
            default:
                FileHandle.standardError.write(Data("Unknown subcommand '\(options.subcommand)'.\n".utf8))
                printUsage()
                exit(2)
            }
        } catch {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    // MARK: - Permissions

    enum PermissionError: LocalizedError {
        case screenRecordingDenied
        case accessibilityDenied

        var errorDescription: String? {
            switch self {
            case .screenRecordingDenied:
                return """
                    Screen Recording permission is missing, so every capture would \
                    be silently blank. Grant it to the terminal you are running \
                    from: System Settings > Privacy & Security > Screen & System \
                    Audio Recording, then restart the terminal.
                    """
            case .accessibilityDenied:
                return """
                    Accessibility permission is missing, so the accessibility tree \
                    would come back empty and every dataset would have zero \
                    targets. Grant it to the terminal you are running from: \
                    System Settings > Privacy & Security > Accessibility, then \
                    restart the terminal.
                    """
            }
        }
    }

    /// Checked up front and loudly, because both failures produce empty results
    /// rather than errors — a silently empty dataset looks like a walker bug.
    static func requirePermissions(needsScreenRecording: Bool) throws {
        if needsScreenRecording && !CGPreflightScreenCaptureAccess() {
            throw PermissionError.screenRecordingDenied
        }
        if !AXIsProcessTrusted() {
            throw PermissionError.accessibilityDenied
        }
    }

    // MARK: - Arguments

    static func parseArguments(_ arguments: [String]) throws -> CommandLineOptions {
        var options = CommandLineOptions()
        guard let first = arguments.first else { return options }
        options.subcommand = first

        var index = 1
        while index < arguments.count {
            let flag = arguments[index]
            func nextValue() throws -> String {
                guard index + 1 < arguments.count else {
                    throw ArgumentError.missingValue(flag)
                }
                index += 1
                return arguments[index]
            }

            switch flag {
            case "--bundle-id":
                options.bundleIdentifier = try nextValue()
            case "--frontmost":
                options.useFrontmostApplication = true
            case "--out":
                options.outputDirectory = URL(fileURLWithPath: try nextValue())
            case "--dataset":
                options.datasetPath = try nextValue()
            case "--results":
                options.resultsPath = try nextValue()
            case "--arm":
                options.arms = try nextValue()
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
            case "--limit":
                options.limit = Int(try nextValue()) ?? options.limit
            case "--model":
                options.model = try nextValue()
            case "--hit-padding":
                options.hitPaddingInPoints = Double(try nextValue()) ?? options.hitPaddingInPoints
            case "--settle-seconds":
                options.settleSeconds = Double(try nextValue()) ?? options.settleSeconds
            default:
                throw ArgumentError.unknownFlag(flag)
            }
            index += 1
        }

        if options.subcommand == "capture",
           options.bundleIdentifier == nil,
           !options.useFrontmostApplication {
            throw ArgumentError.missingValue("--bundle-id (or --frontmost)")
        }
        return options
    }

    enum ArgumentError: LocalizedError {
        case unknownFlag(String)
        case missingValue(String)

        var errorDescription: String? {
            switch self {
            case .unknownFlag(let flag):
                return "Unknown flag \(flag). Run `grounding-lab help`."
            case .missingValue(let flag):
                return "Missing value for \(flag)."
            }
        }
    }

    static func printUsage() {
        print("""
            grounding-lab — measure how accurately a model can point at real macOS UI,
            using the accessibility tree as automatically generated ground truth.

            USAGE
              grounding-lab capture --bundle-id <id> | --frontmost [--out <dir>] [--settle-seconds <s>]
              grounding-lab run --dataset <path/to/dataset.json> --arm <ax|claude|claude-verify>
                                [--limit <n>] [--model <id>] [--hit-padding <pt>] [--results <path>]

            ARMS
              ax             Resolve each instruction against the live accessibility tree.
                             Makes no API calls. Its real output is COVERAGE.
              claude         Send the screenshot + instruction to Anthropic's computer-use
                             tool and parse the coordinate back.
              claude-verify  Draw a crosshair at a proposed point and ask the model whether
                             it is on the target. One on-target probe and one decoy probe
                             per target, so guessing "yes" scores 50%.

            COST CONTROL
              --limit defaults to 40 targets per run (--limit 0 disables the cap).
              The estimated cost is printed before any API call is made.
              ANTHROPIC_API_KEY is read from the environment and never printed.

            EXAMPLE
              set -a; source /Users/you/publik/.env.local; set +a
              swift build
              .build/debug/grounding-lab capture --bundle-id com.apple.Safari --out ./run1
              .build/debug/grounding-lab run --dataset ./run1/dataset.json --arm ax --limit 0
              .build/debug/grounding-lab run --dataset ./run1/dataset.json --arm claude --limit 10
            """)
    }
}
