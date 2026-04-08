import { Tray, Menu, nativeImage } from "electron";
import path from "path";

interface TrayCallbacks {
  onSettings: () => void;
  onQuit: () => void;
}

let tray: Tray | null = null;

export function createTray(callbacks: TrayCallbacks): Tray {
  const iconPath = path.join(__dirname, "..", "..", "assets", "tray-icon.png");

  // Create a small default icon if asset doesn't exist yet
  const icon = nativeImage.createFromPath(iconPath);
  tray = new Tray(icon.isEmpty() ? nativeImage.createEmpty() : icon);

  const contextMenu = Menu.buildFromTemplate([
    {
      label: "Clicky",
      enabled: false,
    },
    { type: "separator" },
    {
      label: "Settings",
      click: callbacks.onSettings,
    },
    { type: "separator" },
    {
      label: "Quit",
      click: callbacks.onQuit,
    },
  ]);

  tray.setToolTip("Clicky — AI Screen Companion");
  tray.setContextMenu(contextMenu);

  return tray;
}
