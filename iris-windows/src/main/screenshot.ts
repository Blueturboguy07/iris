import { desktopCapturer, screen } from "electron";

export interface ScreenshotResult {
  /** Base64-encoded JPEG */
  data: string;
  /** Display index */
  displayIndex: number;
  /** Display bounds */
  bounds: { x: number; y: number; width: number; height: number };
}

const MAX_DIMENSION = 1280;
const JPEG_QUALITY = 80;

export class ScreenCapture {
  /**
   * Capture all screens and return as base64 JPEG images.
   * Images are resized to fit within MAX_DIMENSION while preserving aspect ratio.
   */
  async captureAllScreens(): Promise<ScreenshotResult[]> {
    const displays = screen.getAllDisplays();
    const sources = await desktopCapturer.getSources({
      types: ["screen"],
      thumbnailSize: { width: MAX_DIMENSION, height: MAX_DIMENSION },
    });

    const results: ScreenshotResult[] = [];

    for (let i = 0; i < sources.length; i++) {
      const source = sources[i];
      const display = displays[i] || displays[0];
      const thumbnail = source.thumbnail;

      if (thumbnail.isEmpty()) continue;

      const jpeg = thumbnail.toJPEG(JPEG_QUALITY);
      results.push({
        data: jpeg.toString("base64"),
        displayIndex: i,
        bounds: display.bounds,
      });
    }

    return results;
  }

  /**
   * Capture the primary screen only.
   */
  async capturePrimaryScreen(): Promise<ScreenshotResult | null> {
    const results = await this.captureAllScreens();
    return results[0] || null;
  }

  /**
   * Get cursor position relative to displays.
   */
  getCursorPosition(): { x: number; y: number } {
    return screen.getCursorScreenPoint();
  }
}
