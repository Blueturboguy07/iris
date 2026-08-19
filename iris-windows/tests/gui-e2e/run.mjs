// run.mjs
//
// The headed GUI end-to-end suite for Iris on Windows. It launches the REAL
// packaged app on the windows-latest CI runner (a genuine Windows machine with
// a desktop session), drives it "like a human" through the Chrome DevTools
// Protocol against the real preload bridge, exercises the genuinely
// Windows-only code paths for real (the WER crash watcher, the PowerShell hang
// probe, the foreground/registry app-inventory seams, safeStorage/DPAPI), and
// captures real screenshots at every major step.
//
// It is NOT part of `npm test` (the pure vitest unit suite, which must stay
// display-/network-/Windows-free). This needs a launched app and a real
// desktop, so it runs only here. See tests/gui-e2e/README.md.
//
// Structure: a handful of scenarios, each launching its own app instance with
// a fresh userData dir (so ask-gate/rate-limit state never bleeds across) and,
// where a Windows-native input is needed, a scratch `%ProgramData%` the live
// crash watcher derives its watch directory from. Every check is recorded; any
// failure fails the job.

import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { homedir } from "node:os";
import { mkdirSync, writeFileSync } from "node:fs";
import { spawn, spawnSync } from "node:child_process";

import { waitForDebuggerEndpoint, attach, hasTarget, waitForTarget, CdpSession } from "./cdp.mjs";
import {
  scratchRoot,
  findPackagedExe,
  launchApp,
  deliverDeepLink,
  werReportArchiveDir,
  writeCrashArtifact,
  publikclipCrashFields,
  pathExists,
  isNonEmptyDir,
  rmrf,
  sleep,
} from "./app.mjs";
import { Results, flushLog, log } from "./report.mjs";

const __dirname = dirname(fileURLToPath(import.meta.url));
const REPO_DIR = join(__dirname, "..", "..");
const DIST_DIR = join(REPO_DIR, "dist");
const require = createRequire(import.meta.url);

const OUT_DIR = process.env.IRIS_E2E_OUT || join(REPO_DIR, "out", "gui-e2e");
const SHOTS_DIR = join(OUT_DIR, "screenshots");
const AUTOPILOT_TIMEOUT_MS = Number(process.env.IRIS_E2E_AUTOPILOT_TIMEOUT_MS || 720_000);

const results = new Results();

function shot(name) {
  return join(SHOTS_DIR, name);
}

/** Launch an app, wait for its debugger + chat renderer, run `fn`, always kill. */
async function withApp(opts, fn) {
  const app = launchApp(opts);
  try {
    await waitForDebuggerEndpoint(app.port);
    await fn(app);
  } finally {
    app.kill();
    await sleep(500);
  }
}

// The env that makes the app come up signed-out with the test-only hooks on and
// no publik account configured (so onboarding shows and no real model call is
// possible). IRIS_E2E=1 unlocks the `e2e_open_settings` guide command only.
const baseEnv = {
  IRIS_E2E: "1",
  IRIS_SUPABASE_URL: "",
  IRIS_SUPABASE_ANON_KEY: "",
};

