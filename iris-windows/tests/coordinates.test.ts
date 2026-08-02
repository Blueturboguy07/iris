import { describe, expect, it } from "vitest";
import {
  MAX_MODEL_IMAGE_EDGE,
  clampPointToBounds,
  imageDimensionsForCapture,
  imagePointToDisplayPoint,
  parsePointTags,
  planRefinementCrop,
  refinedCropPointToImagePoint,
  resolvePointForOverlay,
  stripPointTags,
} from "../src/services/coordinates";

/**
 * Upstream's own architecture notes call the coordinate pipeline "the easiest
 * part of the codebase to break", so this is the table-driven suite for it.
 *
 * The failure mode being guarded against is subtle: applying one space's scale
 * factor to another space's number. On a 2x display that is silently off by
 * exactly 2x, which reads as a mediocre model rather than as a unit error —
 * hence the Retina-style cases below.
 */

describe("NATIVE -> IMAGE: downsampling for the model", () => {
  it.each([
    // [description, native size, expected image size]
    ["a 1x 1080p display needs no downsampling", { width: 1920, height: 1080 }, { width: 1568, height: 882 }],
    ["a 2x 1080p display (Retina) downsamples from 3840x2160", { width: 3840, height: 2160 }, { width: 1568, height: 882 }],
    ["a small window is never upscaled", { width: 800, height: 600 }, { width: 800, height: 600 }],
    ["a display exactly at the cap is untouched", { width: 1568, height: 1000 }, { width: 1568, height: 1000 }],
    ["a portrait display clamps its long edge, which is the height", { width: 1080, height: 1920 }, { width: 882, height: 1568 }],
    ["an ultrawide clamps width", { width: 5120, height: 1440 }, { width: 1568, height: 441 }],
  ])("%s", (_description, nativeSize, expected) => {
    expect(imageDimensionsForCapture(nativeSize)).toEqual(expected);
  });

  it("never returns an edge longer than the model's documented maximum", () => {
    for (const nativeSize of [
      { width: 7680, height: 4320 },
      { width: 3840, height: 2160 },
      { width: 1920, height: 1200 },
      { width: 2560, height: 1600 },
    ]) {
      const imageSize = imageDimensionsForCapture(nativeSize);
      expect(Math.max(imageSize.width, imageSize.height)).toBeLessThanOrEqual(MAX_MODEL_IMAGE_EDGE);
    }
  });

  it("preserves aspect ratio to within a rounding pixel", () => {
    const nativeSize = { width: 3840, height: 2160 };
    const imageSize = imageDimensionsForCapture(nativeSize);
    const nativeAspect = nativeSize.width / nativeSize.height;
    const imageAspect = imageSize.width / imageSize.height;
    expect(Math.abs(nativeAspect - imageAspect)).toBeLessThan(0.01);
  });
});

describe("IMAGE -> DISPLAY: where the overlay actually draws", () => {
  it.each([
    // [description, image point, image dims, display bounds, expected display point]
    [
      "1x display: 1568-wide image maps back onto 1920 CSS px",
      { x: 784, y: 441 },
      { width: 1568, height: 882 },
      { width: 1920, height: 1080 },
      { x: 960, y: 540 },
    ],
    [
      "2x display: the SAME image maps onto the SAME 1920 CSS px, not 3840",
      // This is the case the whole module exists for. The display is 3840
      // native pixels but 1920 device-independent ones, and the overlay window
      // is sized in the latter. Multiplying by scaleFactor here would land the
      // cursor off the right edge of the screen.
      { x: 784, y: 441 },
      { width: 1568, height: 882 },
      { width: 1920, height: 1080 },
      { x: 960, y: 540 },
    ],
    [
      "top-left corner stays at the origin",
      { x: 0, y: 0 },
      { width: 1568, height: 882 },
      { width: 1920, height: 1080 },
      { x: 0, y: 0 },
    ],
    [
      "bottom-right corner of the image maps to the bottom-right of the display",
      { x: 1568, y: 882 },
      { width: 1568, height: 882 },
      { width: 1920, height: 1080 },
      { x: 1920, y: 1080 },
    ],
    [
      "a non-downsampled small display is a 1:1 map",
      { x: 400, y: 300 },
      { width: 800, height: 600 },
      { width: 800, height: 600 },
      { x: 400, y: 300 },
    ],
    [
      "an ultrawide scales x and y by different factors",
      { x: 784, y: 220 },
      { width: 1568, height: 441 },
      { width: 5120, height: 1440 },
      { x: 2560, y: 718 },
    ],
  ])("%s", (_description, imagePoint, imageDimensions, displayBounds, expected) => {
    expect(imagePointToDisplayPoint(imagePoint, imageDimensions, displayBounds)).toEqual(expected);
  });

  it("survives a zero-sized image without producing NaN", () => {
    expect(
      imagePointToDisplayPoint({ x: 10, y: 10 }, { width: 0, height: 0 }, { width: 1920, height: 1080 })
    ).toEqual({ x: 0, y: 0 });
  });

  it("clamps a point to the display it will be drawn on", () => {
    const bounds = { width: 1920, height: 1080 };
    expect(clampPointToBounds({ x: 5000, y: 5000 }, bounds)).toEqual({ x: 1919, y: 1079 });
    expect(clampPointToBounds({ x: -50, y: -50 }, bounds)).toEqual({ x: 0, y: 0 });
    expect(clampPointToBounds({ x: 100, y: 100 }, bounds)).toEqual({ x: 100, y: 100 });
  });
});

