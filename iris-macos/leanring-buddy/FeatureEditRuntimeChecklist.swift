//
//  FeatureEditRuntimeChecklist.swift
//  leanring-buddy
//
//  The runtime-shape checklist for the Feature Engine (plan §8) — the concrete
//  meaning of the user's ask for "software-engineering best practices
//  considering how this app would run, locally or at scale."
//
//  The plan's 8-dimension table is encoded here as data: one row per dimension,
//  each carrying a pure-local check and a scaled-service check. The classified
//  RecipeRuntimeShape (§8) selects which COLUMN applies, and the same column is
//  used twice, deliberately:
//
//    1. As a PRE-FLIGHT prompt addendum (`preflightPromptAddendum`) — told to
//       the codegen model up front so it writes idempotent / crash-safe /
//       tenant-scoped / flag-gated code the FIRST time, not as a later fix.
//    2. As a POST-EDIT review checklist (`reviewChecklist`) — the specific
//       dimensions the §9 adversarial pass probes, so "did nothing regress"
//       is checked against these named concerns rather than a vague eyeball.
//
//  Single-sourcing the check strings (one per dimension per column, used by
//  both functions) is what keeps the two passes in lockstep: the reviewer can
//  never probe a concern the author was never told about.
//
//  Pure Foundation value logic — no network, no UI, no process spawning. The
//  strings ARE the policy; changing what the engine cares about is editing a
//  row here, not rewriting a prompt in a coordinator.
//

import Foundation

// MARK: - Which column applies

/// The two columns of the plan §8 table. Only two exist because the table
/// condenses to "the cheap local lane" vs "the careful server lane"; the
/// mapping from the four `RecipeRuntimeShape` cases onto these two columns
/// (below) is where the three service-ish shapes collapse together.
nonisolated enum RuntimeChecklistColumn: String, Sendable, CaseIterable {
    /// Native app / CLI / a `bin` — nothing persists beyond this one machine
    /// and one user, so a bad change is one `git revert` away.
    case pureLocal

    /// Anything with a server component and/or shared persistence — a
    /// single-instance self-hosted service, a scaled multi-instance service,
    /// or (fail-conservative) a shape we could not classify.
    case scaledService
}

// MARK: - One dimension of the checklist

/// One row of the plan §8 table: a named engineering concern and the specific
/// check that satisfies it in each column. The check string is written to read
/// as BOTH a pre-flight directive ("make sure X") and a post-edit review item
/// ("is X true?"), so it can be single-sourced across the two passes.
nonisolated struct RuntimeChecklistDimension: Sendable, Equatable {
    /// The concern's short title, e.g. "Concurrency & idempotency". Shown as
    /// the leading label of each review item and grouped under the same word
    /// in the pre-flight addendum.
    let name: String

    /// What "done right" means for a purely local app on one machine.
    let pureLocalCheck: String

    /// What "done right" means once a server component or shared persistence
    /// is involved.
    let scaledServiceCheck: String

    /// The check that applies to the given column — the one place the column
    /// selects a string, so neither consumer duplicates the switch.
    func check(forColumn column: RuntimeChecklistColumn) -> String {
        switch column {
        case .pureLocal:
            return pureLocalCheck
        case .scaledService:
            return scaledServiceCheck
        }
    }
}

// MARK: - The checklist

