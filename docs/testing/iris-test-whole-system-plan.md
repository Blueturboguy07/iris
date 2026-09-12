# Iris Test whole-system execution plan

This is the working plan for the separate Iris Test application. It is a
single end-to-end loop, not a promise that a passing unit test proves the
whole product. The ordinary Iris app, normal user profiles and valuable user
app copies remain outside the test target.

## Outcome

Make a small, reliable harness that can turn an everyday request into a
reviewable change without making the reader learn repository terminology. It
must:

1. understand the requested outcome and the current app context;
2. ask only for decisions the repository and screen cannot answer;
3. show a plain-language plan and explicit non-goals;
4. make the smallest confined change with a bounded model and command budget;
5. prove behavior separately from build success;
6. deliver a runnable Iris Test copy, relaunch it, and keep a recoverable
   previous version; and
7. leave an honest, inspectable record when a stage was not run or could not
   be proved.

## One continuous lifecycle

The harness owns one run record with a stable run ID and revision. Every
asynchronous callback, terminal session, guide fetch, plan, receipt and
relaunch result is accepted only when it still belongs to that run and
revision. A newer request invalidates older work; an interrupted command is
not replayed automatically.

The run proceeds through these states:

`intake -> inspect -> clarify (only if needed) -> plan -> consent -> edit ->
verify -> review -> package -> replace Test copy -> relaunch -> symptom check
-> keep or Undo`

The states are a single state machine for ownership and accounting, not a
requirement to call a model at every state. Local selections, cached catalog
facts and deterministic checks stay local and do not spend a model call.

## Nontechnical intake contract

The reader may say something like “make WhisperFlow paste into the right tab.”
The model must translate that into a compact question set in ordinary words:

- Which app or window should receive the paste?
- What should count as the correct tab: its name, site, or both?
- Should Iris choose the tab automatically, ask every time, or use the last
  selected tab?
- What should happen when that tab is missing or more than one tab matches?
- What is explicitly out of scope (for example, changing login or sending a
  message)?

The repository answers technical questions itself. The reader answers product
choices. Questions are batched, single-select where possible, and capped. A
simple bug fix with a clear target skips the interview. Unanswered or
ambiguous choices stop before editing; they never acquire invented defaults.
Answers are recorded by stable question ID, survive a refinement, and
invalidate evidence from an older revision.

## Model routing and budgets

- Planning: Astra Medium, because it must convert an informal outcome into a
  technical brief and acceptance contract.
- Implementation and review: Astra Low is the default fast path. Luna XHigh
  is an isolated comparison arm only when the same frozen brief, source
  revision, input budget and acceptance contract are used.
- Routing is decided by task shape and evidence needs, not by a blanket “use
  the biggest model” rule. The implementation arm cannot silently change the
  plan or acceptance criteria.
- Every call reserves input bytes before sending, records settled usage, and
  treats missing provider usage as unknown. Review allowance is never spent
  on a retry after a failed suite.

## Verification and delivery

Build, tests, behavior, packaging, installation, relaunch and Undo are
separate facts. A green build never becomes “feature verified.” A successful
source edit never becomes “installed.” The final record must show each stage
as passed, failed, not run or unknown.

The Test delivery path must:

- require a clean, registered disposable target;
- refuse normal apps, ambiguous identities, dirty user work and external
  recovery paths;
- snapshot the currently installed Test copy before replacement;
- replace only the registered Test copy, then launch that exact path;
- verify the new bundle identity and visible behavior after relaunch; and
- make Undo restore the snapshot, relaunch the restored copy and preserve the
  receipt when any step is uncertain.

## Real computer-use acceptance loop

For each acceptance target, operate the installed Iris Test UI rather than a
synthetic click fixture:

1. open the eye and inspect a fresh screenshot and accessibility state;
2. exercise Ask/Edit separation, project switching, unsent-draft behavior,
   history clearing and settings;
3. run a disposable app through onboarding and at least one real workflow;
4. test overlapping install and edit windows, minimized terminals and a
   stopped or failed command;
5. quit and relaunch the same disposable app, then inspect the visible result;
6. capture screenshots at each transition and attach the run ID to the log;
7. if a control or result is not observable, record it as unproven rather than
   inferring success from a build or shell log.

The first disposable target is NitroAI Iris QA. Additional registered targets
may be used only when their roots, bundle IDs and recovery locations are
explicitly isolated.

## Defensive regression lane

The security lane is defensive and confined to Iris Test and disposable
fixtures. It checks path escape, symlink and dirty-tree refusal, command and
credential boundary enforcement, secret redaction, cancellation and stale
callback ownership, receipt/backup retention, input/image limits, and
untrusted model output. It does not attempt to access other users, evade
platform safeguards, or turn an untrusted output into a permission to publish
or install.

One known follow-up remains: the optional model-derived ambiguity and
irreversibility probe currently fails open when its provider reply is missing
or malformed. Until that policy is changed and tested, the harness must not
describe the probe as a guarantee that a destructive request was clarified.
The ordinary consent, command and delivery gates still apply.

## Agent work contract

When work is delegated, each agent receives a narrow file/test ownership list,
the exact acceptance contract, the disposable fixture root, and a prohibition
on touching normal Iris or user data. Agents return changed paths, commands,
results and uncertainties. The root agent integrates overlapping changes,
builds the candidate, operates the real UI and decides whether a claim is
accepted. Parallelism reduces waiting; it does not remove the final review.

## Exit criteria for an Iris Test run

The run is useful for human testing only when all of the following are true:

- the separate Iris Test app launches with the expected identity;
- harness, guide/controller and defensive regressions pass;
- at least one real disposable app workflow was operated through computer use;
- the visible post-relaunch state is recorded;
- the version-history receipt and Undo state are inspectable; and
- every unrun or unproven stage is listed plainly.

This plan intentionally does not claim complex-feature success until a real
feature is delivered, relaunched, exercised and independently reviewed.