// ===========================================================================
// Scenario A — boot, onboarding, key storage, settings, signed-out query,
// window lifecycle, and real iris:// deep-link delivery.
// ===========================================================================
async function scenarioCoreUi(exePath) {
  results.scenario("A · Core UI: onboarding, keys, settings, signed-out query, windows, deep links");
  const userDataDir = join(scratchRoot(), "userdata-core");
  rmrf(userDataDir);

  await withApp({ exePath, userDataDir, env: baseEnv, name: "core" }, async (app) => {
    const chat = await attach(app.port, "chat/index.html");

    // 1. Boot & onboarding: signed-out setup panel with the BYO-key input and
    //    both sign-in buttons.
    await chat.waitForEval("!!document.getElementById('byo-key')", (v) => v === true, 15_000);
    const onboarding = await chat.eval(
      "({" +
        "setupVisible: document.getElementById('setup').classList.contains('visible')," +
        "hasByoKey: !!document.getElementById('byo-key')," +
        "hasGoogle: !!document.getElementById('signin-google')," +
        "hasGithub: !!document.getElementById('signin-github')," +
        "googleDisabled: document.getElementById('signin-google').disabled," +
        "setupText: (document.getElementById('setup-text').textContent||'')" +
      "})",
    );
    results.check("onboarding setup panel is visible when signed-out", onboarding.setupVisible);
    results.check("BYO Anthropic key input (#byo-key) is present", onboarding.hasByoKey);
    results.check("both sign-in buttons render", onboarding.hasGoogle && onboarding.hasGithub);
    results.check(
      "sign-in disabled + explained when no publik account configured",
      onboarding.googleDisabled && /no publik account/i.test(onboarding.setupText),
      onboarding.setupText,
    );
    await chat.screenshot(shot("01-onboarding.png"));

    // 2. Key storage via the bridge (real safeStorage / DPAPI on Windows).
    const initial = await chat.eval("window.iris.getSettings()");
    results.check("secretStorageAvailable is true on Windows (DPAPI)", initial.secretStorageAvailable === true);
    results.check("no Anthropic key stored initially", initial.hasAnthropicApiKey === false);
    results.check("no OpenAI key stored initially", initial.hasOpenAiApiKey === false);

    const setAnthropic = await chat.eval("window.iris.setSetting('anthropicApiKey','sk-ant-e2e-dummy-key')");
    const afterAnthropic = await chat.eval("window.iris.getSettings()");
    results.check("setting an Anthropic key returns true (encrypted OK)", setAnthropic === true);
    results.check("hasAnthropicApiKey flips true after set", afterAnthropic.hasAnthropicApiKey === true);
    results.check("OpenAI key still independent (false)", afterAnthropic.hasOpenAiApiKey === false);
    await chat.waitForEval(
      "(document.getElementById('tier').textContent||'')",
      (v) => typeof v === "string" && /anthropic key/i.test(v),
      5_000,
    ).catch(() => {});
    await chat.screenshot(shot("02-key-stored.png"));

    const setOpenAi = await chat.eval("window.iris.setSetting('openaiApiKey','sk-openai-e2e-dummy')");
    const afterOpenAi = await chat.eval("window.iris.getSettings()");
    results.check("setting an OpenAI key returns true", setOpenAi === true);
    results.check("hasOpenAiApiKey flips true, Anthropic still true (independent)",
      afterOpenAi.hasOpenAiApiKey === true && afterOpenAi.hasAnthropicApiKey === true);

    // Edge case: empty string clears a key (rejected/cleared, not stored blank).
    const clearAnthropic = await chat.eval("window.iris.setSetting('anthropicApiKey','')");
    const afterClearAnthropic = await chat.eval("window.iris.getSettings()");
    results.check("empty string clears the Anthropic key (returns true)", clearAnthropic === true);
    results.check("hasAnthropicApiKey is false after empty-string clear", afterClearAnthropic.hasAnthropicApiKey === false);
    results.check("OpenAI key survives clearing Anthropic (independent)", afterClearAnthropic.hasOpenAiApiKey === true);

    await chat.eval("window.iris.setSetting('openaiApiKey','')");
    const cleared = await chat.eval("window.iris.getSettings()");
    results.check("both keys clear to false", cleared.hasAnthropicApiKey === false && cleared.hasOpenAiApiKey === false);

    // 3. Settings window (opened via the IRIS_E2E-gated main-process hook, since
    //    a native tray click is not reachable from CDP). Verify the OpenAI field
    //    renders.
    await chat.eval("window.irisNative.invoke('e2e_open_settings', {})");
    const settings = await attach(app.port, "settings/index.html");
    await settings.waitForEval("!!document.getElementById('openaiApiKey')", (v) => v === true, 10_000);
    const settingsDom = await settings.eval(
      "({" +
        "hasAnthropic: !!document.getElementById('anthropicApiKey')," +
        "hasOpenAi: !!document.getElementById('openaiApiKey')," +
        "hasModel: !!document.getElementById('claudeModel')," +
        "hasAccount: !!document.getElementById('account-status')" +
      "})",
    );
    results.check("settings window renders the Anthropic key field", settingsDom.hasAnthropic);
    results.check("settings window renders the OpenAI (Tier C) key field", settingsDom.hasOpenAi);
    results.check("settings window renders the model select + account row", settingsDom.hasModel && settingsDom.hasAccount);
    await settings.screenshot(shot("03-settings.png"));
    settings.close();

    // 4. Signed-out sendQuery must PROMPT for a key, never make a paid model
    //    call. (No key is stored and we are not signed in.)
    const query = await chat.eval(
      "window.iris.sendQuery('what is on my screen right now?')" +
        ".then(function(v){return {ok:true, value:String(v).slice(0,300)};})" +
        ".catch(function(e){return {ok:false, message:String(e && e.message ? e.message : e)};})",
    );
    results.check("signed-out sendQuery rejects rather than querying", query.ok === false, JSON.stringify(query));
    results.check(
      "…and the rejection prompts for a key / sign-in",
      query.ok === false && /anthropic key|sign in/i.test(query.message || ""),
      query.message,
    );

    // 5. Window lifecycle: guide window opens; overlay window(s) present.
    await chat.eval("window.iris.openGuide()");
    const guideTarget = await waitForTarget(app.port, "guide/index.html", 15_000);
    results.check("guide window opens on request", !!guideTarget);
    const guide = await new CdpSession(guideTarget).open();
    await guide.screenshot(shot("04-guide.png")).catch(() => {});
    guide.close();

    const overlayPresent = await hasTarget(app.port, "overlay/index.html");
    results.check("at least one click-through overlay window is present", overlayPresent);
    if (overlayPresent) {
      const overlay = await attach(app.port, "overlay/index.html").catch(() => null);
      if (overlay) {
        await overlay.screenshot(shot("05-overlay.png")).catch(() => {});
        overlay.close();
      }
    }

    // 6. Real iris:// deep-link delivery through the single-instance lock.
    await chat.eval(
      "window.__e2e = { rejected: [], guideOpened: [] };" +
        "window.irisNative.listen('iris-deep-link-rejected', function(p){ window.__e2e.rejected.push(p); });" +
        "window.irisNative.listen('iris-guide-opened', function(p){ window.__e2e.guideOpened.push(p); });" +
        "'installed'",
    );
    // An unknown query parameter is rejected outright (not ignored).
    deliverDeepLink({ exePath, userDataDir, url: "iris://guide/openascii?version=1&bogus=1" });
    const rejected = await chat
      .waitForEval("window.__e2e.rejected", (v) => Array.isArray(v) && v.length > 0, 15_000)
      .catch(() => []);
    results.check(
      "unknown deep-link param is rejected (real second-instance delivery)",
      Array.isArray(rejected) && rejected.includes("unsupported Iris guide parameter"),
      JSON.stringify(rejected),
    );
    // A well-formed link is accepted and opens the guide.
    deliverDeepLink({ exePath, userDataDir, url: "iris://guide/openascii?version=1&branch=windows:desktop&step=2" });
    const accepted = await chat
      .waitForEval("window.__e2e.guideOpened", (v) => Array.isArray(v) && v.length > 0, 15_000)
      .catch(() => []);
    results.check(
      "well-formed deep link is accepted and opens the guide",
      Array.isArray(accepted) && accepted.length > 0 && accepted[0]?.slug === "openascii",
      JSON.stringify(accepted),
    );

    chat.close();
  });
}

