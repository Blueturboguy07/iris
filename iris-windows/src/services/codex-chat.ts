/**
 * codex-chat.ts
 *
 * Driving the reader's own `codex` CLI as a chat model.
 *
 * Why this is possible at all: Iris's companion chat sends NO tools. The body
 * is a system prompt, a conversation, and screenshots, and the reply is plain
 * text carrying `[POINT:x,y:label:screenN]` tags. `codex exec` takes one prompt
 * and `--image` files and prints a final message — which is exactly that shape.
 * The thing Codex genuinely cannot serve is the Anthropic tool-use wire format,
 * and chat never asks for it. (Maintain mode's fix ladder reached the same
 * conclusion first; see `autopilot/fix-ladder.ts`'s plain-text contract.)
 *
 * What is NOT equivalent, stated plainly rather than discovered later:
 *   - Codex is an agent. Its instinct on a task is to go and use its own shell
 *     and file tools, which here would produce an empty reply — its cwd is a
 *     scratch directory and its sandbox is read-only. The framing preamble
 *     below is what holds it to answering instead, and a preamble is a request,
 *     not a guarantee.
 *   - There is no system-prompt channel, so the system prompt is folded in as a
 *     leading block and the conversation is replayed under speaker labels. A
 *     model that ignores the framing reads Iris's system prompt as ordinary
 *     text rather than as instructions.
 *   - Pointing accuracy is a property of whichever model the reader's `codex`
 *     is configured with, and Iris does not choose it.
 *
 * Pure: argv, prompt text, output parsing and error classification. Spawning
 * and temp files belong to `main/codex-session.ts`.
 *
 * This mirrors `iris-macos/leanring-buddy/CodexMaintainProvider.swift`'s
 * invocation rules — parity of behaviour, not of code.
 */

/** The reader's own binary. Never a path Iris constructs from input. */
export const CODEX_EXECUTABLE = "codex";

/**
 * Flag prefixes Iris must never pass. Codex spells its escape hatches as
 * flags, and a prompt is attacker-influenced text (a guide, a web page, a
 * screenshot's contents) — so the allowlist is enforced on the argv Iris
 * builds, not merely intended.
 */
const FORBIDDEN_FLAG_PREFIXES = [
  "--dangerously",
  "--yolo",
  "--full-auto",
  "--search",
  "--config",
  "-c",
] as const;

export class CodexArgumentError extends Error {}

/**
 * One `codex exec` invocation.
 *
 * `--sandbox read-only` and `--ignore-user-config` are both required, not
 * defaults to be trusted: the reader's own `~/.codex/config.toml` can pin a
 * model, a sandbox mode, or an approval policy, and Iris must not inherit any
 * of it when it is the one spending the reader's plan.
 */
export function buildCodexChatArguments(options: {
  imagePaths?: string[];
  /** Only when the caller has a specific reason; otherwise codex's own default. */
  model?: string | null;
}): string[] {
  const args = ["exec", "--sandbox", "read-only", "--ignore-user-config"];

  if (options.model) {
    if (options.model.startsWith("-")) {
      throw new CodexArgumentError("a model name may not look like a flag");
    }
    args.push("--model", options.model);
  }

  for (const imagePath of options.imagePaths ?? []) {
    if (imagePath.startsWith("-")) {
      throw new CodexArgumentError("an image path may not look like a flag");
    }
    args.push("--image", imagePath);
  }

  for (const argument of args) {
    for (const forbidden of FORBIDDEN_FLAG_PREFIXES) {
      if (argument === forbidden || argument.startsWith(`${forbidden}=`)) {
        throw new CodexArgumentError(`refusing to pass ${argument} to codex`);
      }
    }
  }

  return args;
}

/**
 * Tells Codex it is being used as a text model, not turned loose on a repo.
 *
 * Without this it answers by trying to act — and its sandbox is read-only in a
 * scratch directory, so acting fails silently and the reply comes back empty.
 */
export const CODEX_FRAMING_PREAMBLE = `You are being used as a text model inside another program. Do not use YOUR OWN shell, file, or search tools — the directory you are running in is an empty scratch directory with nothing relevant in it, so any attempt will silently fail. Your entire reply is the deliverable.

Answer as the assistant described below, following its output format exactly. Reply with the answer itself and nothing else: no preamble, no explanation of what you are about to do, no summary of what you did.`;

export interface CodexChatMessage {
  role: "user" | "assistant";
  text: string;
}

/**
 * Folds the system prompt and the conversation into the one prompt `codex
 * exec` accepts.
 *
 * Speaker labels rather than a transcript format Codex might try to continue:
 * the last line is always the live question, so the model is answering rather
 * than predicting the next turn of a document.
 */
