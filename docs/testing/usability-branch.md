# Usability test branch

Branch: `codex/iris-usability-reliability`, based on Iris 0.9.9 (`84dd908`).
This is a local test candidate. No PR or push is authorized yet.

## Scope

1. The project-edit Codex model picker reads visible entries from the CLI's local model cache, offers a custom identifier, remembers the choice and passes it to `codex exec --model`. The provider captures the choice for the run. The UI and run log say **Requested**, not runtime-confirmed. A missing cache still permits the CLI default or a custom identifier. Invalid identifiers are refused before the model process starts.
2. General help remains separate. Funded help says its model is managed by publik; a Sonnet/Opus toggle is only shown when it actually controls the user's own help connection. The native UI uses stronger secondary text, 12-point supporting controls, larger headings and more spacing. The result card collapses the original request and separates delivery facts.
3. Verification receipts distinguish checks that passed, failed or did not run. Commit trailers use the actual stage results. Saving code, packaging, replacing an installed copy, relaunching and confirming behavior are separate facts. The same run log remains available through delivery and the symptom verdict and includes the Iris version, build and run identifier.

## Project-edit approval behavior is unchanged

No additional confirmation is introduced for skipped checks or normal progress. `earnsCleanApply`, the existing automatic-delivery flow, clone lock, dirty-tree refusal, build-script guard, read-only Codex invocation and destructive/public-write consent policies are unchanged. The stronger verification-rung policy is deferred to the separate research branch.

This does not certify generated changes as correct. A model review, a successful build and the user's interaction passing remain different evidence.

## Keychain prompt fix

Routine reads, provider availability checks, saves and deletes are non-interactive. If access is unavailable, Iris reports its existing disconnected/failure state instead of opening a password dialog. An explicit **Reconnect saved access** menu in the eye gear's account panel can request access to one saved item. Importing an existing Claude login remains an explicit interactive action. No item ACL is broadened, no Mac password is retained, and no credential is migrated or deleted by this fix. Saves now update in place and only add when missing, preserving an existing credential after a denied update.

The first candidate, build 25.1, used only `LAContext.interactionNotAllowed`. A live user screenshot disproved that fix for the legacy login Keychain. Build 25.2 also uses a scoped, serialized `SecKeychainSetUserInteractionAllowed` guard, restoring the prior process-local state after each synchronous operation. This is a compatibility use of a deprecated API, not a system-wide setting. Chromium documents the same [legacy-backend limitation](https://chromium.googlesource.com/chromium/src/crypto/+/refs/heads/main/apple/scoped_keychain_user_interaction_allowed.cc); the modern query retains Apple's [authentication context](https://developer.apple.com/documentation/security/ksecuseauthenticationcontext).

The local app keeps one stable signing identity across rebuilds. Signing-key approval and macOS Screen Recording/Accessibility consent are separate from credential reads and are not bypassed by this change.

## Verification so far

- `swift test --package-path iris-macos/tools/usability-tests`: 24 tests passed, including parameterized identifier/cache cases, legacy interaction-state restoration, no re-add after denied credential updates, an accessible fake item, and a locked disposable legacy Keychain returning immediately without a password request. Fixtures contain no real credentials and are removed after the tests. This compiles actual isolated production files via relative symlinks. It does not build or launch Iris.
- All native app Swift sources passed a direct compiler type check against the pinned Sparkle 2.9.0 dependency. Existing concurrency and deprecation warnings remain; this is not an Xcode packaging or runtime test.
- Additional native-target tests cover model argument isolation, the skipped-check receipt and unchanged acceptance policy, and run-log version attribution. Their full Xcode test run is pending.
- Xcode GUI build succeeded for build 25.2 on September 4, 2026 at 7:19 PM Pacific. The installed local test app is Iris 0.9.9 build 25.2. Deep strict signature verification passed. Its temporary local signing overrides and local-only library-validation exception are not in the public project configuration.
- Live launch, eye-button interaction, opening the model picker, catalog choices, Escape dismissal and the standard app Settings menu were observed without credential prompts. The standard Settings menu opens an existing empty placeholder, not the real account panel; use the eye gear. No model selection was changed and no model call or edit was submitted during these checks.
- After unlocking the Mac, the real eye-gear account panel was opened repeatedly, including its six-item reconnect menu, without a password prompt. No reconnect item was selected and no access grant or sign-in was performed. Codex remained visibly connected; Keychain-backed chat credentials appeared disconnected and may require an intentional reconnect. The account layout and reconnect copy were visually inspected.
- A graceful quit was verified by the absence of an Iris process, followed by a fresh launch of the installed 25.2 bundle and another account-panel check. The new process loaded the verified installed executable. No Keychain prompt appeared during these checks. The 24-test isolated regression suite passed again after unlock.
- Interactive reconnect acceptance, light/dark background visual QA, custom-model entry, live CLI routing and end-to-end edit/delivery acceptance remain pending. This is an installed test candidate, not a fully accepted release. Quiet credential checks do not bypass signing-key, Screen Recording or Accessibility consent.

## Manual acceptance checklist

- General help clearly names its route. The project model setting does not change funded help or guide repair.
- Changing the Codex selection changes the next run's requested model in the command and log. It does not change an in-flight run.
- Missing cache, rejected model and unavailable provider produce clear states. No silent switch of account or paid provider is added.
- Text and buttons remain legible over a light browser and a dark app. Menus, custom model entry, long identifiers, keyboard focus and expanded request details fit the panel.
- Missing build/test recipes show `Not run`, with no extra prompt. Build-only and suite-only checks do not imply behavior passed.
- Packaging failure leaves code saved but not installed. Build-directory fallback does not say the installed copy was replaced.
- A successful launch still says behavior is unconfirmed until the user or a separately labeled machine check supplies a verdict.
- A second edit has fresh receipts, no stale success, and a distinct run identifier. Minimize, reopen, Stop and Undo still work.
- After a signing-identity transition, repeatedly opening help, the model menu and settings must not request Keychain passwords. Denied/locked credentials stay disconnected until an explicit reconnect. Check account-panel reconnect and a second launch without automatically granting access to any item.

## Branch boundaries

`main` and `codex/baseline-0.9.9` retain the pristine starting point. `codex/iris-harness-research` is a separate worktree containing only an audit, an additive plan and a synthetic policy simulation. It does not change the shipping harness or call models.
