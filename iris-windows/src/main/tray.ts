import { Tray, Menu, nativeImage } from "electron";
import path from "node:path";

interface TrayCallbacks {
  onChat: () => void;
  onGuide: () => void;
  onSettings: () => void;
  onQuit: () => void;
}

let tray: Tray | null = null;

export function createTray(callbacks: TrayCallbacks): Tray {
  const icon = nativeImage.createFromPath(
    path.join(__dirname, "..", "..", "assets", "icon.ico")
  );
  tray = new Tray(icon);

  const contextMenu = Menu.buildFromTemplate([
    { label: "Iris", enabled: false },
    { type: "separator" },
    { label: "Ask Iris", click: callbacks.onChat },
    { label: "Install guide", click: callbacks.onGuide },
    { label: "Settings", click: callbacks.onSettings },
    { type: "separator" },
    { label: "Quit", click: callbacks.onQuit },
  ]);

  tray.setToolTip("Iris — publik's desktop companion");
  tray.setContextMenu(contextMenu);

  // Left-click opens the chat window directly.
  tray.on("click", () => callbacks.onChat());

  return tray;
}