// ===========================================================================
// The real Windows crash path: write a genuine Report.wer for publikclip-app.exe
// into the directory the live CrashArtifactWatcher is fs.watching, and assert
// the running app detects it and raises exactly one publikclip ask. Then drive
// each answer branch + the rate-limit / suppression edges. Each answer branch
// gets its own launch so the 24h gate + one-pending guard never cross-talk.
// ===========================================================================

/** Launch a crash-capable app whose %ProgramData% points at `programDataRoot`,
 *  with the WER ReportArchive pre-created so the watcher's fs.watch succeeds. */
async function launchCrashApp(exePath, tag, extraEnv = {}) {
  const programDataRoot = join(scratchRoot(), `programdata-${tag}`);
  const archiveDir = werReportArchiveDir(programDataRoot);
  mkdirSync(archiveDir, { recursive: true });
  const userDataDir = join(scratchRoot(), `userdata-${tag}`);
  rmrf(userDataDir);
  const app = launchApp({
    exePath,
    userDataDir,
    env: { ...baseEnv, ProgramData: programDataRoot, ...extraEnv },
    name: tag,
  });
  await waitForDebuggerEndpoint(app.port);
  const chat = await attach(app.port, "chat/index.html");
  // Let bootstrap's startDetection() hook the watch before we drop a report.
  await sleep(2500);
  return { app, chat, archiveDir };
}

