/**
 * coordinates.ts
 *
 * The three coordinate spaces the pointing pipeline moves between, and every
 * conversion between them. Upstream's own architecture notes call this the
 * easiest thing in the system to break, so it lives here as pure arithmetic with
 * no Electron import — which is what makes it testable without a screen.
 *
 * ## The three spaces
 *
 * 1. NATIVE space  — real device pixels of one display. On a 2x display a
 *                    1920x1080 desktop is 3840x2160 native pixels. This is what
 *                    `desktopCapturer` hands back and what a refinement crop is
 *                    taken from, because cropping at native density is the whole
 *                    reason the second pass is sharper than the first.
 *
 * 2. IMAGE space   — the downsampled JPEG actually sent to the model, long edge
 *                    clamped to `MAX_MODEL_IMAGE_EDGE`. The model's `[POINT:x,y]`
 *                    tags are in THIS space, because it is the only image it saw.
 *
 * 3. DISPLAY space — Electron's `display.bounds`, i.e. device-independent
 *                    pixels. The overlay window is sized in this space, so a
 *                    point must land here before it can be drawn.
 *
 * The pipeline is: capture NATIVE -> downsample to IMAGE -> model points in
 * IMAGE -> crop back to NATIVE around that point -> model refines in CROP
 * pixels -> map back to IMAGE -> scale to DISPLAY -> draw.
 *
 * The bug this module exists to prevent is applying one space's scale factor to
 * another space's number, which on a 2x display is silently off by exactly 2x —
 * close enough to look like a mediocre model and not like a unit error.
 */

export interface Size {
  readonly width: number;
  readonly height: number;
}

export interface Point {
  readonly x: number;
  readonly y: number;
}

export interface Rect {
  readonly x: number;
  readonly y: number;
  readonly width: number;
  readonly height: number;
}

/**
 * 1568 is Anthropic's recommended max edge for vision input. Going higher on the
 * pass-1 image triggers API-side downscaling, which shifts every coordinate the
 * model returns without telling us the factor it used.
 */
export const MAX_MODEL_IMAGE_EDGE = 1568;

/**
 * NATIVE -> IMAGE. The size of the JPEG to send the model for a capture of
 * `nativeSize`, preserving aspect ratio and never upscaling.
 */
export function imageDimensionsForCapture(
  nativeSize: Size,
  maximumEdge: number = MAX_MODEL_IMAGE_EDGE
): Size {
  const longestEdge = Math.max(nativeSize.width, nativeSize.height);
  if (longestEdge <= maximumEdge || longestEdge === 0) {
    return { width: nativeSize.width, height: nativeSize.height };
  }
  return {
    width: Math.round((nativeSize.width * maximumEdge) / longestEdge),
    height: Math.round((nativeSize.height * maximumEdge) / longestEdge),
  };
}

/**
 * IMAGE -> DISPLAY. Turns a model-supplied point into the overlay window's own
 * coordinate space.
 *
 * `displayBounds` is in device-independent pixels and `imageDimensions` is in
 * downsampled image pixels, so the ratio between them already folds in BOTH the
 * display's scale factor and the downsample — which is exactly why the scale
 * factor must not be applied again anywhere else.
 */
export function imagePointToDisplayPoint(
  imagePoint: Point,
  imageDimensions: Size,
  displayBounds: Size
): Point {
  if (imageDimensions.width === 0 || imageDimensions.height === 0) {
    return { x: 0, y: 0 };
  }
  const horizontalScale = displayBounds.width / imageDimensions.width;
  const verticalScale = displayBounds.height / imageDimensions.height;
  return {
    x: Math.round(imagePoint.x * horizontalScale),
    y: Math.round(imagePoint.y * verticalScale),
  };
}

/** Keeps a display-space point inside the overlay it is about to be drawn on. */
export function clampPointToBounds(point: Point, bounds: Size): Point {
  return {
    x: Math.min(Math.max(point.x, 0), Math.max(bounds.width - 1, 0)),
    y: Math.min(Math.max(point.y, 0), Math.max(bounds.height - 1, 0)),
  };
}

/**
 * The plan for one second-pass refinement crop.
 *
 * `nativeRect` is what to actually cut out of the native-resolution capture.
 * `originInImageSpace` is that rect's top-left expressed back in IMAGE space,
 * and `nativePixelsPerImagePixel` is the factor between the two — together they
 * are everything needed to map the model's answer back.
 */
export interface RefinementCropPlan {
  readonly nativeRect: Rect;
  readonly originInImageSpace: Point;
  readonly nativePixelsPerImagePixel: number;
}

