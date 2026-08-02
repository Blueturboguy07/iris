import { defineConfig } from "vitest/config";

/**
 * The suite must run without a network, a display, or Windows — it is the only
 * way this app gets tested on a Mac, and it is what CI runs first on Windows.
 * Everything under test is therefore pure, or takes its I/O as an injected
 * function.
 */
export default defineConfig({
  // iris-windows sits inside the publik repo, whose root carries a PostCSS
  // config for the Next.js site. Vite would otherwise walk up and try to load
  // it, which fails — and has nothing to do with this app, which ships no CSS
  // pipeline at all. An inline (empty) config stops the search.
  css: { postcss: {} },
  test: {
    environment: "node",
    include: ["tests/**/*.test.ts"],
    // Nothing here should ever be slow; a test that hangs is a test that
    // accidentally reached the network.
    testTimeout: 5_000,
  },
});
