/**
 * state-store.ts
 *
 * The concrete, Electron-backed implementation of every read-all/write-all
 * persistence seam `services/maintain/*.ts` defines — the porting spec's
 * `main/maintain/` `MaintainStateStore`. One JSON file, `userData/maintain.json`,
 * in the same "plain JSON, safe to paste into a bug report" spirit as
 * `main/settings.ts`'s `settings.json`: nothing secret ever lives here (no API
 * keys, no GitHub tokens — those stay in `secrets.ts` behind `safeStorage`).
 * This file holds:
 *
 *   - the ask-gate state `incident-coordinator.ts` needs
 *     (`MaintainIncidentGatePersistence`): muted apps, suppressed signature
 *     ids, per-app last-ask timestamps, per-day incident counts.
 *   - the install-provenance records `install-provenance.ts` needs
 *     (`InstallProvenancePersistence`): how each catalog app got onto this
 *     machine, and — for a guide-source clone — where and at what commit.
 *   - the pseudonymous install id `install-identity.ts` needs
 *     (`InstallIdentityPersistence`): a random UUID, rotated every 90 days.
 *
 * Explicitly NOT this file's job: the patch queue (`patch-queue.ts` owns its
 * own per-`(appSlug, recipeId)` JSON file under `userData/patch-queue/`, per
 * that module's own header) and anything secret (`secrets.ts`).
 *
 * One JSON file, one read-modify-write per mutation — matching
 * `SettingsStore`'s shape exactly (read once at construction, rewrite the
 * whole file on every `set`). Maintain-mode writes are rare (an ask raised
 * roughly once a day per app, at most) so there is no contention this needs
 * to be cleverer about.
 */

import { app } from "electron";
import * as fs from "node:fs";
import * as path from "node:path";
import {
  EMPTY_MAINTAIN_INCIDENT_GATE_STATE,
  type MaintainIncidentGatePersistence,
  type MaintainIncidentGateState,
} from "../../services/maintain/incident-coordinator";
import type { InstallIdentityPersistence, InstallIdentityRecord } from "../../services/maintain/install-identity";
import type { InstallProvenancePersistence, RecordedInstallProvenance } from "../../services/maintain/install-provenance";

interface MaintainStateFileContents {
  readonly gate: MaintainIncidentGateState;
  readonly provenanceByAppSlug: Readonly<Record<string, RecordedInstallProvenance>>;
  readonly installIdentity: InstallIdentityRecord | null;
}

const EMPTY_STATE: MaintainStateFileContents = {
  gate: EMPTY_MAINTAIN_INCIDENT_GATE_STATE,
  provenanceByAppSlug: {},
  installIdentity: null,
};

function maintainStateFilePath(): string {
  const userDataPath = app.isReady() ? app.getPath("userData") : path.join(process.env.APPDATA || process.env.HOME || ".", "iris");
  return path.join(userDataPath, "maintain.json");
}

/**
 * The one file-backed store behind all three seams above. Constructed once,
 * at the same point `SettingsStore`/`AccountSession` are constructed in
 * `main/index.ts`'s `app.whenReady()` handler, and passed down to
 * `main/maintain/controller.ts`.
 */
export class MaintainStateStore
  implements MaintainIncidentGatePersistence, InstallProvenancePersistence, InstallIdentityPersistence
{
  private data: MaintainStateFileContents;
  private readonly filePath: string;

  constructor() {
    this.filePath = maintainStateFilePath();
    this.data = this.readFromDisk();
  }

  // MARK: - MaintainIncidentGatePersistence

  readGateState(): MaintainIncidentGateState {
    return this.data.gate;
  }

  writeGateState(state: MaintainIncidentGateState): void {
    this.data = { ...this.data, gate: state };
    this.writeToDisk();
  }

  // MARK: - InstallProvenancePersistence

  readAllProvenanceRecords(): Readonly<Record<string, RecordedInstallProvenance>> {
    return this.data.provenanceByAppSlug;
  }

  writeAllProvenanceRecords(records: Readonly<Record<string, RecordedInstallProvenance>>): void {
    this.data = { ...this.data, provenanceByAppSlug: records };
    this.writeToDisk();
  }

  // MARK: - InstallIdentityPersistence

  readCurrentInstallIdentity(): InstallIdentityRecord | null {
    return this.data.installIdentity;
  }

  writeCurrentInstallIdentity(record: InstallIdentityRecord): void {
    this.data = { ...this.data, installIdentity: record };
    this.writeToDisk();
  }

  // MARK: - Disk I/O

  private readFromDisk(): MaintainStateFileContents {
    try {
      if (!fs.existsSync(this.filePath)) return EMPTY_STATE;
      const raw = JSON.parse(fs.readFileSync(this.filePath, "utf-8")) as Partial<MaintainStateFileContents>;
      return {
        gate: raw.gate ?? EMPTY_STATE.gate,
        provenanceByAppSlug: raw.provenanceByAppSlug ?? EMPTY_STATE.provenanceByAppSlug,
        installIdentity: raw.installIdentity ?? EMPTY_STATE.installIdentity,
      };
    } catch {
      // A corrupt maintain.json is treated as an empty one: the app re-learns
      // the ask gate and provenance from scratch, which is recoverable and
      // never worth crashing over.
      return EMPTY_STATE;
    }
  }

  private writeToDisk(): void {
    try {
      fs.mkdirSync(path.dirname(this.filePath), { recursive: true });
      fs.writeFileSync(this.filePath, JSON.stringify(this.data, null, 2));
    } catch {
      // Silent fail on write error, matching `SettingsStore.save()` — a
      // maintain-state write is never worth crashing the app over.
    }
  }
}