/// The plan §8 runtime-shape checklist, as data plus the two pure functions
/// that surface it. No model calls, no I/O — the coordinator classifies the
/// shape (via `RuntimeShapeClassifier`) and hands it here; this layer turns
/// that shape into the exact words the codegen model and the adversarial
/// reviewer see.
nonisolated enum FeatureEditRuntimeChecklist {

    /// The 8 dimensions, in the plan §8 table's own order. This array IS the
    /// policy — adding a concern the engine should enforce is one appended row
    /// here, and both the pre-flight addendum and the review checklist pick it
    /// up automatically.
    static let dimensions: [RuntimeChecklistDimension] = [
        RuntimeChecklistDimension(
            name: "Concurrency & idempotency",
            pureLocalCheck: "Running this twice must not duplicate its side effects — "
                + "use an atomic write and a single-instance lock so a re-run is safe.",
            scaledServiceCheck: "A mutating endpoint must be safe to call twice — "
                + "protect it with an idempotency key or a unique constraint, never "
                + "assume exactly-once delivery."
        ),
        RuntimeChecklistDimension(
            name: "State",
            pureLocalCheck: "Persist state with a crash-safe disk write (a WAL or an "
                + "atomic rename), never memory-only that a crash would lose.",
            scaledServiceCheck: "Keep no per-request state in a module-level variable or "
                + "an in-process cache — that breaks the moment there is more than one "
                + "instance."
        ),
        RuntimeChecklistDimension(
            name: "Database migration",
            pureLocalCheck: "Make any migration idempotent and back up first, and handle "
                + "the \"newer schema, older binary\" case so a downgrade does not corrupt data.",
            scaledServiceCheck: "Use expand/contract: additive and nullable so the N-1 "
                + "binary still runs against the new schema, and avoid a long table lock."
        ),
        RuntimeChecklistDimension(
            name: "Performance",
            pureLocalCheck: "Do not block the main thread, do not spawn unbounded threads, "
                + "and account for the battery/CPU cost of the work.",
            scaledServiceCheck: "Avoid N+1 query patterns, prefix every cache key by tenant, "
                + "and reason about p95/p99 latency, not the average."
        ),
        RuntimeChecklistDimension(
            name: "Observability & errors",
            pureLocalCheck: "Surface errors to the user and log them without leaking secrets.",
            scaledServiceCheck: "Emit structured logs with a correlation id, retry transient "
                + "failures with bounded backoff plus jitter, and split transient from "
                + "permanent errors."
        ),
        RuntimeChecklistDimension(
            name: "Security & tenancy",
            pureLocalCheck: "Parse untrusted files safely and keep secrets in the Keychain, "
                + "never in plaintext on disk.",
            scaledServiceCheck: "Scope every query by the AUTHENTICATED tenant, use "
                + "parameterized SQL, and check authorization — not just authentication."
        ),
        RuntimeChecklistDimension(
            name: "Rollout",
            pureLocalCheck: "Put the new behavior behind an off-by-default local toggle so "
                + "it reverts cleanly with a single git revert.",
            scaledServiceCheck: "Gate the change behind a feature flag that defaults off and "
                + "has a kill-switch."
        ),
        RuntimeChecklistDimension(
            name: "API & contract",
            pureLocalCheck: "Migrate the config/save-file schema and keep a fallback that "
                + "still reads files written by the old version.",
            scaledServiceCheck: "Make the API change additive-only or introduce a new version, "
                + "with a deprecation window before anything is removed."
        ),
    ]

    /// Which column the classified runtime shape maps onto.
    ///
    /// Only `pureLocalApp` gets the cheap local lane. The two service shapes
    /// AND `unknown` all map to the careful scaled-service lane — the same
    /// grouping `FeatureEditVerificationLadder.requiredRung` uses (L2 for
    /// pure-local, L5 for everything else), and for the same reason: once a
    /// server or shared persistence is in play, a regression can corrupt state
    /// a `git revert` cannot un-corrupt, so `unknown` fails conservative into
    /// the stricter column rather than being assumed local. A single-instance
    /// self-hosted service does not need every scaled check to bite equally,
    /// but the scaled column's concerns (crash-safe state, expand/contract
    /// migrations, parameterized SQL, structured errors) are exactly the ones
    /// that DO apply the moment there is a server and a database.
    static func columnApplied(forRuntimeShape runtimeShape: RecipeRuntimeShape) -> RuntimeChecklistColumn {
        switch runtimeShape {
        case .pureLocalApp:
            return .pureLocal
        case .localSingleInstanceService, .builtForScale, .unknown:
            return .scaledService
        }
    }

    /// What to tell the codegen model UP FRONT (plan §8, pass 1). A short
    /// runtime-context header naming how the app runs, followed by the
    /// applicable-column check for every dimension as a directive the model
    /// must satisfy the first time — so idempotency / tenancy / flagging are
    /// designed in, not bolted on after a review catches their absence.
    static func preflightPromptAddendum(forRuntimeShape runtimeShape: RecipeRuntimeShape) -> String {
        let column = columnApplied(forRuntimeShape: runtimeShape)

        var addendumLines: [String] = []
        addendumLines.append("Runtime context: \(runtimeShapeDescription(forRuntimeShape: runtimeShape))")
        addendumLines.append("")
        addendumLines.append("Apply software-engineering practices appropriate to that runtime. "
            + "Before you finish, your change must satisfy each of these:")
        addendumLines.append("")
        for dimension in dimensions {
            addendumLines.append("- \(dimension.name): \(dimension.check(forColumn: column))")
        }
        return addendumLines.joined(separator: "\n")
    }

    /// The POST-EDIT review items (plan §8, pass 2) — the exact dimensions the
    /// §9 adversarial pass probes, one per dimension, phrased as the concern to
    /// audit. Same column, same strings as the pre-flight addendum, so the
    /// reviewer can never check a dimension the author was not told about (nor
    /// miss one the author was).
    static func reviewChecklist(forRuntimeShape runtimeShape: RecipeRuntimeShape) -> [String] {
        let column = columnApplied(forRuntimeShape: runtimeShape)
        return dimensions.map { dimension in
            "\(dimension.name): \(dimension.check(forColumn: column))"
        }
    }

    /// A one-line, reader-and-model-facing description of how the app runs,
    /// used as the pre-flight header. `unknown` says so plainly AND names the
    /// conservative choice, so nobody reads the stricter checklist as a claim
    /// the app is definitely scaled.
    static func runtimeShapeDescription(forRuntimeShape runtimeShape: RecipeRuntimeShape) -> String {
        switch runtimeShape {
        case .pureLocalApp:
            return "this app runs purely locally on one Mac (a native app or CLI, no server)."
        case .localSingleInstanceService:
            return "this app runs as a self-hosted single-instance service (a server plus "
                + "persistence, for one operator)."
        case .builtForScale:
            return "this app is built to run as a scaled, multi-instance service."
        case .unknown:
            return "Iris could not classify how this app runs, so it is treating it as the "
                + "riskier server-shaped case and applying the stricter checklist."
        }
    }
}
