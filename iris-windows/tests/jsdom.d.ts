//
// A local declaration for the one jsdom entry point the suite uses.
//
// NOT `@types/jsdom`: that package pulls `lib.dom` into the whole project, and
// this project is Electron main/services code compiled with `lib: ["ES2022"]`
// on purpose — with the DOM ambient, a stray `document` or `window` in
// `src/main/` would typecheck instead of failing. The renderer is plain
// JavaScript and is not typechecked at all, so nothing else needs those types.
// The surface below is exactly what tests/guide-renderer.test.ts touches.
//
declare module "jsdom" {
  export interface JSDOMWindow {
    readonly document: {
      querySelector(selectors: string): {
        textContent: string | null;
        click(): void;
      } | null;
    };
    readonly navigator: object;
    readonly location: object;
    Element: { prototype: { scrollIntoView: () => void } };
    matchMedia: unknown;
    fetch: unknown;
    eval(script: string): unknown;
    close(): void;
  }

  export class JSDOM {
    constructor(
      html: string,
      options?: {
        url?: string;
        runScripts?: "dangerously" | "outside-only";
        pretendToBeVisual?: boolean;
      },
    );
    readonly window: JSDOMWindow;
  }
}
