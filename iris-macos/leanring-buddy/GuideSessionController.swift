//
//  GuideSessionController.swift
//  leanring-buddy
//
//  Owns one in-progress install guide: which guide is open, which branch of it
//  the reader picked, how far into that branch they are, and what the panel
//  should offer them to press next.
//
//  This is the state layer the Tauri panel keeps in its `state` object
//  (`iris-desktop/ui/app.js` — `loadGuide`, `setPlatform`, `moveStep`,
//  `updatePrimaryAction`, `verifyCurrentTools`), which remains the behavioral
//  spec. Nothing here re-implements validation: fetching, version checking,
//  handoff resolution, and progress storage all go through `GuideService`, link
//  policy goes through `ExternalLinkPolicy`, and tool checks go through
//  `ToolVersionService`.
//

import AppKit
import Combine
import Foundation

/// What the panel is showing right now. The failure case carries an already
/// human-readable sentence rather than an error value, because every failure
/// this controller can hit has exactly one thing worth telling the reader and
/// deciding that twice (once here, once in the view) is how the two drift.
enum GuideSessionLoadState: Equatable, Sendable {
    case noGuideIsOpen
    case guideIsLoading(slug: String)
    case guideIsOpen
    case guideCouldNotBeLoaded(slug: String, userFacingMessage: String)

    var isShowingSomethingAboutAGuide: Bool {
        self != .noGuideIsOpen
    }
}

/// The one thing the step card's main button does. The blocked case exists so a
/// step whose link host is not allowlisted renders as a visibly disabled button
/// with a reason attached: the Tauri app shipped a version where that same
/// situation produced a button that silently did nothing (Astro's Windows
/// "Install BrowserOS"), and `iris-desktop 0.1.4` fixed it. A no-op button is
/// worse than no button, because the reader blames themselves.
enum GuideStepPrimaryAction: Equatable, Sendable {
    case copyCommandToClipboard(command: String, buttonLabel: String)
    case openLinkInBrowser(linkURLString: String, buttonLabel: String)
    case openLinkIsUnavailable(linkURLString: String, reasonTheLinkCannotBeOpened: String)
    case runToolChecksForThisStep(buttonLabel: String)
    /// "I ran it" / "Continue" / "Finish" / "Done" — every label that simply
    /// moves the reader on. They differ only in wording, so they share a case.
    case advanceToTheNextStep(buttonLabel: String)

    var buttonLabel: String {
        switch self {
        case .copyCommandToClipboard(_, let buttonLabel): return buttonLabel
        case .openLinkInBrowser(_, let buttonLabel): return buttonLabel
        case .openLinkIsUnavailable: return "Open"
        case .runToolChecksForThisStep(let buttonLabel): return buttonLabel
        case .advanceToTheNextStep(let buttonLabel): return buttonLabel
        }
    }

    /// Whether the panel should draw this as a pressable button at all.
    var isPressable: Bool {
        if case .openLinkIsUnavailable = self {
            return false
        }
        return true
    }
}

/// Where one tool-check row is in its life. `readyToCheck` is the row's resting
/// state: the Tauri panel lists the tools a step needs but does not run anything
/// until the reader presses the button, so nothing is spawned by merely landing
/// on a step.
enum GuideToolCheckState: Equatable, Sendable {
    case readyToCheck
    case checking
    case installedWithVersion(version: String)
    case notInstalled
    case couldNotBeChecked(reason: String)
}

struct GuideToolCheckRow: Identifiable, Equatable, Sendable {
    let toolName: String
    let state: GuideToolCheckState

    var id: String { toolName }

    /// The trailing half of the row, matching the Tauri panel's
    /// `"${tool} · ${detail}"` line.
    var detailText: String {
        switch state {
        case .readyToCheck: return "ready to check"
        case .checking: return "checking…"
        case .installedWithVersion(let version): return version
        case .notInstalled: return "Not installed"
        case .couldNotBeChecked(let reason): return reason
        }
    }
}

@MainActor
final class GuideSessionController: ObservableObject {
    // MARK: - Published state