async function raiseCrashAndWaitForAsk(chat, archiveDir, reportName, offset) {
  writeCrashArtifact(archiveDir, { reportName, fields: publikclipCrashFields(offset) });
  return await chat.waitForEval(
    "window.iris.getMaintainSnapshot()",
    (snap) => snap && snap.pendingAsk && snap.pendingAsk.appSlug === "publikclip",
    20_000,
    400,
  );
}

async function scenarioCrashConfirm(exePath) {
  results.scenario("B1 · Real WER crash → ask → 'something is broken' → fix ladder + 24h suppression");
  const { app, chat, archiveDir } = await launchCrashApp(exePath, "crash-confirm");
  try {
    const before = await chat.eval("window.iris.getMaintainSnapshot()");
    results.check("no pending ask before any crash", !before.pendingAsk);

    const snap = await raiseCrashAndWaitForAsk(chat, archiveDir, "publikclip_crash_0001", "000000000004a1b0");
    results.check("live CrashArtifactWatcher detected the real Report.wer and raised an ask", !!snap.pendingAsk);
    results.check("ask is attributed to publikclip", snap.pendingAsk.appSlug === "publikclip");
    results.check(
      "ask evidence reads in the user's terms",
      snap.pendingAsk.evidenceSentence === "publikclip quit unexpectedly a moment ago.",
      snap.pendingAsk.evidenceSentence,
    );
    // Screenshot the actual ask card window.
    const card = await attach(app.port, "maintain/index.html").catch(() => null);
    if (card) {
      await sleep(400);
      await card.screenshot(shot("06-crash-ask-card.png")).catch(() => {});
      card.close();
    }

    // Answer "yes, something is broken" → files to the pool + runs the ladder.
    await chat.eval("window.iris.answerMaintainAsk('somethingIsBroken')");
    const afterYes = await chat.waitForEval(
      "window.iris.getMaintainSnapshot()",
      (s) => s && s.pendingAsk === null && typeof s.fixStatusLine === "string" && s.fixStatusLine.length > 0,
      20_000,
      400,
    );
    results.check(
      "after 'yes' the ask clears and a fix-status line appears (fix ladder ran)",
      afterYes.pendingAsk === null && !!afterYes.fixStatusLine,
      afterYes.fixStatusLine,
    );
    const card2 = await attach(app.port, "maintain/index.html").catch(() => null);
    if (card2) {
      await sleep(400);
      await card2.screenshot(shot("07-fix-status.png")).catch(() => {});
      card2.close();
    }

    // Dismiss the fix status.
    await chat.eval("window.iris.clearMaintainFixStatus()");
    const cleared = await chat.eval("window.iris.getMaintainSnapshot()");
    results.check("clearMaintainFixStatus empties the snapshot", !cleared.pendingAsk && !cleared.fixStatusLine);

    // 24h rate-limit edge: a SECOND crash for the same app within 24h must not
    // raise a new ask.
    writeCrashArtifact(archiveDir, { reportName: "publikclip_crash_0002", fields: publikclipCrashFields("00000000000abc12") });
    await sleep(4000);
    const suppressed = await chat.eval("window.iris.getMaintainSnapshot()");
    results.check("second crash within 24h is rate-limit suppressed (no new ask)", !suppressed.pendingAsk);
  } catch (error) {
    results.scenarioError(error);
  } finally {
    app.kill();
    await sleep(500);
  }
}

async function scenarioCrashThatWasMe(exePath) {
  results.scenario("B2 · Real WER crash → 'that was me' → signature suppression");
  const { app, chat, archiveDir } = await launchCrashApp(exePath, "crash-benign");
  try {
    const snap = await raiseCrashAndWaitForAsk(chat, archiveDir, "publikclip_crash_b2a", "000000000004a1b0");
    results.check("ask raised for the real crash", snap.pendingAsk?.appSlug === "publikclip");

    await chat.eval("window.iris.answerMaintainAsk('thatWasMe')");
    const afterNo = await chat.waitForEval(
      "window.iris.getMaintainSnapshot()",
      (s) => s && s.pendingAsk === null,
      10_000,
      400,
    );
    results.check("'that was me' clears the ask with no fix status", afterNo.pendingAsk === null && !afterNo.fixStatusLine);

    // The SAME signature crashing again must be suppressed (marked benign).
    writeCrashArtifact(archiveDir, { reportName: "publikclip_crash_b2b", fields: publikclipCrashFields("000000000004a1b0") });
    await sleep(4000);
    const suppressed = await chat.eval("window.iris.getMaintainSnapshot()");
    results.check("same signature re-crash is suppressed after 'that was me'", !suppressed.pendingAsk);
  } catch (error) {
    results.scenarioError(error);
  } finally {
    app.kill();
    await sleep(500);
  }
}

