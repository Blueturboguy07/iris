//
//  IrisGuideModels.swift
//  leanring-buddy
//
//  The shape of a guide as `GET /api/iris/guides/{slug}` serves it. These
//  mirror the TypeScript types at the top of `lib/iris-guides.ts` — IrisGuide,
//  IrisGuideBranch, IrisGuideStep, IrisUnsupportedPair — field for field, so a
//  change on the website surfaces here as a decode failure rather than as a
//  quietly missing value.
//

import Foundation

enum IrisPlatform: String, Codable, Equatable, Sendable {
    case macos
    case windows

    /// What the platform switch shows for this computer.
    var displayLabel: String {
        switch self {
        case .macos: return "macOS"
        case .windows: return "Windows"
        }
    }
}

/// The phone an app is built for. Mobile guides branch on the *pair* of
/// computer and phone, not on the computer alone: the same Mac produces a
/// completely different install path for an iPhone than for an Android, and one
/// pair (Windows + iPhone) has no valid path at all.
enum IrisMobileTarget: String, Codable, Equatable, Sendable {
    case ios
    case android
}

enum IrisGuideStatus: String, Codable, Equatable, Sendable {
    case pilot
    case approved
    case review

    /// The API refuses to serve anything else, so this mirrors the route's
    /// 403 condition in `app/api/iris/guides/[slug]/route.ts`.
    var isPublished: Bool {
        self == .pilot || self == .approved
    }
}

enum IrisStepKind: String, Codable, Equatable, Sendable {
    case check
    case terminal
    case open
    case permission
    case verify
    /// Do something on a web page — sign in, click a button, copy a value.
    case web
    /// Move a secret from where it was created into where it is used.
    case paste
}

enum IrisGuideShell: String, Codable, Equatable, Sendable {
    case terminal
    case powershell
}

enum IrisGuideOutputType: String, Codable, Equatable, Sendable {
    case desktopApp = "desktop_app"
    case localWeb = "local_web"
    case mobileApp = "mobile_app"
    /// A flow that produces a credential rather than an installed app — see
    /// `IRIS_FLOWS` in `lib/iris-guides.ts`. Decoding is strict here, so a
    /// value missing from this enum does not degrade: the whole flow fails to
    /// load and the reader gets nothing.
    case credential
}

/// The only two tools a step can ask Iris to verify for the reader.
enum IrisStepTool: String, Codable, Equatable, Sendable {
    case git
    case node
}

/// Why a computer/phone pair has no install route, shown instead of steps.
struct IrisUnsupportedPair: Codable, Equatable, Sendable {
    let headline: String
    let reason: String
    let alternatives: [String]
}

/// How the desktop app can tell, without being told, that a step is done.
///
/// Mirrors `IrisStepExpectation` in `lib/iris-guides.ts` field for field: each
/// case name is the wire's `type` value, and the associated value's label is the
/// wire's key. The order below is also the order `WatchLoop` tries them in — the
/// first four are answered locally in microseconds and `visual` is the only one
/// that costs a model call, which is why a step should declare the cheapest
/// expectation that actually distinguishes done from not-done.
enum IrisStepExpectation: Equatable, Sendable {
    case foregroundApp(bundleId: String)
    case urlHost(host: String)
    case toolVersion(tool: String)
    case axElement(roleLabel: String)
    case visual(prompt: String)

    /// True for the one expectation that cannot be answered without pixels.
    var requiresLookingAtTheScreen: Bool {
        if case .visual = self {
            return true
        }
        return false
    }
}

extension IrisStepExpectation: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case bundleId
        case host
        case tool
        case roleLabel
        case prompt
    }

    /// An expectation whose `type` this build does not recognize throws, and
    /// `IrisStepWatch` drops it rather than failing the whole guide. A newer
    /// website teaching Iris a signal an older client cannot evaluate must cost
    /// that client one signal, not the entire step.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let expectationType = try container.decode(String.self, forKey: .type)
        switch expectationType {
        case "foregroundApp":
            self = .foregroundApp(bundleId: try container.decode(String.self, forKey: .bundleId))
        case "urlHost":
            self = .urlHost(host: try container.decode(String.self, forKey: .host))
        case "toolVersion":
            self = .toolVersion(tool: try container.decode(String.self, forKey: .tool))
        case "axElement":
            self = .axElement(roleLabel: try container.decode(String.self, forKey: .roleLabel))
        case "visual":
            self = .visual(prompt: try container.decode(String.self, forKey: .prompt))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "unrecognized step expectation type '\(expectationType)'"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .foregroundApp(let bundleId):
            try container.encode("foregroundApp", forKey: .type)
            try container.encode(bundleId, forKey: .bundleId)
        case .urlHost(let host):
            try container.encode("urlHost", forKey: .type)
            try container.encode(host, forKey: .host)
        case .toolVersion(let tool):
            try container.encode("toolVersion", forKey: .type)
            try container.encode(tool, forKey: .tool)
        case .axElement(let roleLabel):
            try container.encode("axElement", forKey: .type)
            try container.encode(roleLabel, forKey: .roleLabel)
        case .visual(let prompt):
            try container.encode("visual", forKey: .type)
            try container.encode(prompt, forKey: .prompt)
        }
    }
}