    @Published private(set) var loadState: GuideSessionLoadState = .noGuideIsOpen
    @Published private(set) var guideBeingFollowed: IrisGuide?
    @Published private(set) var selectedBranch: IrisGuideBranch?
    @Published private(set) var currentStepIndex: Int = 0
    @Published private(set) var readerHasFinishedTheGuide: Bool = false
    @Published private(set) var toolCheckRows: [GuideToolCheckRow] = []

    /// Set the moment the reader copies the step's command, which is what turns
    /// the button from "Copy" into "I ran it" — the same `actionReady` latch the
    /// Tauri panel keeps.
    @Published private(set) var readerHasTakenThisStepsAction: Bool = false

    /// The short-lived "Copied — paste in Terminal." line under the command
    /// block. Nil when nothing was copied recently.
    @Published private(set) var transientCopyConfirmationText: String?

    /// True once the reader has pressed "Check tools" at least once on this
    /// step, which is what relabels the button to "Check again".
    @Published private(set) var toolChecksHaveBeenRunForThisStep: Bool = false

    // MARK: - Collaborators

    private let guideService: GuideService

    /// The computer this app is running on. It only ever has one value in a
    /// shipped build — this is a Mac-only app — but it is injectable so the
    /// branch-preference behavior can be tested from the Windows side too.
    private let platformThisAppRunsOn: IrisPlatform

    private var copyConfirmationDismissalTask: Task<Void, Never>?
    private var toolCheckTask: Task<Void, Never>?

    /// The most recent progress write. Pressing Next must not wait on storage,
    /// so the write is started and left to finish on its own; anything that
    /// needs it to have landed before reading progress back waits here.
    private var progressPersistenceTask: Task<Void, Never>?

    /// How long the copy confirmation stays up, matching the Tauri panel's
    /// 2200ms toast so both surfaces feel the same.
    private static let copyConfirmationVisibleDuration: Duration = .milliseconds(2200)

    init(
        guideService: GuideService = GuideService(
            apiBase: AssistantTransport.configuredPublikBaseURL().absoluteString
        ),
        platformThisAppRunsOn: IrisPlatform = .macos
    ) {
        self.guideService = guideService
        self.platformThisAppRunsOn = platformThisAppRunsOn
    }

    // MARK: - Opening a guide

    /// The deep-link route: `iris://guide/<slug>?version=&branch=&step=`. The
    /// link is already shape-validated by `IrisDeepLinkParser` before it gets
    /// here; the branch and step are checked against the guide that actually
    /// comes back, by `GuideService.resolveHandoff`.
    func openGuide(fromDeepLink guideDeepLink: GuideDeepLink) async {
        await openGuide(
            slug: guideDeepLink.slug,
            requestedVersion: Int(guideDeepLink.version),
            branchKeyFromDeepLink: guideDeepLink.branchKey,
            stepIndexFromDeepLink: guideDeepLink.stepIndex.map(Int.init)
        )
    }

    /// The no-deep-link route: the reader typed a slug into the panel. No
    /// version is pinned, so publik serves whatever is current, which is what
    /// somebody starting fresh wants.
    func openLatestVersionOfGuide(slug: String) async {
        await openGuide(
            slug: slug,
            requestedVersion: nil,
            branchKeyFromDeepLink: nil,
            stepIndexFromDeepLink: nil
        )
    }