describe("IMAGE -> NATIVE -> CROP: planning the refinement cut", () => {
  it("on a 2x display, cuts at native density so the crop is genuinely sharper", () => {
    // 1568-wide image from a 3840-wide native capture => 2.449 native px per
    // image px. A 300-image-px crop is therefore ~735 native px.
    const plan = planRefinementCrop({
      imageDimensions: { width: 1568, height: 882 },
      nativeSize: { width: 3840, height: 2160 },
      centerInImageSpace: { x: 784, y: 441 },
      cropSizeInImageSpace: 300,
    });

    expect(plan.nativePixelsPerImagePixel).toBeCloseTo(3840 / 1568, 5);
    // Centred: 784 * 2.449 = 1920 native, minus half of 735 => ~1553.
    expect(plan.nativeRect.x).toBe(1553);
    expect(plan.nativeRect.width).toBe(735);
    // And the origin reported back in image space is the same corner.
    expect(plan.originInImageSpace.x).toBeCloseTo(1553 / (3840 / 1568), 3);
  });

  it("on a 1x display the factor is 1 and the crop is exactly the requested size", () => {
    const plan = planRefinementCrop({
      imageDimensions: { width: 800, height: 600 },
      nativeSize: { width: 800, height: 600 },
      centerInImageSpace: { x: 400, y: 300 },
      cropSizeInImageSpace: 300,
    });
    expect(plan.nativePixelsPerImagePixel).toBe(1);
    expect(plan.nativeRect).toEqual({ x: 250, y: 150, width: 300, height: 300 });
    expect(plan.originInImageSpace).toEqual({ x: 250, y: 150 });
  });

  it.each([
    ["top-left corner", { x: 0, y: 0 }],
    ["bottom-right corner", { x: 1568, y: 882 }],
    ["off the right edge entirely", { x: 5000, y: 441 }],
    ["negative coordinates", { x: -100, y: -100 }],
  ])("keeps the crop on screen when the point is at %s", (_description, centerInImageSpace) => {
    const nativeSize = { width: 3840, height: 2160 };
    const plan = planRefinementCrop({
      imageDimensions: { width: 1568, height: 882 },
      nativeSize,
      centerInImageSpace,
      cropSizeInImageSpace: 300,
    });
    expect(plan.nativeRect.x).toBeGreaterThanOrEqual(0);
    expect(plan.nativeRect.y).toBeGreaterThanOrEqual(0);
    expect(plan.nativeRect.x + plan.nativeRect.width).toBeLessThanOrEqual(nativeSize.width);
    expect(plan.nativeRect.y + plan.nativeRect.height).toBeLessThanOrEqual(nativeSize.height);
  });

  it("collapses to the display when the requested crop is larger than the screen", () => {
    const plan = planRefinementCrop({
      imageDimensions: { width: 400, height: 300 },
      nativeSize: { width: 400, height: 300 },
      centerInImageSpace: { x: 200, y: 150 },
      cropSizeInImageSpace: 1000,
    });
    expect(plan.nativeRect.x).toBe(0);
    expect(plan.nativeRect.y).toBe(0);
    expect(plan.nativeRect.width).toBeLessThanOrEqual(400);
    expect(plan.nativeRect.height).toBeLessThanOrEqual(300);
  });
});

describe("CROP -> IMAGE: mapping the second pass's answer back", () => {
  it("round-trips the crop centre on a 2x display", () => {
    const imageDimensions = { width: 1568, height: 882 };
    const nativeSize = { width: 3840, height: 2160 };
    const centerInImageSpace = { x: 784, y: 441 };

    const plan = planRefinementCrop({
      imageDimensions,
      nativeSize,
      centerInImageSpace,
      cropSizeInImageSpace: 300,
    });

    // The model says "the element is dead centre of the crop you sent me".
    const centreOfCrop = { x: plan.nativeRect.width / 2, y: plan.nativeRect.height / 2 };
    const backInImageSpace = refinedCropPointToImagePoint(centreOfCrop, plan);

    // Which must land back on (approximately) the point we cropped around.
    expect(backInImageSpace.x).toBeCloseTo(centerInImageSpace.x, 0);
    expect(backInImageSpace.y).toBeCloseTo(centerInImageSpace.y, 0);
  });

  it("a correction inside the crop is scaled DOWN into image space, not up", () => {
    // The classic 2x bug: a 100-native-pixel correction is ~41 image pixels, not
    // 100 and certainly not 200.
    const plan = planRefinementCrop({
      imageDimensions: { width: 1568, height: 882 },
      nativeSize: { width: 3840, height: 2160 },
      centerInImageSpace: { x: 784, y: 441 },
      cropSizeInImageSpace: 300,
    });
    const withoutCorrection = refinedCropPointToImagePoint({ x: 0, y: 0 }, plan);
    const withCorrection = refinedCropPointToImagePoint({ x: 100, y: 0 }, plan);
    expect(withCorrection.x - withoutCorrection.x).toBeCloseTo(100 / (3840 / 1568), 3);
    expect(withCorrection.x - withoutCorrection.x).toBeLessThan(100);
  });
});