/// Where the eye should fly while a step is open. Mirrors
/// `IrisStepPointTarget` in `lib/iris-guides.ts`.
///
/// The descriptor is text a person would use, never coordinates: coordinates
/// authored into a guide are wrong the first time anybody resizes a window,
/// and text can be matched against the accessibility tree, which is exact and
/// free for about three quarters of controls.
struct IrisStepPointTarget: Codable, Equatable, Sendable {
    let descriptor: String
    /// Iris refuses to point into an app that is not in front — an arrow
    /// hovering over a hidden window is worse than no arrow — and says
    /// "switch to X first" instead.
    let inApp: String?
    /// True when the target is a window rather than a control inside one.
    /// Command steps want this: the answer is "that Terminal", not a button.
    let isWindow: Bool?

    init(descriptor: String, inApp: String? = nil, isWindow: Bool? = nil) {
        self.descriptor = descriptor
        self.inApp = inApp
        self.isWindow = isWindow
    }
}

/// What a step tells the desktop app to watch for. Mirrors `IrisStepWatch` in
/// `lib/iris-guides.ts`.
struct IrisStepWatch: Codable, Equatable, Sendable {
    let expect: [IrisStepExpectation]

    /// Set when the screen during this step may contain something the reader
    /// would not want captured — an API key, a password, a recovery phrase.
    ///
    /// `WatchLoop` takes no screenshot at all while a sensitive step is open and
    /// decides completion from side signals only. That is what lets Iris walk
    /// somebody through creating and pasting a key it never sees.
    let sensitive: Bool

    /// Shown when the reader appears stuck, before offering to look further.
    let hints: [String]

    /// True when the step declares the one expectation that costs a model call.
    var declaresAVisualExpectation: Bool {
        expect.contains { expectation in expectation.requiresLookingAtTheScreen }
    }

    /// The prompt the visual check asks, or nil when the step declares none.
    var visualPrompt: String? {
        for expectation in expect {
            if case .visual(let prompt) = expectation {
                return prompt
            }
        }
        return nil
    }

    /// Every expectation that can be answered without looking at the screen.
    var expectationsAnsweredWithoutPixels: [IrisStepExpectation] {
        expect.filter { expectation in !expectation.requiresLookingAtTheScreen }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedExpectations = (try? container.decode(
            [LenientlyDecodedStepExpectation].self,
            forKey: .expect
        )) ?? []
        expect = decodedExpectations.compactMap { decodedExpectation in
            decodedExpectation.expectationIfThisBuildUnderstandsIt
        }
        // Absent means "not sensitive" on the wire, but the safe reading of a
        // *malformed* value is the cautious one, so anything that is not
        // explicitly `false` leaves capture off.
        sensitive = (try? container.decodeIfPresent(Bool.self, forKey: .sensitive)) ?? false
        hints = (try? container.decodeIfPresent([String].self, forKey: .hints)) ?? []
    }

    init(expect: [IrisStepExpectation], sensitive: Bool = false, hints: [String] = []) {
        self.expect = expect
        self.sensitive = sensitive
        self.hints = hints
    }
}

/// Lets one unrecognized expectation be dropped instead of taking the array —
/// and with it the step, and with it the guide — down alongside it.
private struct LenientlyDecodedStepExpectation: Decodable {
    let expectationIfThisBuildUnderstandsIt: IrisStepExpectation?

    init(from decoder: Decoder) throws {
        expectationIfThisBuildUnderstandsIt = try? IrisStepExpectation(from: decoder)
    }
}

struct IrisGuideStep: Codable, Equatable, Sendable {
    let id: String
    let kind: IrisStepKind
    let title: String
    let body: String
    let tool: IrisStepTool?
    let command: String?
    let href: String?
    let actionLabel: String?
    let verifierLabel: String?

    /// What the desktop app should watch for to decide this step is done. Nil
    /// means the reader tells Iris themselves, which is every step written
    /// before the watch loop existed — and the reason `WatchLoop` refuses to
    /// run at all for a step without one.
    let watch: IrisStepWatch?

    /// Where the eye should fly while this step is open. Nil is the common
    /// case and does not mean "point at nothing" — see `IrisStepPointTarget`
    /// and the resolution ladder in `GuidePointing.swift`.
    let point: IrisStepPointTarget?