    /// Fetches a guide and lands the reader somewhere real inside it.
    func openGuide(
        slug: String,
        requestedVersion: Int?,
        branchKeyFromDeepLink: String?,
        stepIndexFromDeepLink: Int?
    ) async {
        cancelAnyWorkFromThePreviousStep()
        loadState = .guideIsLoading(slug: slug)
        guideBeingFollowed = nil
        selectedBranch = nil
        currentStepIndex = 0
        readerHasFinishedTheGuide = false
        toolCheckRows = []

        let fetchedGuide: IrisGuide
        do {
            fetchedGuide = try await guideService.fetchGuide(slug: slug, version: requestedVersion)
        } catch let guideServiceError as GuideServiceError {
            // Every status the route can answer with is already a distinct case
            // carrying its own sentence, so "this version is gone" never reads
            // as "you have no internet".
            loadState = .guideCouldNotBeLoaded(
                slug: slug,
                userFacingMessage: guideServiceError.userFacingMessage
            )
            return
        } catch {
            loadState = .guideCouldNotBeLoaded(
                slug: slug,
                userFacingMessage: GuideServiceError
                    .transportFailure(reason: error.localizedDescription)
                    .userFacingMessage
            )
            return
        }

        // The version here is the guide's own, not the link's: they are equal by
        // the time `fetchGuide` returns (it 409s otherwise), and using the real
        // one keeps the progress key honest when no version was pinned at all.
        let guideDeepLinkToResolve = GuideDeepLink(
            slug: fetchedGuide.appSlug,
            version: UInt32(max(1, fetchedGuide.version)),
            branchKey: branchKeyFromDeepLink,
            stepIndex: stepIndexFromDeepLink.map { stepIndex in UInt32(max(0, stepIndex)) }
        )
        guard let resolvedHandoff = GuideService.resolveHandoff(
            guideDeepLinkToResolve,
            against: fetchedGuide,
            preferredPlatform: platformThisAppRunsOn
        ) else {
            loadState = .guideCouldNotBeLoaded(
                slug: slug,
                userFacingMessage: GuideServiceError.guideHasNoBranches.userFacingMessage
            )
            return
        }

        guideBeingFollowed = fetchedGuide
        selectedBranch = resolvedHandoff.branch

        // A link that names both a branch and a step is carrying the reader's
        // own place across from the website, so it wins over whatever this
        // machine last wrote down. Without one, saved progress is the only thing
        // that knows where they got to.
        let theLinkNamedThisExactBranchAndStep =
            branchKeyFromDeepLink == resolvedHandoff.branch.branchKey
            && stepIndexFromDeepLink != nil
        if theLinkNamedThisExactBranchAndStep {
            currentStepIndex = resolvedHandoff.stepIndex
            readerHasFinishedTheGuide = false
            await persistProgressForTheCurrentPosition()
        } else {
            await restoreSavedProgress(forBranch: resolvedHandoff.branch)
        }

        prepareToolCheckRowsForTheCurrentStep()
        loadState = .guideIsOpen
    }

    func closeTheGuide() {
        cancelAnyWorkFromThePreviousStep()
        loadState = .noGuideIsOpen
        guideBeingFollowed = nil
        selectedBranch = nil
        currentStepIndex = 0
        readerHasFinishedTheGuide = false
        toolCheckRows = []
    }

    // MARK: - Branch selection

    /// Every branch the guide ships, which is what the device-pair picker draws.
    /// Unsupported pairs are included on purpose: a reader on a Mac who picks
    /// "Windows + iPhone" deserves to be told why it cannot work rather than to
    /// find that pair missing and assume Iris is broken.
    var branchesTheReaderCanChooseBetween: [IrisGuideBranch] {
        guideBeingFollowed?.branches ?? []
    }

    /// The Tauri panel hides the picker entirely for a single-branch guide,
    /// because a choice of one is not a choice.
    var guideOffersAChoiceOfBranches: Bool {
        branchesTheReaderCanChooseBetween.count > 1
    }

    func selectBranch(withBranchKey branchKey: String) async {
        guard let guide = guideBeingFollowed,
              let branchTheReaderPicked = guide.branch(matchingBranchKey: branchKey) else {
            return
        }
        cancelAnyWorkFromThePreviousStep()
        selectedBranch = branchTheReaderPicked
        // Each branch remembers its own place: the same reader can be nine steps
        // into the Android build and not have started the iPhone one.
        await restoreSavedProgress(forBranch: branchTheReaderPicked)
        prepareToolCheckRowsForTheCurrentStep()
    }

    // MARK: - What the step card renders

    /// The pair explanation shown instead of steps. Non-nil means this branch
    /// has no install route at all.
    var unsupportedPairForTheSelectedBranch: IrisUnsupportedPair? {
        selectedBranch?.unsupported
    }

