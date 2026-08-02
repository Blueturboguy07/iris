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
}

enum IrisGuideShell: String, Codable, Equatable, Sendable {
    case terminal
    case powershell
}

enum IrisGuideOutputType: String, Codable, Equatable, Sendable {
    case desktopApp = "desktop_app"
    case localWeb = "local_web"
    case mobileApp = "mobile_app"
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
        verifierLabel: String? = nil
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
