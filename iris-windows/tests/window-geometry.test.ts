import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import {
  FIRST_RUN_WINDOW_GEOMETRY,
  NARROWEST_FORM_WINDOW_WIDTH,
  SETTINGS_WINDOW_GEOMETRY,
} from "../src/services/window-geometry";

/**
 * "I can't resize the menu settings and it show up the 2 big default scroller
 * vertical and horizontal" — a paying subscriber, 2026-09-24. Two halves:
 * the windows must be resizable (geometry, below), and the pages inside them
 * must never need a horizontal scrollbar and must not fall back to Windows'
 * default one for the vertical (CSS, further below).
 *
 * jsdom does no layout, so the CSS half pins the rules that produce the
 * behaviour rather than measuring it; the headed GUI e2e suite measures the
 * real settings window at its narrowest width on windows-latest.
 */

describe("the Settings and first-run window sizes", () => {
  it.each([
    ["settings", SETTINGS_WINDOW_GEOMETRY],
    ["first-run", FIRST_RUN_WINDOW_GEOMETRY],
  ] as const)("the %s window can be resized, and opens at least as big as its minimum", (_name, geometry) => {
    expect(geometry.resizable).toBe(true);
    expect(geometry.width).toBeGreaterThanOrEqual(geometry.minWidth);
    expect(geometry.height).toBeGreaterThanOrEqual(geometry.minHeight);
  });

  it.each([
    ["settings", SETTINGS_WINDOW_GEOMETRY],
    ["first-run", FIRST_RUN_WINDOW_GEOMETRY],
  ] as const)("the %s window cannot shrink past the width its layout is checked at", (_name, geometry) => {
    expect(geometry.minWidth).toBe(NARROWEST_FORM_WINDOW_WIDTH);
  });

  it("opens both windows small enough for a 1366x768 laptop", () => {
    for (const geometry of [SETTINGS_WINDOW_GEOMETRY, FIRST_RUN_WINDOW_GEOMETRY]) {
      expect(geometry.width).toBeLessThanOrEqual(1366);
      // 768 minus the taskbar leaves roughly 720.
      expect(geometry.height).toBeLessThanOrEqual(720);
    }
  });
});

const RENDERER_DIR = join(__dirname, "..", "src", "renderer");

function stylesOf(page: string): string {
  const html = readFileSync(join(RENDERER_DIR, page, "index.html"), "utf-8");
  return [...html.matchAll(/<style>([\s\S]*?)<\/style>/g)].map((match) => match[1]).join("\n");
}

/** The declarations of the first rule whose selector list is exactly `selector`. */
function ruleBody(styles: string, selector: string): string {
  const escaped = selector.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const match = styles.match(new RegExp(`(^|[}\\s])${escaped}\\s*\\{([^}]*)\\}`, "m"));
  return match?.[2] ?? "";
}

describe("the scrollbars inside Iris's own windows", () => {
  it.each(["settings", "first-run", "chat"])("the %s window styles its scrollbar instead of using Windows' default", (page) => {
    const styles = stylesOf(page);
    expect(ruleBody(styles, "::-webkit-scrollbar")).toMatch(/width:\s*\d+px/);
    expect(ruleBody(styles, "::-webkit-scrollbar-thumb")).toMatch(/background/);
  });

  it.each(["settings", "first-run", "chat"])(
    "the %s window does not set scrollbar-width or scrollbar-color, which would switch that styling off",
    (page) => {
      // Chromium 121+ ignores every ::-webkit-scrollbar rule on an element
      // whose scrollbar-width or scrollbar-color is set, and falls back to the
      // native scrollbar — the very one this replaced.
      expect(stylesOf(page)).not.toMatch(/scrollbar-(width|color)\s*:/);
    }
  );

  it.each(["settings", "first-run"])("the %s window never scrolls sideways", (page) => {
    const body = ruleBody(stylesOf(page), "body");
    expect(body).toMatch(/overflow-x:\s*hidden/);
    expect(body).toMatch(/overflow-y:\s*auto/);
    // Long unbroken text — an email address, a key placeholder — may break
    // rather than push the page wider than the window.
    expect(body).toMatch(/overflow-wrap:\s*anywhere/);
  });

  it.each(["settings", "first-run"])("the %s window's rows of buttons wrap onto a new line instead of overflowing", (page) => {
    expect(ruleBody(stylesOf(page), ".row")).toMatch(/flex-wrap:\s*wrap/);
  });
});