    /// The step the reader is on, or nil when there is nothing to show — no
    /// guide, an unsupported pair, an empty branch, or the completion card.
    var currentStep: IrisGuideStep? {
        guard let branch = selectedBranch, branch.unsupported == nil else {
            return nil
        }
        guard currentStepIndex >= 0, currentStepIndex < branch.steps.count else {
            return nil
        }
        return branch.steps[currentStepIndex]
    }

    var numberOfStepsInTheSelectedBranch: Int {
        // Setup steps are deliberately excluded, matching the Tauri panel: they
        // are a side quest for a missing tool, so counting them would make the
        // total jump around depending on what the reader already has installed.
        selectedBranch?.steps.count ?? 0
    }

    /// "3 / 12", or "Done" on the completion card.
    var stepCounterText: String {
        if readerHasFinishedTheGuide {
            return "Done"
        }
        guard numberOfStepsInTheSelectedBranch > 0 else {
            return ""
        }
        return "\(currentStepIndex + 1) / \(numberOfStepsInTheSelectedBranch)"
    }

    /// How full the progress bar is, from 0 to 1.
    var fractionOfTheGuideCompleted: Double {
        guard numberOfStepsInTheSelectedBranch > 0 else {
            return 0
        }
        if readerHasFinishedTheGuide {
            return 1
        }
        return Double(currentStepIndex) / Double(numberOfStepsInTheSelectedBranch)
    }

    /// The command block's contents, or nil when there is no block to draw.
    /// A `check` step's command is the list of version probes behind the tool
    /// rows rather than something for the reader to paste, so it is not shown
    /// as a block — the same call the Tauri panel makes.
    var commandBlockTextForTheCurrentStep: String? {
        guard let step = currentStep, step.kind != .check else {
            return nil
        }
        guard let command = step.command, !command.isEmpty else {
            return nil
        }
        return command
    }

    /// The body copy under the step title. A step with a command says where to
    /// paste it, which is more useful than the authored body at that moment —
    /// the Tauri panel makes the same substitution.
    var bodyTextForTheCurrentStep: String {
        guard let step = currentStep else {
            return ""
        }
        if commandBlockTextForTheCurrentStep != nil {
            return "Paste in \(nameOfTheShellForTheSelectedBranch)."
        }
        return step.body
    }

    var nameOfTheShellForTheSelectedBranch: String {
        switch selectedBranch?.shell ?? .terminal {
        case .terminal: return "Terminal"
        case .powershell: return "PowerShell"
        }
    }

    /// "cue is ready." — the completion card's headline.
    var completionHeadline: String {
        guard let guide = guideBeingFollowed else {
            return "Guide complete."
        }
        return "\(guide.appName) is ready."
    }

    var canReturnToThePreviousStep: Bool {
        guard selectedBranch?.unsupported == nil, numberOfStepsInTheSelectedBranch > 0 else {
            return false
        }
        return readerHasFinishedTheGuide || currentStepIndex > 0
    }

    // MARK: - The primary action