describe("the whole pipeline end to end", () => {
  it.each([
    ["1x 1080p", { width: 1920, height: 1080 }, 1],
    ["2x 1080p (Retina)", { width: 1920, height: 1080 }, 2],
    ["1.5x 1440p (the common Windows scale)", { width: 2560, height: 1440 }, 1.5],
    ["2x 4K", { width: 3840, height: 2160 }, 2],
  ])(
    "puts a centre-of-screen point back at the centre on %s",
    (_description, displayBounds, scaleFactor) => {
      const nativeSize = {
        width: displayBounds.width * scaleFactor,
        height: displayBounds.height * scaleFactor,
      };
      const imageDimensions = imageDimensionsForCapture(nativeSize);

      // The model points at the middle of the image it was given.
      const imagePoint = {
        x: Math.round(imageDimensions.width / 2),
        y: Math.round(imageDimensions.height / 2),
      };

      const displayPoint = resolvePointForOverlay({
        imagePoint,
        imageDimensions,
        displayBounds,
      });

      // Which must be the middle of the overlay, in CSS pixels, regardless of
      // how many native pixels the display actually has.
      expect(displayPoint.x).toBeCloseTo(displayBounds.width / 2, -1);
      expect(displayPoint.y).toBeCloseTo(displayBounds.height / 2, -1);
    }
  );

  it("gives the same display point whether or not refinement ran, when refinement agrees", () => {
    const displayBounds = { width: 1920, height: 1080 };
    const nativeSize = { width: 3840, height: 2160 };
    const imageDimensions = imageDimensionsForCapture(nativeSize);
    const imagePoint = { x: 784, y: 441 };

    const withoutRefinement = resolvePointForOverlay({
      imagePoint,
      imageDimensions,
      displayBounds,
    });

    const cropPlan = planRefinementCrop({
      imageDimensions,
      nativeSize,
      centerInImageSpace: imagePoint,
      cropSizeInImageSpace: 300,
    });
    const withRefinement = resolvePointForOverlay({
      imagePoint,
      imageDimensions,
      displayBounds,
      refinement: {
        pointInCropSpace: { x: cropPlan.nativeRect.width / 2, y: cropPlan.nativeRect.height / 2 },
        cropPlan,
      },
    });

    expect(Math.abs(withRefinement.x - withoutRefinement.x)).toBeLessThanOrEqual(1);
    expect(Math.abs(withRefinement.y - withoutRefinement.y)).toBeLessThanOrEqual(1);
  });

  it("never returns a point outside the overlay, whatever the model says", () => {
    const displayBounds = { width: 1920, height: 1080 };
    for (const imagePoint of [
      { x: -1000, y: -1000 },
      { x: 99999, y: 99999 },
      { x: 0, y: 0 },
    ]) {
      const point = resolvePointForOverlay({
        imagePoint,
        imageDimensions: { width: 1568, height: 882 },
        displayBounds,
      });
      expect(point.x).toBeGreaterThanOrEqual(0);
      expect(point.y).toBeGreaterThanOrEqual(0);
      expect(point.x).toBeLessThan(displayBounds.width);
      expect(point.y).toBeLessThan(displayBounds.height);
    }
  });
});

describe("POINT tag parsing", () => {
  it("pulls every tag out of a reply, in order", () => {
    const reply =
      "Click Save [POINT:920,820:Save button:screen0] then pick a playlist " +
      "[POINT:400,200:Playlist menu:screen1].";
    expect(parsePointTags(reply)).toEqual([
      { x: 920, y: 820, label: "Save button", screen: 0 },
      { x: 400, y: 200, label: "Playlist menu", screen: 1 },
    ]);
  });

  it("finds nothing in a reply with no tags", () => {
    expect(parsePointTags("The meaning of life is 42.")).toEqual([]);
  });

  it("ignores a malformed tag rather than half-parsing it", () => {
    expect(parsePointTags("[POINT:abc,def:label:screen0]")).toEqual([]);
    expect(parsePointTags("[POINT:100,200:label]")).toEqual([]);
  });

  it("strips tags from the text the user reads", () => {
    expect(stripPointTags("Click Save [POINT:920,820:Save button:screen0] below the video.")).toBe(
      "Click Save below the video."
    );
  });

  it("leaves text with no tags untouched", () => {
    expect(stripPointTags("Nothing to point at here.")).toBe("Nothing to point at here.");
  });
});
