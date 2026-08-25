import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    // Only the cross-client checks at this root. Each client ships its own
    // suite and its own dependencies: iris-macos runs under xcodebuild,
    // iris-windows has its own vitest config. Running those from here would
    // fail on any clone where their dependencies are absent, and would report
    // one number for three unrelated things.
    include: ["tests/**/*.test.ts"],
    exclude: ["**/node_modules/**", "iris-windows/**", "iris-macos/**", "iris-desktop/**"],
  },
});