async function scenarioCrashMuteUnmute(exePath) {
  results.scenario("B3 · Real WER crash → 'don't ask about this app' → mute + unmute");
  const { app, chat, archiveDir } = await launchCrashApp(exePath, "crash-mute");
  try {
    const snap = await raiseCrashAndWaitForAsk(chat, archiveDir, "publikclip_crash_b3", "000000000004a1b0");
    results.check("ask raised for the real crash", snap.pendingAsk?.appSlug === "publikclip");

    await chat.eval("window.iris.answerMaintainAsk('neverAskAboutThisApp')");
    await sleep(500);
    const muted = await chat.eval("window.iris.mutedMaintainApps()");
    results.check("muting adds publikclip to the mute list", Array.isArray(muted) && muted.includes("publikclip"), JSON.stringify(muted));

    await chat.eval("window.iris.unmuteMaintainApp('publikclip')");
    await sleep(300);
    const afterUnmute = await chat.eval("window.iris.mutedMaintainApps()");
    results.check("unmuting removes publikclip from the mute list", Array.isArray(afterUnmute) && !afterUnmute.includes("publikclip"), JSON.stringify(afterUnmute));
  } catch (error) {
    results.scenarioError(error);
  } finally {
    app.kill();
    await sleep(500);
  }
}

async function scenarioDemoCrash(exePath) {
  results.scenario("B4 · IRIS_MAINTAIN_DEMO_CRASH synthetic-ask path");
  const userDataDir = join(scratchRoot(), "userdata-demo-crash");
  rmrf(userDataDir);
  await withApp(
    { exePath, userDataDir, env: { ...baseEnv, IRIS_MAINTAIN_DEMO_CRASH: "publikclip" }, name: "demo-crash" },
    async (app) => {
      const chat = await attach(app.port, "chat/index.html");
      const snap = await chat.waitForEval(
        "window.iris.getMaintainSnapshot()",
        (s) => s && s.pendingAsk && s.pendingAsk.appSlug === "publikclip",
        20_000,
        400,
      );
      results.check("synthetic demo crash raises a publikclip ask ~3s in", snap.pendingAsk?.appSlug === "publikclip");
      results.check(
        "demo ask evidence sentence is user-facing",
        snap.pendingAsk?.evidenceSentence === "publikclip quit unexpectedly a moment ago.",
        snap.pendingAsk?.evidenceSentence,
      );
      const card = await attach(app.port, "maintain/index.html").catch(() => null);
      if (card) {
        await sleep(400);
        await card.screenshot(shot("08-demo-crash-ask.png")).catch(() => {});
        card.close();
      }
      chat.close();
    },
  );
}

