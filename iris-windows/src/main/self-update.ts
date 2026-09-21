/**
 * self-update.ts
 *
 * Background awareness that a newer Iris exists — the main-process wiring
 * around `services/self-update-check.ts`'s pure decision logic. Checks once
 * shortly after launch, then on an interval, and announces a given release at
 * most once: the tray's "Update to Iris x.y.z" item reflects the latest check
 * every time, but the notification and `lastAnnouncedUpdateTag` write only
 * fire the first time a release is seen, so a reader who dismisses it is not
 * renotified every few hours for the same build.
 */
import { Notification, shell } from "electron";
import { checkForIrisUpdate } from "../services/self-update-check";
import { setTrayUpdateAvailable } from "./tray";
import type { SettingsStore } from "./settings";

const INITIAL_DELAY_MS = 30_000;
const RECHECK_INTERVAL_MS = 6 * 60 * 60 * 1000;

export function startSelfUpdateWatch(settings: SettingsStore, currentVersion: string): void {
  const runCheck = () => void checkAndAnnounce(settings, currentVersion);
  setTimeout(runCheck, INITIAL_DELAY_MS);
  setInterval(runCheck, RECHECK_INTERVAL_MS);
}

async function checkAndAnnounce(settings: SettingsStore, currentVersion: string): Promise<void> {
  const result = await checkForIrisUpdate(currentVersion);

  if (!result.available || !result.latestVersion || !result.downloadUrl || !result.latestTag) {
    setTrayUpdateAvailable(null);
    return;
  }

  const downloadUrl = result.downloadUrl;
  setTrayUpdateAvailable({ version: result.latestVersion, downloadUrl });

  if (settings.get("lastAnnouncedUpdateTag") === result.latestTag) return;
  settings.set("lastAnnouncedUpdateTag", result.latestTag);

  if (!Notification.isSupported()) return;
  const notification = new Notification({
    title: "A new version of Iris is available",
    body: `Iris ${result.latestVersion} is ready to install.`,
  });
  notification.on("click", () => void shell.openExternal(downloadUrl));
  notification.show();
}