    /// The single button at the bottom of the step card, resolved exactly once
    /// so the view never has to work out what pressing it should do.
    var primaryActionForTheCurrentStep: GuideStepPrimaryAction? {
        guard loadState == .guideIsOpen,
              !readerHasFinishedTheGuide,
              let branch = selectedBranch,
              branch.unsupported == nil,
              let step = currentStep else {
            return nil
        }

        let thisIsTheLastStep = currentStepIndex >= branch.steps.count - 1
        let labelForMovingOn = thisIsTheLastStep ? "Finish" : "Continue"

        // A check step's whole job is the tool rows, so its button drives them
        // until every tool it needs has been found.
        let toolNamesThisStepNeeds = toolNamesRequiredByTheCurrentStep
        if step.kind == .check, !toolNamesThisStepNeeds.isEmpty {
            if everyRequiredToolWasFound {
                return .advanceToTheNextStep(buttonLabel: labelForMovingOn)
            }
            return .runToolChecksForThisStep(
                buttonLabel: toolChecksHaveBeenRunForThisStep ? "Check again" : "Check tools"
            )
        }

        if let command = commandBlockTextForTheCurrentStep {
            if readerHasTakenThisStepsAction {
                return .advanceToTheNextStep(buttonLabel: "I ran it")
            }
            return .copyCommandToClipboard(command: command, buttonLabel: "Copy")
        }

        if let linkURLString = step.href, !linkURLString.isEmpty {
            guard ExternalLinkPolicy.isAllowedExternalURL(linkURLString) else {
                return .openLinkIsUnavailable(
                    linkURLString: linkURLString,
                    reasonTheLinkCannotBeOpened: Self.reasonALinkCannotBeOpened(
                        linkURLString: linkURLString
                    )
                )
            }
            if readerHasTakenThisStepsAction {
                return .advanceToTheNextStep(buttonLabel: labelForMovingOn)
            }
            return .openLinkInBrowser(
                linkURLString: linkURLString,
                buttonLabel: step.actionLabel ?? "Open"
            )
        }

        return .advanceToTheNextStep(buttonLabel: thisIsTheLastStep ? "Finish" : "Done")
    }

    /// Says which host was refused rather than just "blocked", because the
    /// reader can still visit it themselves and the host name is the only part
    /// of the answer they can act on.
    static func reasonALinkCannotBeOpened(linkURLString: String) -> String {
        let hostThatWasRefused = URLComponents(string: linkURLString)?.host
        guard let hostThatWasRefused, !hostThatWasRefused.isEmpty else {
            return "Iris cannot open this link — it is not a web address Iris understands."
        }
        return "Iris will not open \(hostThatWasRefused) — it is not on publik's reviewed link list."
    }

    /// Runs whatever the primary button is currently offering.
    func performPrimaryAction() {
        guard let primaryAction = primaryActionForTheCurrentStep else {
            return
        }
        switch primaryAction {
        case .copyCommandToClipboard(let command, _):
            copyCommandToClipboard(command)
        case .openLinkInBrowser(let linkURLString, _):
            openLinkInBrowser(linkURLString)
        case .openLinkIsUnavailable:
            // Deliberately nothing: this action is drawn as a disabled control
            // with its reason showing, and is never wired to a press.
            break
        case .runToolChecksForThisStep:
            runToolChecksForTheCurrentStep()
        case .advanceToTheNextStep:
            advanceToTheNextStep()
        }
    }

    // MARK: - Copying and opening

    func copyCommandToClipboard(_ command: String) {
        let generalPasteboard = NSPasteboard.general
        generalPasteboard.clearContents()
        generalPasteboard.setString(command, forType: .string)
        readerHasTakenThisStepsAction = true
        showTransientCopyConfirmation()
    }

    /// Hands the link to `ExternalLinkPolicy`, which is the only thing in this
    /// app that decides whether a guide's host may be opened. Returns false when
    /// the policy refused, so a caller never has to guess.
    @discardableResult
    func openLinkInBrowser(_ linkURLString: String) -> Bool {
        let theLinkWasOpened = ExternalLinkPolicy.openExternalURLIfAllowed(linkURLString)
        if theLinkWasOpened {
            readerHasTakenThisStepsAction = true
        }
        return theLinkWasOpened
    }

    private func showTransientCopyConfirmation() {
        copyConfirmationDismissalTask?.cancel()
        transientCopyConfirmationText = "Copied — paste in \(nameOfTheShellForTheSelectedBranch)."
        copyConfirmationDismissalTask = Task { [weak self] in
            try? await Task.sleep(for: Self.copyConfirmationVisibleDuration)
            guard !Task.isCancelled else { return }
            self?.transientCopyConfirmationText = nil
        }
    }

    // MARK: - Tool checks

    /// The tools this step wants verified. A setup step names one outright in
    /// `tool`; a `check` step lists them as version probes in its command, which
    /// is what `extractSafeTools` reads in the Tauri panel.
    var toolNamesRequiredByTheCurrentStep: [String] {
        guard let step = currentStep else {
            return []
        }
        if let declaredTool = step.tool {
            return [declaredTool.rawValue]
        }
        guard step.kind == .check, let command = step.command else {
            return []
        }
        return Self.allowlistedToolNames(inVersionProbeCommand: command)
    }

