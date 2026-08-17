// @ts-check
import eslint from "@eslint/js";
import tseslint from "typescript-eslint";
import globals from "globals";

/**
 * Upstream shipped a `lint` script but no config, so `npm run lint` could never
 * have passed on ESLint 9 (which requires a flat config). This is that config.
 *
 * The renderer directory is checked as plain browser JavaScript: `app.js` there
 * is transplanted verbatim from `iris-desktop/ui`, so it is linted for real
 * errors but not restyled — keeping it diffable against its original is worth
 * more than uniform formatting.
 */
export default tseslint.config(
  {
    ignores: ["dist/**", "out/**", "node_modules/**", "assets/**"],
  },
  eslint.configs.recommended,
  ...tseslint.configs.recommended,
  {
    files: ["src/**/*.ts", "tests/**/*.ts", "*.config.ts"],
    languageOptions: {
      globals: { ...globals.node },
    },
    rules: {
      "@typescript-eslint/no-unused-vars": [
        "error",
        { argsIgnorePattern: "^_", varsIgnorePattern: "^_" },
      ],
      "@typescript-eslint/no-explicit-any": "error",
      eqeqeq: ["error", "smart"],
      "no-console": "off",
    },
  },
  {
    files: ["src/renderer/**/*.js"],
    ...tseslint.configs.disableTypeChecked,
    languageOptions: {
      globals: { ...globals.browser },
      sourceType: "script",
    },
    rules: {
      "no-unused-vars": "off",
      "no-empty": ["error", { allowEmptyCatch: true }],
    },
  },
  {
    // The headed GUI e2e harness: plain Node ESM (`.mjs`), CI-only, not part of
    // the app or the vitest suite. Linted as Node scripts — `require` via
    // `createRequire` is deliberate (it loads the real compiled services), and
    // an empty catch is a legitimate best-effort cleanup here.
    files: ["tests/gui-e2e/**/*.mjs"],
    ...tseslint.configs.disableTypeChecked,
    languageOptions: {
      globals: { ...globals.node, fetch: "readonly", WebSocket: "readonly" },
      sourceType: "module",
      ecmaVersion: 2023,
    },
    rules: {
      "no-console": "off",
      "no-empty": ["error", { allowEmptyCatch: true }],
      "@typescript-eslint/no-require-imports": "off",
    },
  }
);
