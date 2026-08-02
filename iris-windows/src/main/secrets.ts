/**
 * secrets.ts
 *
 * The only code in this app that touches a secret at rest.
 *
 * Upstream kept every API key in `%APPDATA%/clicky-windows/settings.json` in
 * plain text, which its own notes called "acceptable for a local personal tool;
 * not appropriate for distributed binaries". Iris is a distributed binary, so
 * secrets go through Electron `safeStorage`, which on Windows is DPAPI: the
 * ciphertext is bound to the Windows user account and is useless if the file is
 * copied off the machine.
 *
 * There are exactly two secrets, matching `iris-macos`'s `KeychainStore`:
 *   - the user's own Anthropic API key (BYO tier)
 *   - the Supabase refresh token
 *
 * The access token is deliberately NOT here: it lives in memory only, per
 * protocol section 4.
 *
 * Neither value is ever logged. `toString()` is overridden nowhere because
 * nothing in this module ever returns a wrapper — the raw string leaves only
 * through the two read functions, and their callers hand it straight to
 * `assistant-transport`.
 */

import { app, safeStorage } from "electron";
import * as fs from "node:fs";
import * as path from "node:path";

export type SecretName = "anthropicApiKey" | "supabaseRefreshToken";

interface SecretFileContents {
  /** base64 of the DPAPI ciphertext, keyed by secret name. */
  [secretName: string]: string;
}

/** Kept beside settings.json but in its own file, so a settings dump that gets
 *  pasted into a bug report never contains ciphertext at all. */
function secretsFilePath(): string {
  const userDataPath = app.isReady()
    ? app.getPath("userData")
    : path.join(process.env.APPDATA || process.env.HOME || ".", "iris");
  return path.join(userDataPath, "secrets.json");
}

function readSecretFile(): SecretFileContents {
  try {
    const filePath = secretsFilePath();
    if (!fs.existsSync(filePath)) return {};
    return JSON.parse(fs.readFileSync(filePath, "utf-8")) as SecretFileContents;
  } catch {
    // A corrupt secrets file is treated as an empty one: the user re-enters the
    // key, which is recoverable. Throwing here would make the app unusable.
    return {};
  }
}

function writeSecretFile(contents: SecretFileContents): void {
  const filePath = secretsFilePath();
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, JSON.stringify(contents, null, 2), { mode: 0o600 });
}

/**
 * False on a machine where the OS refuses to provide encryption. The UI must
 * say so rather than silently falling back to plaintext — writing a secret in
 * the clear is never the helpful choice.
 */
export function secretStorageIsAvailable(): boolean {
  try {
    return safeStorage.isEncryptionAvailable();
  } catch {
    return false;
  }
}

export function readSecret(secretName: SecretName): string | null {
  if (!secretStorageIsAvailable()) return null;
  const encoded = readSecretFile()[secretName];
  if (!encoded) return null;
  try {
    return safeStorage.decryptString(Buffer.from(encoded, "base64")) || null;
  } catch {
    // Ciphertext from another Windows account, or a rotated DPAPI key.
    return null;
  }
}

export function writeSecret(secretName: SecretName, secretValue: string): boolean {
  if (!secretStorageIsAvailable()) return false;
  try {
    const contents = readSecretFile();
    contents[secretName] = safeStorage.encryptString(secretValue).toString("base64");
    writeSecretFile(contents);
    return true;
  } catch {
    return false;
  }
}

export function deleteSecret(secretName: SecretName): void {
  try {
    const contents = readSecretFile();
    if (secretName in contents) {
      delete contents[secretName];
      writeSecretFile(contents);
    }
  } catch {
    // Nothing to clean up.
  }
}

/**
 * Upstream's plaintext keys, removed from settings.json on first run so a
 * pre-fork install does not leave a key sitting in the clear forever. The
 * Anthropic one is migrated into safeStorage; the providers Iris dropped are
 * simply deleted.
 */
export const LEGACY_PLAINTEXT_KEY_NAMES = [
  "anthropicApiKey",
  "openaiApiKey",
  "openrouterApiKey",
  "assemblyaiApiKey",
  "elevenlabsApiKey",
] as const;