    /// Reads `git --version\nnode --version` as ["git", "node"].
    ///
    /// The set of names this accepts is `ToolVersionService`'s table and nothing
    /// else. The Tauri app kept a second copy of that allowlist in JavaScript
    /// and the two drifted; there is exactly one here on purpose.
    static func allowlistedToolNames(inVersionProbeCommand command: String) -> [String] {
        var toolNamesFound: [String] = []
        for commandLine in command.split(separator: "\n") {
            let tokensOnThisLine = commandLine
                .split(whereSeparator: { character in character == " " || character == "\t" })
                .map(String.init)
            guard let executableName = tokensOnThisLine.first,
                  let toolSpecification = ToolVersionService.toolSpecification(for: executableName),
                  Array(tokensOnThisLine.dropFirst()) == toolSpecification.arguments,
                  !toolNamesFound.contains(executableName) else {
                continue
            }
            toolNamesFound.append(executableName)
        }
        return toolNamesFound
    }

    var everyRequiredToolWasFound: Bool {
        let toolNamesThisStepNeeds = toolNamesRequiredByTheCurrentStep
        guard !toolNamesThisStepNeeds.isEmpty else {
            return false
        }
        return toolNamesThisStepNeeds.allSatisfy { toolName in
            guard let row = toolCheckRows.first(where: { $0.toolName == toolName }) else {
                return false
            }
            if case .installedWithVersion = row.state {
                return true
            }
            return false
        }
    }

    /// Lists the step's tools without running anything. Landing on a step must
    /// not spawn processes — the reader presses the button when they are ready.
    private func prepareToolCheckRowsForTheCurrentStep() {
        toolChecksHaveBeenRunForThisStep = false
        toolCheckRows = toolNamesRequiredByTheCurrentStep.map { toolName in
            GuideToolCheckRow(toolName: toolName, state: .readyToCheck)
        }
    }

    func runToolChecksForTheCurrentStep() {
        let toolNamesToCheck = toolNamesRequiredByTheCurrentStep
        guard !toolNamesToCheck.isEmpty else {
            return
        }
        toolCheckTask?.cancel()
        toolChecksHaveBeenRunForThisStep = true
        toolCheckRows = toolNamesToCheck.map { toolName in
            GuideToolCheckRow(toolName: toolName, state: .checking)
        }
        toolCheckTask = Task { [weak self] in
            var rowsAfterChecking: [GuideToolCheckRow] = []
            for toolName in toolNamesToCheck {
                rowsAfterChecking.append(await Self.checkOneTool(named: toolName))
            }
            guard !Task.isCancelled else { return }
            self?.toolCheckRows = rowsAfterChecking
        }
    }

    /// A tool that is simply absent is data — the guide exists to install it —
    /// while a lookup that broke is an error worth naming. `ToolVersionService`
    /// already draws that line; this only translates it into a row.
    private static func checkOneTool(named toolName: String) async -> GuideToolCheckRow {
        do {
            let toolVersion = try await ToolVersionService.checkToolVersion(tool: toolName)
            guard toolVersion.available else {
                return GuideToolCheckRow(toolName: toolName, state: .notInstalled)
            }
            return GuideToolCheckRow(
                toolName: toolName,
                state: .installedWithVersion(version: toolVersion.version)
            )
        } catch let toolVersionError as ToolVersionError {
            return GuideToolCheckRow(
                toolName: toolName,
                state: .couldNotBeChecked(reason: toolVersionError.userFacingMessage)
            )
        } catch {
            return GuideToolCheckRow(
                toolName: toolName,
                state: .couldNotBeChecked(reason: error.localizedDescription)
            )
        }
    }

    // MARK: - Navigation

