# Mobile goals (from Akrit's standing goals file, goal text as written 2026-09-26 to 09-28)

Product frame: the people using Iris and Publik are non-technical, and Publik runs locally on their own laptop and phone (no Publik compute servers). Mobile (G0, G7, G8) is the key deliverable. A goal is done only when every automatable gap is closed and what remains is the owner's hands-on checks, permission prompts, Apple or payment steps, or owner decisions. A simulator pass, a source-slice pass or a typecheck is never "done" on its own; native runs, device runs and real journeys are separate facts.

The goal wording below is dated; for the current state see `README.md` in this folder (the status columns of the original file are omitted because they are out of date).

## G0 Phone test (Phase 0)

Iris Apps works on the owner's iPhone: Kneecap export (K0), Nut AI data survives a force quit (N0), FreeHarmony camera asked only when needed (F0), one install per double tap, apps open offline, Browse explains an empty catalog (S0).

## G2 Feature version history

A plain-words Features list per app. Remove any feature, even an old one, and keep the rest; Undo works; a crash mid-remove recovers. Seamless UX: every button answers within 200 ms, click-away never loses state, Escape closes confirmations, the panel drags anywhere, every edge case defined. Storage stays in budget. **Also on the phone (owner, 2026-09-28):** one app per app (never an icon per version), a Features page inside it, and space efficient at 3, 100 and 1,000 apps with many versions (store each unique file once, versions as small manifests, user data never lost).

## G7 Mobile shell functionality (key)

Open Iris Apps, see the apps (a "Setting up your apps" line on first launch, never an empty screen), tap one, it runs full screen and offline; Home asks "Go back to Iris home?"; videos of any length import (only free space limits them); exports go to Photos with "Open Photos"; camera asked once and only when needed; updates in one tap; publikhq.com links open the app's page.

## G8 Mobile store redesign ("fix up the mobile shell UI")

Browse feels like a real app store, from deep research on leading app stores and open-source stores: layout and layering redesigned (not colors or glass). Three tabs (Browse, Search, My apps), bounded shelves, a clearly labeled Featured shelf and honest "Sponsored" tags, categories, on-device search, per-app pages, one tap to Get. Same layout at 3, 100 and 1,000 apps; catalog, icon and storage budgets set.

## Owner decisions in force for mobile (as of 2026-10-04)

- The phone keeps 2 versions per app by default, customizable (2, 3, 5 or all). The app is shown as "Kneecap" with a capital K.
- Captions speech-to-text for web apps is a proposal, not decided.
- Publik API inside the app is OFF; routing work is parked until it can be tested.
- Version history on the phone must be space efficient at 3, 100 and 1,000 apps with many versions, and never lose user data.