// ===========================================================================
// Scenario C — the real PowerShell / registry seams, exercised against the
// actual compiled app code on real Windows. No launched app: these are the
// service functions the maintain controller wires in, run directly.
// ===========================================================================
async function scenarioPowerShellSeams() {
  results.scenario("C · Real PowerShell + app-inventory seams on Windows");
  try {
    const hangProbe = require(join(DIST_DIR, "services", "maintain", "hang-probe.js"));
    const inventory = require(join(DIST_DIR, "services", "maintain", "app-inventory.js"));
    const recipes = require(join(DIST_DIR, "services", "autopilot", "recipes.js"));

    // A real, live, windowless process (a sleeping node child) reports as
    // responsive; a killed pid reports as gone (undefined). This drives the
    // genuine `Get-Process ... Responding` PowerShell one-liner.
    const child = spawn(process.execPath, ["-e", "setTimeout(function(){}, 60000)"], { stdio: "ignore" });
    await sleep(1500);
    const liveVerdict = await hangProbe.checkProcessResponsiveViaPowerShell(child.pid);
    results.check("checkProcessResponsiveViaPowerShell(live pid) === true", liveVerdict === true, String(liveVerdict));

    spawnSync("taskkill", ["/pid", String(child.pid), "/T", "/F"], { stdio: "ignore" });
    await sleep(1500);
    const deadVerdict = await hangProbe.checkProcessResponsiveViaPowerShell(child.pid);
    results.check("checkProcessResponsiveViaPowerShell(dead pid) === undefined", deadVerdict === undefined, String(deadVerdict));

    // The foreground read (an Add-Type GetForegroundWindow + GetWindowThreadProcessId
    // P/Invoke) compiles and runs — proving the real Win32 seam works on the
    // runner. It returns either undefined or a well-formed {pid, processName}.
    const foreground = await inventory.readForegroundProcessViaPowerShell();
    const foregroundOk =
      foreground === undefined ||
      (foreground && Number.isInteger(foreground.pid) && foreground.pid > 0 && typeof foreground.processName === "string");
    results.check("readForegroundProcessViaPowerShell runs (Win32 P/Invoke) and returns a valid shape", foregroundOk, JSON.stringify(foreground));

    // The installed-resolution seam (a known-path existsSync check) runs for
    // real: publikclip is not installed on the runner.
    const inv = new inventory.WindowsAppInventory();
    results.check("catalogApp('publikclip-app.exe') matches the publikclip slug", inv.catalogApp("publikclip-app.exe")?.slug === "publikclip");
    results.check("catalogApp('notepad.exe') is not a catalog app", inv.catalogApp("notepad.exe") === undefined);
    const pubApp = inventory.windowsCatalogAppForSlug("publikclip");
    const installed = new inventory.KnownPathInstalledCatalogAppResolver().isInstalled(pubApp);
    results.check("KnownPathInstalledCatalogAppResolver runs; publikclip not installed on runner", installed === false, String(installed));
    results.check("installedCatalogSlugs() is empty on the runner", inv.installedCatalogSlugs().size === 0);

    const frontmost = await inv.frontmostCatalogApp();
    results.check("frontmostCatalogApp() is undefined (no catalog app frontmost) via real PS read", frontmost === undefined, JSON.stringify(frontmost));

    // publikclip's heavy source-build recipe is too slow to run on CI — assert
    // its shape statically (per the task's guidance) so the desktop/source-build
    // recipe is still verified.
    const publikclip = recipes.recipeForSlug("publikclip");
    results.check("publikclip recipe exists", !!publikclip);
    results.check("publikclip recipe pins its canonical repo", publikclip?.canonicalRepo === "Blueturboguy07/publikclip");
    results.check("publikclip recipe pins a reviewed commit", publikclip?.pinnedCommit === "a53a359b985b1d2d666266062936cc186f02340b");
    results.check(
      "publikclip recipe outputs the installed exe app-inventory recognizes",
      publikclip?.output?.type === "desktop_app" && String(publikclip?.output?.launch?.path || "").includes("publikclip-app.exe"),
    );
    results.check("openascii recipe is a local_web app", recipes.recipeForSlug("openascii")?.output?.type === "local_web");
  } catch (error) {
    results.scenarioError(error);
  }
}

// ===========================================================================
// Scenario D — the autopilot runs a real install end to end (openascii, a
// Node/pnpm local-web app): clone → install → dev server, on the runner.
// ===========================================================================
async function scenarioAutopilot(exePath) {
  results.scenario("D · Autopilot runs a real openascii install to finished");
  const userDataDir = join(scratchRoot(), "userdata-autopilot");
  rmrf(userDataDir);
  // Start clean so the clone step is exercised, not skipped.
  rmrf(join(homedir(), "OpenASCII"));
  // Pre-grant the one-time "Let Iris take control of your PC?" consent by
  // seeding settings.json, simulating a reader who already said yes on a prior
  // install. Without this, the autopilot's first run blocks on the consent
  // dialog — which no one can click headlessly — and the install never starts.
  mkdirSync(userDataDir, { recursive: true });
  writeFileSync(join(userDataDir, "settings.json"), JSON.stringify({ autopilotAutonomyGranted: true }));

  await withApp(
    {
      exePath,
      userDataDir,
      env: { ...baseEnv, IRIS_AUTOPILOT_DEMO: "openascii", COREPACK_ENABLE_DOWNLOAD_PROMPT: "0" },
      name: "autopilot",
    },
    async (app) => {
      const term = await attach(app.port, "autopilot/index.html", 30_000);
      // Capture the runner's event stream + finished signal from the renderer.
      await term.eval(
        "window.__ap = { events: [], finished: null, gates: [] };" +
          "window.irisNative.listen('autopilot:event', function(e){ window.__ap.events.push(e); });" +
          "window.irisNative.listen('autopilot:finished', function(o){ window.__ap.finished = o; });" +
          "window.irisNative.listen('autopilot:gate', function(g){ window.__ap.gates.push(g); });" +
          "'installed'",
      );
      log(`  autopilot: waiting up to ${Math.round(AUTOPILOT_TIMEOUT_MS / 1000)}s for a real clone+install+dev-server…`);

      const finished = await term
        .waitForEval("window.__ap.finished", (v) => v && typeof v === "object", AUTOPILOT_TIMEOUT_MS, 3000)
        .catch(() => null);

      await term.screenshot(shot("09-autopilot-terminal.png")).catch(() => {});

      const cloneDir = join(homedir(), "OpenASCII");
      results.check("autopilot cloned the OpenASCII repo (clone dir exists)", pathExists(cloneDir), cloneDir);
      results.check("clone is a real git checkout (.git present)", pathExists(join(cloneDir, ".git")));
      results.check("dependencies installed (node_modules present)", isNonEmptyDir(join(cloneDir, "node_modules")));
      results.check(
        "autopilot reached the finished state (dev server up → local_web)",
        finished && finished.type === "local_web",
        JSON.stringify(finished),
      );
      // Provenance fires on finish (a local_web install records "none" — the
      // decision still runs; the observable here is the finished output type,
      // asserted above; controller.recordInstallProvenance is unit-tested).
      term.close();
    },
  );
}