export function foldConversationIntoOnePrompt(options: {
  system: string;
  messages: CodexChatMessage[];
  /** How many screenshots were attached, so the prompt can refer to them. */
  attachedImageCount: number;
}): string {
  const sections: string[] = [CODEX_FRAMING_PREAMBLE, "", "--- ASSISTANT INSTRUCTIONS ---", options.system];

  if (options.attachedImageCount > 0) {
    sections.push(
      "",
      "--- SCREENS ---",
      options.attachedImageCount === 1
        ? "One screenshot is attached to this message: it is screen 1."
        : `${options.attachedImageCount} screenshots are attached to this message, in order: screen 1 through screen ${options.attachedImageCount}.`
    );
  }

  sections.push("", "--- CONVERSATION ---");
  for (const message of options.messages) {
    sections.push(`${message.role === "user" ? "User" : "Assistant"}: ${message.text}`);
  }
  sections.push("", "Reply as the assistant, to the final User turn.");

  return sections.join("\n");
}

/**
 * Codex writes progress lines to stdout alongside the answer, each stamped
 * with an RFC 3339 timestamp. The final message is what follows the last
 * `codex` banner line; anything timestamped is log, not answer.
 */
export function extractFinalMessage(stdout: string): string {
  const lines = stdout.split(/\r?\n/);
  const withoutLogLines = lines.filter(
    (line) => !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z?\s/.test(line)
  );
  return withoutLogLines.join("\n").trim();
}

export type CodexFailure =
  /** The binary is not on PATH at all. */
  | { kind: "notInstalled" }
  /** Installed, but nobody is signed in. */
  | { kind: "notSignedIn" }
  /** Iris and the reader's codex disagree about the command line. */
  | { kind: "argumentMismatch"; detail: string }
  /** Ran, exited non-zero, reason unrecognised. */
  | { kind: "failed"; exitCode: number; detail: string }
  /** Ran, exited zero, but said nothing Iris can use. */
  | { kind: "emptyReply" };

/**
 * Classifies a finished run. Quotes codex when Iris does not recognise the
 * failure, because a passed-through sentence from the tool the reader already
 * uses beats Iris inventing a diagnosis.
 */
export function classifyCodexFailure(options: {
  exitCode: number;
  stderr: string;
  stdout: string;
  spawnFailed?: boolean;
}): CodexFailure | null {
  if (options.spawnFailed) return { kind: "notInstalled" };

  const combined = `${options.stderr}\n${options.stdout}`.toLowerCase();

  if (options.exitCode === 0) {
    return extractFinalMessage(options.stdout).length === 0 ? { kind: "emptyReply" } : null;
  }

  if (
    combined.includes("codex login") ||
    combined.includes("not logged in") ||
    combined.includes("please sign in")
  ) {
    return { kind: "notSignedIn" };
  }

  // clap's "error: unexpected argument '…' found" over a `Usage: codex exec`
  // block — the two are out of step, which is neither a credential nor a model
  // problem and must not be reported as one.
  if (combined.includes("unexpected argument") || combined.includes("usage: codex exec")) {
    return { kind: "argumentMismatch", detail: firstUsefulLine(options.stderr) };
  }

  return {
    kind: "failed",
    exitCode: options.exitCode,
    detail: firstUsefulLine(options.stderr) || firstUsefulLine(options.stdout),
  };
}

function firstUsefulLine(text: string): string {
  return (
    text
      .split(/\r?\n/)
      .map((line) => line.trim())
      .find((line) => line.length > 0 && !/^\d{4}-\d{2}-\d{2}T/.test(line)) ?? ""
  );
}

/** What the reader is told, in the assistant's own lowercase voice. */
export function codexFailureMessage(failure: CodexFailure): string {
  switch (failure.kind) {
    case "notInstalled":
      return "i couldn't find the codex command. install it with `npm install -g @openai/codex`, then sign in with `codex login`.";
    case "notSignedIn":
      return "your codex cli isn't signed in. run `codex login` in a terminal, then ask me again.";
    case "argumentMismatch":
      return `your codex cli wouldn't accept how iris called it, so the two are out of step. update codex (\`npm install -g @openai/codex@latest\`), or update iris.${failure.detail ? ` codex said: ${failure.detail}` : ""}`;
    case "emptyReply":
      return "codex finished without answering. that usually means it tried to go and do the task instead of replying — ask again, or switch provider in settings.";
    case "failed":
      return `codex couldn't finish that.${failure.detail ? ` it said: ${failure.detail}` : ""}`;
  }
}
