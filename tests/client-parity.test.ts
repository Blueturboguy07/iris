//
//  client-parity.test.ts
//
//  The check that did not exist, and whose absence is the reason this repo has
//  three clients that quietly disagree.
//
//  Across the entire history of the repository these files came from, no commit
//  ever touched both `iris-macos/` and `iris-windows/` — 123 commits to one, 54
//  to the other, intersection zero. Nothing failed when they diverged, so they
//  diverged, and the divergence reached users:
//
//    - The Tauri client's host allowlist grew seven entries on 2026-08-10 for
//      the Hickeyfield, Nutcracker and Dripwriter Origin guides. Nothing
//      propagated them. publik's guide test validated published links against
//      that list, so four live guide steps passed CI and opened nothing on
//      either shipping client.
//
//  These are deliberately the cheapest possible checks: parse the literals out
//  of each source and compare the sets. They cannot tell you the clients behave
//  the same. They can tell you the day one of them stopped agreeing with the
//  others about a list that has to be identical, which is the failure that has
//  actually happened.
//

import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

function read(relativePath: string): string {
  return readFileSync(new URL(relativePath, import.meta.url), "utf8");
}

/** Quoted lowercase hostnames, deduplicated. */
function hostsIn(source: string): Set<string> {
  return new Set(
    (source.match(/"([a-z0-9-]+(?:\.[a-z0-9-]+)+)"/g) ?? []).map((quoted) =>
      quoted.slice(1, -1)
    )
  );
}

/** The body of a named region, so surrounding code cannot leak into the match. */
function regionBetween(source: string, startsAt: string, endsAt: string): string {
  const start = source.indexOf(startsAt);
  expect(start, `could not find ${startsAt}`).toBeGreaterThan(-1);
  const end = source.indexOf(endsAt, start + startsAt.length);
  expect(end, `could not find ${endsAt} after ${startsAt}`).toBeGreaterThan(-1);
  return source.slice(start, end);
}

describe("host allowlist", () => {
  const swift = hostsIn(
    regionBetween(
      read("../iris-macos/leanring-buddy/ExternalLinkPolicy.swift"),
      "static let allowedExternalHosts",
      "]"
    )
  );
  const typescript = hostsIn(
    regionBetween(
      read("../iris-windows/src/services/external-links.ts"),
      "export const ALLOWED_EXTERNAL_HOSTS",
      "]);"
    )
  );
  const rust = hostsIn(
    regionBetween(
      read("../iris-desktop/src-tauri/src/main.rs"),
      "fn allowed_external_host",
      "#[tauri::command]"
    )
  );

  it("is not empty in any client", () => {
    expect(swift.size).toBeGreaterThan(5);
    expect(typescript.size).toBeGreaterThan(5);
    expect(rust.size).toBeGreaterThan(5);
  });

  it("is the same set in all three clients", () => {
    // A guide link works only where every client agrees. A host in one list and
    // not another is a button that opens nothing on some machines and not
    // others, and it is fixable only by shipping a new client — which is why
    // this is worth failing a build over.
    const missing = (from: Set<string>, present: Set<string>) =>
      [...present].filter((host) => !from.has(host)).sort();

    expect({
      missingFromSwift: missing(swift, typescript),
      missingFromTypeScript: missing(typescript, swift),
      missingFromRust: missing(rust, swift),
    }).toEqual({
      missingFromSwift: [],
      missingFromTypeScript: [],
      missingFromRust: [],
    });
  });
});

describe("autopilot risk gate", () => {
  // Every command the gate refuses outright has to be refused by both shipping
  // clients. One client waving through what the other blocks is the worst kind
  // of divergence here, because the permissive one runs it without asking.
  const swift = read("../iris-macos/leanring-buddy/GuideAutopilotRiskAssessment.swift");
  const typescript = read("../iris-windows/src/services/autopilot/risk.ts");

  const verdicts = [
    ["runsWithoutAsking", "runs_without_asking"],
    ["needsAConfirmTap", "needs_a_confirm_tap"],
    ["refusedOutright", "refused_outright"],
  ] as const;

  it("uses the same three verdicts on both clients", () => {
    for (const [swiftCase, typescriptCase] of verdicts) {
      expect(swift, `macOS gate lost ${swiftCase}`).toContain(swiftCase);
      expect(typescript, `Windows gate lost ${typescriptCase}`).toContain(
        typescriptCase
      );
    }
  });

  it("refuses piping the network into a shell on both clients", () => {
    // The one rule that must never be a per-platform decision: an install step
    // that pipes a download into a shell is refused, not merely confirmed.
    for (const [name, source] of [
      ["macOS", swift],
      ["Windows", typescript],
    ] as const) {
      expect(source, `${name} gate no longer mentions curl`).toMatch(/curl/i);
      expect(source, `${name} gate no longer mentions a shell pipe`).toMatch(
        /\|\s*(?:sh|bash|zsh|iex|Invoke-Expression)/i
      );
    }
  });
});
