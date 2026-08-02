import type { ForgeConfig } from "@electron-forge/shared-types";
import { MakerSquirrel } from "@electron-forge/maker-squirrel";
import { MakerZIP } from "@electron-forge/maker-zip";

/**
 * Squirrel is inherited from upstream and produces the `Iris-Setup.exe` the CI
 * workflow uploads. MSIX (and therefore the Microsoft Store route, which is the
 * only way to avoid SmartScreen) is a later concern and deliberately not here.
 */
const config: ForgeConfig = {
  packagerConfig: {
    asar: true,
    icon: "assets/icon",
    name: "Iris",
    executableName: "iris",
    // `src/renderer/**` is loaded from disk at runtime by `loadFile`, and
    // `dist/**` is the compiled main process. Everything else — the suite, the
    // TypeScript sources, the docs — has no business inside the installer.
    ignore: [
      /^\/tests($|\/)/,
      /^\/src\/(main|preload|services)($|\/)/,
      /^\/docs($|\/)/,
      /^\/scripts($|\/)/,
      /^\/\.github($|\/)/,
      /^\/tsconfig.*\.json$/,
      /^\/vitest\.config\.ts$/,
      /^\/eslint\.config\.mjs$/,
      /^\/forge\.config\.ts$/,
    ],
  },
  makers: [
    new MakerSquirrel({
      name: "Iris",
      setupExe: "Iris-Setup.exe",
      setupIcon: "assets/icon.ico",
      noMsi: true,
    }),
    new MakerZIP({}, ["win32"]),
  ],
  plugins: [
    {
      name: "@electron-forge/plugin-auto-unpack-natives",
      config: {},
    },
  ],
};

export default config;
