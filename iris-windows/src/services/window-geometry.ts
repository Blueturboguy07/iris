/**
 * window-geometry.ts
 *
 * The sizes of Iris's two framed, form-like windows — Settings and the
 * first-run "Welcome to Iris" window. Both used to be fixed at a size smaller
 * than their content (`resizable: false`), so Windows drew its default grey
 * scrollbars inside a window the reader could not make bigger. A paying
 * subscriber reported exactly that on 2026-09-24: "I can't resize the menu
 * settings and it show up the 2 big default scroller vertical and horizontal".
 *
 * Now both can be resized, down to a minimum at which the renderer's own CSS
 * still needs no horizontal scrolling (its rows wrap instead — see
 * `renderer/settings/index.html`), and the vertical scrollbar is a thin one
 * styled to match the app. The numbers live here, not inline in
 * `main/index.ts`, so the suite can hold them to those rules.
 *
 * Sizes are Electron window sizes in device-independent pixels, and on
 * Windows they include the frame (about 16 px wide, 39 px tall).
 */

export interface ResizableWindowGeometry {
  width: number;
  height: number;
  minWidth: number;
  minHeight: number;
  resizable: true;
}

/** The narrowest either window may become. The renderers' layout is checked
 *  at this width on real Windows by the headed GUI e2e suite. */
export const NARROWEST_FORM_WINDOW_WIDTH = 400;

export const SETTINGS_WINDOW_GEOMETRY: ResizableWindowGeometry = {
  width: 520,
  height: 640,
  minWidth: NARROWEST_FORM_WINDOW_WIDTH,
  minHeight: 420,
  resizable: true,
};

export const FIRST_RUN_WINDOW_GEOMETRY: ResizableWindowGeometry = {
  width: 560,
  height: 680,
  minWidth: NARROWEST_FORM_WINDOW_WIDTH,
  minHeight: 440,
  resizable: true,
};
