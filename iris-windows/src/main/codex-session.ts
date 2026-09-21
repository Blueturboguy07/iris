/**
 * codex-session.ts
 *
 * Runs the reader's own `codex` binary and hands its answer back as a chat
 * reply. Every decision lives in `services/codex-chat.ts`; this file owns the
 * things a unit test cannot have — spawning a process and putting screenshots
 * on disk where `--image` can reach them.
 *
 * Iris stores no OpenAI credential anywhere. The CLI owns the reader's sign-in,
 * which is the whole reason this route is allowed to exist where importing a
 * Claude.ai token is not (`docs/assistant-credentials.md`).
 */

import { execFile } from "node:child_process";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { AssistantTransportFailure } from "../services/assistant-transport";
import { ChatBackend } from "../services/claude";
import {
  CODEX_EXECUTABLE,
  CodexChatMessage,
  buildCodexChatArguments,
  classifyCodexFailure,
  codexFailureMessage,
  extractFinalMessage,
  foldConversationIntoOnePrompt,
} from "../services/codex-chat";

/** Codex is markedly slower than an API call; this is a ceiling, not a target. */
const CODEX_TIMEOUT_MS = 180_000;

/** Enough for a screenshot-bearing prompt without inviting an unbounded read. */
const MAX_OUTPUT_BYTES = 8 * 1024 * 1024;

interface ImageBlock {
  type: string;
  source?: { data?: string; media_type?: string };
}

interface TextBlock {
  type: string;
  text?: string;
}

/**
 * Pulls the screenshots and the prose apart. Anthropic's content blocks carry
 * images inline as base64; `codex exec` wants file paths, so the images are
 * written out and the text is what goes into the folded prompt.
 */
function splitContent(content: unknown): { text: string; imagesBase64: string[] } {
  if (typeof content === "string") return { text: content, imagesBase64: [] };
  if (!Array.isArray(content)) return { text: "", imagesBase64: [] };

  const textParts: string[] = [];
  const imagesBase64: string[] = [];
  for (const rawBlock of content) {
    const block = rawBlock as TextBlock & ImageBlock;
    if (block.type === "text" && typeof block.text === "string") textParts.push(block.text);
    if (block.type === "image" && typeof block.source?.data === "string") {
      imagesBase64.push(block.source.data);
    }
  }
  return { text: textParts.join("\n"), imagesBase64 };
}

export class CodexChatBackend implements ChatBackend {
  async respond(request: {
    system: string;
    messages: Array<{ role: string; content: unknown }>;
    maxTokens: number;
  }): Promise<string> {
    const conversation: CodexChatMessage[] = [];
    const imagesBase64: string[] = [];

    for (const message of request.messages) {
      const { text, imagesBase64: messageImages } = splitContent(message.content);
      imagesBase64.push(...messageImages);
      if (text.length > 0) {
        conversation.push({ role: message.role === "assistant" ? "assistant" : "user", text });
      }
    }

    const scratchDirectory = fs.mkdtempSync(path.join(os.tmpdir(), "iris-codex-"));
    try {
      const imagePaths = imagesBase64.map((base64, index) => {
        const imagePath = path.join(scratchDirectory, `screen-${index + 1}.jpg`);
        fs.writeFileSync(imagePath, Buffer.from(base64, "base64"));
        return imagePath;
      });

      const prompt = foldConversationIntoOnePrompt({
        system: request.system,
        messages: conversation,
        attachedImageCount: imagePaths.length,
      });

      const result = await this.runCodex(buildCodexChatArguments({ imagePaths }), prompt, scratchDirectory);

      const failure = classifyCodexFailure({
        exitCode: result.exitCode,
        stderr: result.stderr,
        stdout: result.stdout,
        spawnFailed: result.spawnFailed,
      });
      if (failure) {
        throw new AssistantTransportFailure({
          kind: "codexUnavailable",
          reason: codexFailureMessage(failure),
        });
      }

      return extractFinalMessage(result.stdout);
    } finally {
      // The screenshots are the reader's screen. They do not outlive the call.
      fs.rmSync(scratchDirectory, { recursive: true, force: true });
    }
  }

  /**
   * The prompt goes in on stdin rather than as an argument: a screenshot-laden
   * conversation is far past any Windows command-line length limit, and a
   * prompt on the command line would also be visible to every other process on
   * the machine in the process list.
   */
  private runCodex(
    args: string[],
    prompt: string,
    workingDirectory: string
  ): Promise<{ exitCode: number; stdout: string; stderr: string; spawnFailed: boolean }> {
    return new Promise((resolve) => {
      const child = execFile(
        CODEX_EXECUTABLE,
        args,
        {
          cwd: workingDirectory,
          timeout: CODEX_TIMEOUT_MS,
          maxBuffer: MAX_OUTPUT_BYTES,
          windowsHide: true,
        },
        (error, stdout, stderr) => {
          const spawnFailed = Boolean(
            error && (error as NodeJS.ErrnoException).code === "ENOENT"
          );
          const exitCode =
            error && typeof (error as { code?: unknown }).code === "number"
              ? ((error as { code: number }).code)
              : error
                ? 1
                : 0;
          resolve({ exitCode, stdout: stdout ?? "", stderr: stderr ?? "", spawnFailed });
        }
      );

      child.stdin?.end(prompt);
    });
  }
}

/**
 * Whether the reader has a usable codex. Cheap enough to call when picking a
 * transport, and deliberately answers "no" rather than throwing, so a missing
 * CLI is simply one fewer option rather than an error on an unrelated path.
 */
export function codexIsAvailable(): Promise<boolean> {
  return new Promise((resolve) => {
    execFile(
      CODEX_EXECUTABLE,
      ["--version"],
      { timeout: 5_000, windowsHide: true },
      (error) => resolve(!error)
    );
  });
}

/**
 * Opens `codex login` in a real console window.
 *
 * Deliberately not run headlessly and scraped: the login is an interactive
 * browser flow that ends with a credential Iris must never see or store. A
 * visible console the reader drives themselves is both the honest shape and
 * the only one that keeps Iris out of the credential path — which is exactly
 * what makes this route permissible where importing a Claude.ai token is not.
 *
 * Windows-only by construction (`cmd /c start`), which is fine: this file only
 * ever runs in the packaged Windows app, and the unit suite never calls it.
 */
export function openCodexLogin(): void {
  // `start` needs a title argument before the command when any argument is
  // quoted, hence the empty "".
  execFile("cmd", ["/c", "start", "", "cmd", "/k", "codex login"], { windowsHide: true }, () => {
    // Nothing to report: the reader can see the window, and the next
    // availability probe is what actually tells Iris whether it worked.
  });
}