/**
 * IMAGE -> NATIVE. Plans a square crop centred on a point the model gave us in
 * IMAGE space, cut from the NATIVE capture so the model sees the patch at full
 * display density.
 *
 * `cropSizeInImageSpace` is deliberately expressed in image pixels: the caller
 * is reasoning about "roughly 300 px of what the model already looked at", not
 * about device pixels it never saw.
 */
export function planRefinementCrop(options: {
  imageDimensions: Size;
  nativeSize: Size;
  centerInImageSpace: Point;
  cropSizeInImageSpace: number;
}): RefinementCropPlan {
  const { imageDimensions, nativeSize, centerInImageSpace, cropSizeInImageSpace } = options;

  const nativePixelsPerImagePixel =
    imageDimensions.width === 0 ? 1 : nativeSize.width / imageDimensions.width;

  const nativeCenterX = centerInImageSpace.x * nativePixelsPerImagePixel;
  const nativeCenterY = centerInImageSpace.y * nativePixelsPerImagePixel;
  const nativeCropSize = cropSizeInImageSpace * nativePixelsPerImagePixel;
  const halfCropSize = nativeCropSize / 2;

  // Clamp so the crop stays entirely on screen. A crop larger than the display
  // collapses to the display itself rather than going negative.
  const maximumX = Math.max(0, nativeSize.width - nativeCropSize);
  const maximumY = Math.max(0, nativeSize.height - nativeCropSize);
  const nativeX = Math.round(Math.min(Math.max(0, nativeCenterX - halfCropSize), maximumX));
  const nativeY = Math.round(Math.min(Math.max(0, nativeCenterY - halfCropSize), maximumY));
  const nativeWidth = Math.round(Math.min(nativeCropSize, nativeSize.width - nativeX));
  const nativeHeight = Math.round(Math.min(nativeCropSize, nativeSize.height - nativeY));

  return {
    nativeRect: { x: nativeX, y: nativeY, width: nativeWidth, height: nativeHeight },
    originInImageSpace: {
      x: nativeX / nativePixelsPerImagePixel,
      y: nativeY / nativePixelsPerImagePixel,
    },
    nativePixelsPerImagePixel,
  };
}

/**
 * CROP -> IMAGE. Maps the second pass's answer, which is in the crop's own pixel
 * space, back to the IMAGE space the first pass used, so the single
 * `imagePointToDisplayPoint` conversion still serves both passes.
 */
export function refinedCropPointToImagePoint(
  refinedPointInCropSpace: Point,
  cropPlan: RefinementCropPlan
): Point {
  const scale = cropPlan.nativePixelsPerImagePixel || 1;
  return {
    x: cropPlan.originInImageSpace.x + refinedPointInCropSpace.x / scale,
    y: cropPlan.originInImageSpace.y + refinedPointInCropSpace.y / scale,
  };
}

/**
 * The whole pipeline in one call, for the common case: the model pointed in
 * IMAGE space, an optional refinement came back in CROP space, and the overlay
 * needs a DISPLAY-space point that is definitely on screen.
 */
export function resolvePointForOverlay(options: {
  imagePoint: Point;
  imageDimensions: Size;
  displayBounds: Size;
  refinement?: { pointInCropSpace: Point; cropPlan: RefinementCropPlan };
}): Point {
  const pointInImageSpace = options.refinement
    ? refinedCropPointToImagePoint(options.refinement.pointInCropSpace, options.refinement.cropPlan)
    : options.imagePoint;

  return clampPointToBounds(
    imagePointToDisplayPoint(pointInImageSpace, options.imageDimensions, options.displayBounds),
    options.displayBounds
  );
}

/** A `[POINT:x,y:label:screenN]` tag, in whichever space it has reached. */
export interface PointTag {
  readonly x: number;
  readonly y: number;
  readonly label: string;
  readonly screen: number;
}

/**
 * Pulls `[POINT:x,y:label:screenN]` tags out of the model's text. Kept next to
 * the conversions because the tags are the pipeline's entry point and their
 * coordinates are always IMAGE space.
 */
export function parsePointTags(text: string): PointTag[] {
  const pattern = /\[POINT:(\d+),(\d+):([^:\]]+):screen(\d+)\]/g;
  const tags: PointTag[] = [];
  let match: RegExpExecArray | null;
  while ((match = pattern.exec(text)) !== null) {
    tags.push({
      x: Number.parseInt(match[1], 10),
      y: Number.parseInt(match[2], 10),
      label: match[3],
      screen: Number.parseInt(match[4], 10),
    });
  }
  return tags;
}

/** The text the user actually reads: the same message with the tags taken out. */
export function stripPointTags(text: string): string {
  return text.replace(/\[POINT:[^\]]+\]/g, "").replace(/[ \t]{2,}/g, " ").trim();
}