    /// An unrecognized `kind` falls back to `terminal` rather than failing the
    /// whole guide, which is exactly what the Tauri panel's `sanitizeGuideStep`
    /// does (`iris-desktop/ui/app.js`). Losing one step's styling is a far
    /// better outcome than a reader seeing no guide at all.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        kind = (try? container.decode(IrisStepKind.self, forKey: .kind)) ?? .terminal
        title = try container.decode(String.self, forKey: .title)
        body = try container.decode(String.self, forKey: .body)
        tool = try? container.decodeIfPresent(IrisStepTool.self, forKey: .tool)
        command = try container.decodeIfPresent(String.self, forKey: .command)
        href = try container.decodeIfPresent(String.self, forKey: .href)
        actionLabel = try container.decodeIfPresent(String.self, forKey: .actionLabel)
        verifierLabel = try container.decodeIfPresent(String.self, forKey: .verifierLabel)
        // A watch block Iris cannot make sense of leaves the step unwatched
        // rather than unopenable: the reader can always still press Continue.
        watch = try? container.decodeIfPresent(IrisStepWatch.self, forKey: .watch)
        // Same reasoning as `watch`: a target Iris cannot parse costs the step
        // its arrow, not its existence.
        point = try? container.decodeIfPresent(IrisStepPointTarget.self, forKey: .point)
    }

    init(
        id: String,
        kind: IrisStepKind,
        title: String,
        body: String,
        tool: IrisStepTool? = nil,
        command: String? = nil,
        href: String? = nil,
        actionLabel: String? = nil,
        verifierLabel: String? = nil,
        watch: IrisStepWatch? = nil,
        point: IrisStepPointTarget? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.body = body
        self.tool = tool
        self.command = command
        self.href = href
        self.actionLabel = actionLabel
        self.verifierLabel = verifierLabel
        self.watch = watch
        self.point = point
    }
}

struct IrisGuideBranch: Codable, Equatable, Sendable {
    let platform: IrisPlatform
    /// Null for desktop and local-web guides, where the computer is the target.
    let target: IrisMobileTarget?
    let label: String
    let shell: IrisGuideShell
    let setupSteps: [IrisGuideStep]
    let steps: [IrisGuideStep]
    /// When set, this pair cannot work and the branch carries no runnable steps.
    let unsupported: IrisUnsupportedPair?

    /// Same fallback reasoning as `IrisGuideStep`: an unknown shell renders as
    /// a terminal instead of taking the guide down with it.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        platform = try container.decode(IrisPlatform.self, forKey: .platform)
        target = try? container.decodeIfPresent(IrisMobileTarget.self, forKey: .target)
        label = (try? container.decode(String.self, forKey: .label))
            ?? platform.displayLabel
        shell = (try? container.decode(IrisGuideShell.self, forKey: .shell)) ?? .terminal
        setupSteps = (try? container.decodeIfPresent([IrisGuideStep].self, forKey: .setupSteps)) ?? []
        steps = try container.decode([IrisGuideStep].self, forKey: .steps)
        unsupported = try? container.decodeIfPresent(IrisUnsupportedPair.self, forKey: .unsupported)
    }

    init(
        platform: IrisPlatform,
        target: IrisMobileTarget?,
        label: String,
        shell: IrisGuideShell,
        setupSteps: [IrisGuideStep],
        steps: [IrisGuideStep],
        unsupported: IrisUnsupportedPair?
    ) {
        self.platform = platform
        self.target = target
        self.label = label
        self.shell = shell
        self.setupSteps = setupSteps
        self.steps = steps
        self.unsupported = unsupported
    }
}

struct IrisGuide: Codable, Equatable, Sendable {
    let appSlug: String
    let appName: String
    let version: Int
    let status: IrisGuideStatus
    let sourceOwner: String
    let sourceRepo: String
    let sourceCommit: String?
    let outputType: IrisGuideOutputType
    let estimatedMinutes: Int?
    let readmeSectionIds: [String]
    let reviewNote: String?
    let branches: [IrisGuideBranch]
}

extension IrisGuide {
    /// The branch identity used for progress storage on both surfaces and as
    /// the `branch` parameter of an `iris://` handoff. Equivalent to
    /// `branchKey()` in `lib/iris-guides.ts` (~line 1737). The computer alone is
    /// not enough: a Mac builds a completely different way for an iPhone than
    /// for an Android, and resuming on the wrong one drops the reader into the
    /// wrong IDE.
    static func branchKey(for branch: IrisGuideBranch) -> String {
        "\(branch.platform.rawValue):\(branch.target?.rawValue ?? "desktop")"
    }

    /// The branch a handoff's `branch` parameter names, or nil when this guide
    /// has no such branch — which is what makes a stale link land somewhere real
    /// instead of somewhere wrong.
    func branch(matchingBranchKey branchKey: String) -> IrisGuideBranch? {
        branches.first { candidateBranch in
            Self.branchKey(for: candidateBranch) == branchKey
        }
    }
}

extension IrisGuideBranch {
    var branchKey: String {
        IrisGuide.branchKey(for: self)
    }
}
