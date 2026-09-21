import { describe, expect, it } from "vitest";
import {
  CODEX_FRAMING_PREAMBLE,
  CodexArgumentError,
  buildCodexChatArguments,
  classifyCodexFailure,
  codexFailureMessage,
  extractFinalMessage,
  foldConversationIntoOnePrompt,
} from "../src/services/codex-chat";

/**
 * Codex can serve chat because chat sends no tools — a system prompt, some
 * screenshots, and a plain-text reply carrying POINT tags. These tests hold
 * the parts of that which are Iris's to get right: the argv it builds, the
 * prompt it folds, and what it says when the CLI is not usable.
 */

describe("the codex invocation", () => {
  it("always pins the sandbox and ignores the reader's own config", () => {
    // Their ~/.codex/config.toml can pin a model, a sandbox mode or an
    // approval policy, and Iris must inherit none of it while spending their
    // plan on Iris's behalf.
    const args = buildCodexChatArguments({});
    expect(args.slice(0, 4)).toEqual(["exec", "--sandbox", "read-only"].concat(["--ignore-user-config"]));
  });

  it("passes each screenshot as its own --image", () => {
    const args = buildCodexChatArguments({ imagePaths: ["/tmp/a/screen-1.jpg", "/tmp/a/screen-2.jpg"] });
    expect(args.filter((argument) => argument === "--image")).toHaveLength(2);
    expect(args).toContain("/tmp/a/screen-2.jpg");
  });

  it("refuses an image path or model that could be read as a flag", () => {
    // A prompt is attacker-influenced text; so, potentially, is anything
    // derived from one. The argv is where that has to stop.
    expect(() => buildCodexChatArguments({ imagePaths: ["--dangerously-bypass"] })).toThrow(
      CodexArgumentError
    );
    expect(() => buildCodexChatArguments({ model: "--yolo" })).toThrow(CodexArgumentError);
  });

  it("never emits one of codex's escape hatches", () => {
    const args = buildCodexChatArguments({ imagePaths: ["/tmp/s.jpg"], model: "gpt-5" });
    for (const forbidden of ["--dangerously-bypass-approvals-and-sandbox", "--yolo", "--full-auto", "--search"]) {
      expect(args).not.toContain(forbidden);
    }
  });
});

describe("folding a conversation into one prompt", () => {
  const prompt = foldConversationIntoOnePrompt({
    system: "You are Iris. Emit [POINT:x,y:label:screenN] tags.",
    messages: [
      { role: "user", text: "where is the save button?" },
      { role: "assistant", text: "top left." },
      { role: "user", text: "and the export one?" },
    ],
    attachedImageCount: 2,
  });

  it("leads with the framing that stops codex trying to act instead of answering", () => {
    expect(prompt.startsWith(CODEX_FRAMING_PREAMBLE)).toBe(true);
  });

  it("carries the system prompt, since codex has no system channel", () => {
    expect(prompt).toContain("Emit [POINT:x,y:label:screenN] tags.");
  });

  it("numbers the screens so POINT tags can name the right one", () => {
    expect(prompt).toContain("screen 1 through screen 2");
  });

  it("replays the conversation under speaker labels, ending on the live question", () => {
    expect(prompt).toContain("User: where is the save button?");
    expect(prompt).toContain("Assistant: top left.");
    expect(prompt.trimEnd().endsWith("Reply as the assistant, to the final User turn.")).toBe(true);
  });

  it("says nothing about screens when none are attached", () => {
    const textOnly = foldConversationIntoOnePrompt({
      system: "s",
      messages: [{ role: "user", text: "hi" }],
      attachedImageCount: 0,
    });
    expect(textOnly).not.toContain("SCREENS");
  });

  it("uses the singular for one screen", () => {
    const one = foldConversationIntoOnePrompt({
      system: "s",
      messages: [{ role: "user", text: "hi" }],
      attachedImageCount: 1,
    });
    expect(one).toContain("it is screen 1");
  });
});

describe("reading codex's output", () => {
  it("drops the timestamped log lines and keeps the answer", () => {
    const stdout = [
      "2026-09-21T04:53:26.352513Z  INFO codex_exec: starting",
      "The save button is here [POINT:120,40:Save:screen1]",
      "2026-09-21T04:53:31.100000Z  INFO codex_exec: done",
    ].join("\n");
    expect(extractFinalMessage(stdout)).toBe("The save button is here [POINT:120,40:Save:screen1]");
  });

  it("keeps a multi-line answer intact", () => {
    const stdout = "2026-09-21T04:53:26Z INFO x\nline one\nline two";
    expect(extractFinalMessage(stdout)).toBe("line one\nline two");
  });
});

describe("classifying a finished run", () => {
  it("reports success as no failure at all", () => {
    expect(classifyCodexFailure({ exitCode: 0, stderr: "", stdout: "an answer" })).toBeNull();
  });

  it("catches a zero exit that said nothing — codex went and did the task instead", () => {
    const failure = classifyCodexFailure({ exitCode: 0, stderr: "", stdout: "" });
    expect(failure?.kind).toBe("emptyReply");
    expect(codexFailureMessage(failure!)).toContain("instead of replying");
  });

  it("recognises a missing binary", () => {
    const failure = classifyCodexFailure({ exitCode: 1, stderr: "", stdout: "", spawnFailed: true });
    expect(failure?.kind).toBe("notInstalled");
    expect(codexFailureMessage(failure!)).toContain("npm install -g @openai/codex");
  });

  it("recognises a signed-out CLI and says how to fix it", () => {
    const failure = classifyCodexFailure({
      exitCode: 1,
      stderr: "error: not logged in. please run `codex login`",
      stdout: "",
    });
    expect(failure?.kind).toBe("notSignedIn");
    expect(codexFailureMessage(failure!)).toContain("codex login");
  });

  it("distinguishes an argv mismatch from a credential problem", () => {
    // clap's error when Iris and the reader's codex are out of step. Reporting
    // this as "sign in" would send them somewhere useless.
    const failure = classifyCodexFailure({
      exitCode: 2,
      stderr: "error: unexpected argument '--image' found\n\nUsage: codex exec [OPTIONS]",
      stdout: "",
    });
    expect(failure?.kind).toBe("argumentMismatch");
    expect(codexFailureMessage(failure!)).toContain("out of step");
  });

  it("quotes codex when it does not recognise the failure", () => {
    const failure = classifyCodexFailure({
      exitCode: 70,
      stderr: "stream disconnected before completion",
      stdout: "",
    });
    expect(failure?.kind).toBe("failed");
    expect(codexFailureMessage(failure!)).toContain("stream disconnected before completion");
  });

  it("never shows a bare timestamp line as the reason", () => {
    const failure = classifyCodexFailure({
      exitCode: 1,
      stderr: "2026-09-21T04:53:26.352513Z  INFO codex_exec: starting\nreal reason here",
      stdout: "",
    });
    if (failure?.kind === "failed") expect(failure.detail).toBe("real reason here");
  });
});
