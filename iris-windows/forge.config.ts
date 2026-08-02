import type { ForgeConfig } from "@electron-forge/shared-types";
import { MakerSquirrel } from "@electron-forge/maker-squirrel";
import { MakerZIP } from "@electron-forge/maker-zip";

const config: ForgeConfig = {
  packagerConfig: {
    asar: true,
    icon: "assets/icon",
    name: "Clicky",
    executableName: "clicky",
  },
  makers: [
    new MakerSquirrel({
      name: "Clicky",
      setupExe: "Clicky-Setup.exe",
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
