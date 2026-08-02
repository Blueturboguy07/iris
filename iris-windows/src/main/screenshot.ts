import { desktopCapturer, nativeImage, screen } from "electron";
import {
  MAX_MODEL_IMAGE_EDGE,
  RefinementCropPlan,
  Size,
  imageDimensionsForCapture,
  planRefinementCrop,
} from "../services/coordinates";

/**
 * screenshot.ts
 *
 * Electron's side of the capture: talk to `desktopCapturer`, hand back one
 * result per display. Every coordinate decision is delegated to
 * `services/coordinates.ts`, which is pure and tested — this file only carries
 * pixels around.
 *
 * PRIVACY (protocol section 5): a frame exists only as a local value here and in
 * the one call that sends it. Nothing in this file writes an image to disk.
 */

export interface ScreenshotResult {
  /** Base64-encoded JPEG, downsampled for pass-1 model input. */
  data: string;
  /** Index into `screen.getAllDisplays()`, and therefore into the overlay array. */
  displayIndex: number;
  /** Display bounds in device-independent pixels, including position offset. */
  bounds: { x: number; y: number; width: number; height: number };
  /** Pixel dimensions of the downsampled JPEG actually sent to the model. */
  imageDimensions: { width: number; height: number };
  /** Native pixel dimensions of the capture the JPEG was made from. */
  nativeDimensions: { width: number; height: number };
  /**
   * Full-resolution source kept in memory for second-pass refinement crops.
   * NOT serialisable — never send this over IPC.
   */
  _source?: Electron.NativeImage;
}

const JPEG_QUALITY = 85;
const REFINEMENT_CROP_JPEG_QUALITY = 95;

export class ScreenCapture {
  /**
   * Capture all screens. Returns a downsampled JPEG for pass-1 input and retains
   * the native-resolution image on each result for refinement.
   */
  async captureAllScreens(): Promise<ScreenshotResult[]> {
    const displays = screen.getAllDisplays();

    // Ask for the largest native-pixel edge across all displays. Electron clamps
    // to what the OS provides, so an oversized request is safe.
    let maxNativeEdge = MAX_MODEL_IMAGE_EDGE;
    for (const display of displays) {
      const scaleFactor = display.scaleFactor || 1;
      maxNativeEdge = Math.max(
        maxNativeEdge,
        Math.ceil(display.bounds.width * scaleFactor),
        Math.ceil(display.bounds.height * scaleFactor)
      );
    }

    const sources = await desktopCapturer.getSources({
      types: ["screen"],
      thumbnailSize: { width: maxNativeEdge, height: maxNativeEdge },
    });

    const results: ScreenshotResult[] = [];

    // Correlate sources with displays by id. The order of `sources` is NOT
    // guaranteed to match `displays` — on Windows it usually does, but Electron
    // explicitly warns against relying on it.
    const anySourceHasDisplayId = sources.some((source) => source.display_id);

    for (let index = 0; index < displays.length; index++) {
      const display = displays[index];
      const matchedById = sources.find(
        (source) => source.display_id && source.display_id === String(display.id)
      );
      if (!matchedById && anySourceHasDisplayId) {
        console.warn(
          `[iris] no desktopCapturer source matched display.id=${display.id} (index ${index}); ` +
            "falling back to positional match. Screenshot may be routed to the wrong monitor."
        );
      }
      const source = matchedById || sources[index] || sources[0];
      if (!source) continue;

      const fullResolutionImage = source.thumbnail;
      if (fullResolutionImage.isEmpty()) continue;

      const nativeSize: Size = fullResolutionImage.getSize();
      const targetImageSize = imageDimensionsForCapture(nativeSize);
      const downsampled =
        targetImageSize.width === nativeSize.width && targetImageSize.height === nativeSize.height
          ? fullResolutionImage
          : fullResolutionImage.resize({
              width: targetImageSize.width,
              height: targetImageSize.height,
            });
      const actualImageSize = downsampled.getSize();

      results.push({
        data: downsampled.toJPEG(JPEG_QUALITY).toString("base64"),
        displayIndex: index,
        bounds: display.bounds,
        imageDimensions: { width: actualImageSize.width, height: actualImageSize.height },
        nativeDimensions: { width: nativeSize.width, height: nativeSize.height },
        _source: fullResolutionImage,
      });
    }

    // Ordering stays aligned with `screen.getAllDisplays()`, which is also the
    // order the overlay windows are created in, so a POINT tag's `screen` field
    // indexes into either array.
    return results;
  }

  getCursorPosition(): { x: number; y: number } {
    return screen.getCursorScreenPoint();
  }
}

export interface RefinementCrop {
  /** Base64 JPEG of the crop. */
  data: string;
  /** Pixel size of that JPEG — what the model will actually see. */
  cropSize: { width: number; height: number };
  /** Everything needed to map the model's answer back to IMAGE space. */
  plan: RefinementCropPlan;
}

/**
 * Cut a square patch around a first-pass point for second-pass refinement.
 *
 * The centre is given in IMAGE space (the space the model pointed in). The cut is
 * made from the native-resolution image so the model sees the patch at real
 * display density — that is the whole reason the second pass helps.
 */
export function cropScreenshotRegion(
  shot: ScreenshotResult,
  centerInImageSpace: { x: number; y: number },
  cropSizeInImageSpace: number
): RefinementCrop {
  const sourceImage =
    shot._source ?? nativeImage.createFromBuffer(Buffer.from(shot.data, "base64"));
  const nativeSize = shot._source
    ? shot.nativeDimensions
    : { width: shot.imageDimensions.width, height: shot.imageDimensions.height };

  const plan = planRefinementCrop({
    imageDimensions: shot.imageDimensions,
    nativeSize,
    centerInImageSpace,
    cropSizeInImageSpace,
  });

  const cropped = sourceImage.crop({
    x: plan.nativeRect.x,
    y: plan.nativeRect.y,
    width: Math.max(1, plan.nativeRect.width),
    height: Math.max(1, plan.nativeRect.height),
  });
  const croppedSize = cropped.getSize();

  return {
    data: cropped.toJPEG(REFINEMENT_CROP_JPEG_QUALITY).toString("base64"),
    cropSize: { width: croppedSize.width, height: croppedSize.height },
    plan,
  };
}
