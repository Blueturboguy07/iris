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
  }
);