    func advanceToTheNextStep() {
        guard let branch = selectedBranch, branch.unsupported == nil, !branch.steps.isEmpty else {
            return
        }
        let lastStepIndex = branch.steps.count - 1
        if currentStepIndex >= lastStepIndex {
            // Past the last step is the completion card, never a step index the
            // branch does not have.
            currentStepIndex = lastStepIndex
            readerHasFinishedTheGuide = true
        } else {
            currentStepIndex += 1
        }
        cancelAnyWorkFromThePreviousStep()
        prepareToolCheckRowsForTheCurrentStep()
        startPersistingProgressForTheCurrentPosition()
    }

    func returnToThePreviousStep() {
        guard let branch = selectedBranch, branch.unsupported == nil, !branch.steps.isEmpty else {
            return
        }
        if readerHasFinishedTheGuide {
            // Backing out of the completion card puts the reader on the last
            // step rather than one before it, which is where they just were.
            readerHasFinishedTheGuide = false
        } else if currentStepIndex > 0 {
            currentStepIndex -= 1
        } else {
            // Already on the first step. There is nowhere further back, and a
            // negative index would be a crash rather than a wrap-around.
            return
        }
        cancelAnyWorkFromThePreviousStep()
        prepareToolCheckRowsForTheCurrentStep()
        startPersistingProgressForTheCurrentPosition()
    }

    func restartTheGuide() {
        guard selectedBranch != nil else { return }
        currentStepIndex = 0
        readerHasFinishedTheGuide = false
        cancelAnyWorkFromThePreviousStep()
        prepareToolCheckRowsForTheCurrentStep()
        startPersistingProgressForTheCurrentPosition()
    }

    /// Clears the copy confirmation and the "I ran it" latch, and stops any
    /// tool check still running for the step being left behind — otherwise its
    /// result would land in the next step's rows.
    private func cancelAnyWorkFromThePreviousStep() {
        copyConfirmationDismissalTask?.cancel()
        copyConfirmationDismissalTask = nil
        toolCheckTask?.cancel()
        toolCheckTask = nil
        transientCopyConfirmationText = nil
        readerHasTakenThisStepsAction = false
    }

    // MARK: - Progress

    private func restoreSavedProgress(forBranch branch: IrisGuideBranch) async {
        guard let guide = guideBeingFollowed else { return }
        // The version is baked into the storage key, so a guide that has moved
        // to a new version simply finds nothing saved and starts at step one.
        // That is the point: step nine of version two may not exist in version
        // three, and resuming into it would drop the reader somewhere wrong.
        let savedProgress = await guideService.loadProgress(
            slug: guide.appSlug,
            version: guide.version,
            branchKey: branch.branchKey
        )
        let lastStepIndex = max(0, branch.steps.count - 1)
        currentStepIndex = min(max(0, savedProgress.stepIndex), lastStepIndex)
        readerHasFinishedTheGuide = savedProgress.isCompleted
    }

    /// Starts a progress write without blocking whoever asked for it. Pressing
    /// Next has to feel instant, and storage is the one thing in that path that
    /// can be slow.
    private func startPersistingProgressForTheCurrentPosition() {
        progressPersistenceTask = Task { [weak self] in
            await self?.persistProgressForTheCurrentPosition()
        }
    }

    /// Waits for the most recent progress write to reach storage, for anything
    /// that is about to read progress back and would otherwise race it.
    func waitUntilProgressHasBeenPersisted() async {
        await progressPersistenceTask?.value
    }

    private func persistProgressForTheCurrentPosition() async {
        guard let guide = guideBeingFollowed, let branch = selectedBranch else { return }
        await guideService.saveProgress(
            slug: guide.appSlug,
            version: guide.version,
            branch: branch,
            progress: GuideProgress(
                stepIndex: currentStepIndex,
                isCompleted: readerHasFinishedTheGuide
            )
        )
    }

    /// Forgets every guide's saved place, the same reset the Tauri panel offers.
    func clearAllStoredGuideProgress() async {
        await guideService.clearAllStoredProgress()
        if selectedBranch != nil {
            currentStepIndex = 0
            readerHasFinishedTheGuide = false
            cancelAnyWorkFromThePreviousStep()
            prepareToolCheckRowsForTheCurrentStep()
        }
    }
}