// ===========================================================================

async function main() {
  mkdirSync(SHOTS_DIR, { recursive: true });

  if (process.platform !== "win32") {
    log("GUI e2e is Windows-only (it launches the packaged Windows app on a real desktop). Skipping on " + process.platform + ".");
    results.write(OUT_DIR);
    flushLog(OUT_DIR);
    return;
  }

  const exePath = findPackagedExe(REPO_DIR);
  log(`Packaged app: ${exePath}`);
  log(`Screenshots + logs: ${OUT_DIR}`);

  // Each scenario is independent and self-contained; a throw in one is recorded
  // and the rest still run, so the results log covers everything even on a
  // partial failure.
  const scenarios = [
    () => scenarioCoreUi(exePath),
    () => scenarioCrashConfirm(exePath),
    () => scenarioCrashThatWasMe(exePath),
    () => scenarioCrashMuteUnmute(exePath),
    () => scenarioDemoCrash(exePath),
    () => scenarioPowerShellSeams(),
    () => scenarioAutopilot(exePath),
  ];

  for (const run of scenarios) {
    try {
      await run();
    } catch (error) {
      results.scenarioError(error);
    }
  }

  results.write(OUT_DIR);
  flushLog(OUT_DIR);

  const summary = results.summary();
  log(
    `\nSUMMARY: ${summary.scenarios} scenarios, ${summary.totalChecks} checks, ${summary.failedChecks} failed — ${summary.passed ? "GREEN" : "RED"}`,
  );
  if (!summary.passed) {
    process.exitCode = 1;
  }
}

// Hard watchdog. The suite launches a real app whose autopilot leaves a
// `pnpm dev` server running and holds open CDP sockets; if any of that keeps
// the event loop alive after the assertions finish, Node would hang until the
// CI job's own timeout CANCELS the step — which discards the exit code and the
// green/red verdict with it (that is exactly what happened once). This bounds
// the whole run and force-exits with a failure if it is ever exceeded, so a
// hang surfaces as an honest red instead of a silent cancel.
const WATCHDOG_MS = 18 * 60 * 1000;
const watchdog = setTimeout(() => {
  log(`WATCHDOG: gui-e2e exceeded ${WATCHDOG_MS / 60000} min — forcing exit(1)`);
  try {
    results.write(OUT_DIR);
    flushLog(OUT_DIR);
  } catch {
    // best effort — we are force-exiting regardless
  }
  process.exit(1);
}, WATCHDOG_MS);
watchdog.unref();

// Force a clean exit once main resolves. Without this, an open handle (the
// autopilot dev server, a CDP WebSocket) keeps Node alive even though every
// check has finished — `process.exitCode` alone is not enough.
main()
  .then(() => {
    process.exit(process.exitCode ?? 0);
  })
  .catch((error) => {
    log(`FATAL: ${error?.stack || error}`);
    results.write(OUT_DIR);
    flushLog(OUT_DIR);
    process.exit(1);
  });
