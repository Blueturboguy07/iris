import type { ForgeConfig } from "@electron-forge/shared-types";
import { MakerZIP } from "@electron-forge/maker-zip";

const config: ForgeConfig = {
  packagerConfig: {
    asar: true,
    icon: "assets/icon",
    name: "Clicky",
    executableName: "clicky",
  },
  makers: [
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
