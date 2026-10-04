// RC-03 (round5/rc03-website). Plain-language website content, sourced from
// apple-compliance/LISTING.md, PRIVACY_POLICY_OUTLINE.md and PRIVACY_LABEL.md
// (unit RC-13, docs/plans/20260928-all-routes/apple-compliance/). Nothing
// here is deployed; build-site.mjs turns this into the actual pages.
//
// Every business or pricing statement in this file ("nothing for sale", "no
// subscription") is a product fact backed by the codebase cited in
// LISTING.md section 2 and 3 (no StoreKit reference, no price field in the
// catalog contract), not a market or fundraising claim, so it does not draw
// on artifacts/ref-business-model.json.
//
// publisher: "Publik" (RC-05's recommended rendering, "By Publik") appears
// as page text here. RC-05 itself (the schema field on AppStoreMetadataV1)
// is a separate unit's file (mobile-shell/contracts/index.d.ts, index.js);
// this unit does not add an undocumented key to that contract.

export const PUBLISHER_NAME = "Publik";
export const SUPPORT_EMAIL = "support@publikhq.com";
export const REPORT_EMAIL = "report@publikhq.com";

// OD-06 (apple-compliance/REQUIRED_CHANGES.md, decided in DECISIONS.md):
// "Publik reads every report" replaces a specific reply-time promise until
// someone owns the report mailbox and can keep a fixed number of days.
export const REPORT_REPLY_PROMISE = "Publik reads every report.";

// OD-11: no Apple Developer team is enrolled yet (Release.xcconfig's
// DEVELOPMENT_TEAM is empty). This placeholder is clearly not a real team
// id (it fails Apple's own 10-character team id format only in spirit, not
// in the AASA validator's shape check) and must be replaced with the real
// team id from Release.xcconfig the day enrollment completes, before this
// AASA file is ever deployed. Flagged to the owner (see NEEDS_OWNER.md).
export const PLACEHOLDER_APPLE_TEAM_ID = "TEAMIDTBD1";
export const RELEASE_BUNDLE_ID = "com.publikhq.iris.mobileshell";

// R5-RC-03-website-2: the single source of truth for whether Iris Apps
// itself has a real App Store or TestFlight link yet. null means it does
// not (no Apple Developer team is enrolled, OD-11), and every app page's
// copy and its "Get <app>" box must read consistently with that: no
// promise of a download, one honest sentence about what to do today
// instead (see howToGetItCopy below and integration.mjs's
// renderCatalogHandoffHTML, which both read this same fact through
// build-site.mjs -> site-pages.mjs, never a hardcoded value of their own).
// The day a real https://apps.apple.com/... or
// https://testflight.apple.com/join/... link exists, set it here (it is
// validated by integration.mjs's validateAppleDistributionURL) and every
// app page switches to a real Install Iris button in its place;
// tests/jess-reads-app-pages.test.mjs exercises both states.
export const IRIS_DISTRIBUTION_URL = null;

// Per-app App Store Guideline 4.7 metadata (AppStoreMetadataV1). Age
// ratings: Kneecap 4 and FreeHarmony 13 are unchanged from the seed
// (mobile-shell/website/seed-catalog-v2.mjs). Nut AI is 13 here per OD-08's
// decision ("13+ in the seed, 'infrequent or mild' on the form",
// apple-compliance/DECISIONS.md section 1.3 and QUESTIONNAIRE.md section 4),
// which this unit cannot write into seed-catalog-v2.mjs (excluded from this
// unit's owned paths) but can and does apply to the live website catalog
// this unit publishes. See NEEDS_OWNER.md for the resulting note asking
// the seed's own owner to bring the bundled fallback catalog in line.
export const AGE_RATING_BY_SLUG = Object.freeze({
  kneecap: 4,
  "nut-ai": 13,
  freeharmony: 13,
  // round6/catalog-expand (SPEC.md section 6): a proposal for the owner, 16+
  // because Lunara logs intimacy, contraception and pregnancy. Same number as
  // SEED_APPS in seed-catalog-v2.mjs.
  lunara: 16,
});

const PRIVACY_POLICY_URL = "https://publikhq.com/iris/privacy";

export function appStoreMetadataFor(slug, privacySummary) {
  const ageRating = AGE_RATING_BY_SLUG[slug];
  if (!ageRating) throw new TypeError(`no decided age rating for ${slug}`);
  return {
    kind: "iris.mobile-shell.app-store-metadata",
    version: 1,
    ageRating,
    privacySummary,
    privacyPolicyUrl: PRIVACY_POLICY_URL,
    supportContact: { kind: "email", value: SUPPORT_EMAIL },
    reportContact: { kind: "email", value: REPORT_EMAIL },
  };
}

// Plain-language "what does it cost" and "how to get it" copy, one per app,
// for a non-technical reader. Backed by LISTING.md section 2 and 3 (no
// account, no ads, nothing for sale) and DEPLOY.md ("The iPhone app already
// carries these exact files inside it").
export const COST_COPY = "Free. Nothing in Iris Apps is for sale, and there is no subscription.";

// `isDownloadable` must be `Boolean(IRIS_DISTRIBUTION_URL)` (site-pages.mjs
// passes this through), so this sentence can never promise a download the
// page cannot deliver. A blind test (Jess, R5-RC-03-website-2) hit exactly
// that: the old unconditional text ("the fastest way to get it today")
// sat right above a "Get Kneecap" box that said there was no download link
// today, and read as the page being broken rather than not released yet.
export function howToGetItCopy(name, isDownloadable) {
  if (isDownloadable) {
    return `${name} comes built into Iris Apps, Publik's own collection of apps for iPhone. `
      + "Tap Install Iris below to add it.";
  }
  return `${name} comes built into Iris Apps, Publik's own collection of apps for iPhone. `
    + "Iris Apps is not in the App Store yet, so there is nothing to download here today. "
    + "See below for what you can do right now.";
}

export function dataLeavesPhoneCopy(name, privacySummary) {
  return `${privacySummary} The only thing Iris Apps sends anywhere is a short check for which apps are `
    + `available, ${name}'s icon, and the app itself if you choose to install it. `
    + "Nothing you type, record, or save inside the app leaves your phone.";
}

// Privacy policy page, in sections. Each `body` is one or more paragraphs
// (an array of plain strings, already safe for HTML text; no markup). This
// mirrors apple-compliance/PRIVACY_POLICY_OUTLINE.md's numbered sections,
// written for a non-technical reader on a phone. Section 8 (removing an
// app) uses the outline's OWN caution: RC-04 (the "also delete my data"
// removal path) has not landed yet, so the narrower, honest claim is used,
// not the fuller one the outline says to hold back.
export function privacyPolicySections({ appNames }) {
  const appList = appNames.join(", ");
  return [
    {
      heading: "What Iris Apps is",
      body: [`Iris Apps is ${PUBLISHER_NAME}'s own collection of apps that run on your iPhone: ${appList}.`],
    },
    {
      heading: "What stays on your iPhone",
      body: [
        "Everything each app does stays on your phone. Kneecap's video clips and projects, Nut AI's food log and "
        + "weight history, FreeHarmony's photos and measurements, and Lunara's cycle log are all kept only on your "
        + "device, never sent anywhere.",
        "Each app runs in its own separate, isolated storage area, so apps never share data with each other, and "
        + `no app in Iris Apps can reach the internet on its own; ${PUBLISHER_NAME} controls that at the app level.`,
      ],
    },
    {
      heading: "What Iris Apps sends to Publik, and why",
      body: [
        "The only thing Iris Apps sends anywhere is a request to publikhq.com to check which apps are available, "
        + "to fetch an app's icon, and to download an app you chose to install. These requests do not carry your "
        + "food log, your video clips, your photos, or anything you typed into an app.",
      ],
    },
    {
      heading: "Permissions an app may ask for",
      body: [
        "Camera: asked for only inside the specific app that needs it, at the moment it is needed, and you can "
        + "turn it off again in Iris Apps' own Permissions screen.",
        "Photos: add-only, for saving a finished video (Kneecap) or picking a photo (Kneecap, FreeHarmony) through "
        + "the system picker, which never gives an app your whole photo library.",
        "Microphone: never requested by any app in Iris Apps.",
      ],
    },
    {
      heading: "Health and wellness content",
      body: [
        "Nut AI's calorie, protein, carb, and weight figures are estimates, not medical advice, and Nut AI is not "
        + "a medical device. It does not diagnose, treat, cure, or prevent any condition. Talk to a registered "
        + "dietitian or healthcare provider before making medical decisions.",
        "FreeHarmony's face measurements are for information only, are not a diagnosis, and are never used to "
        + "identify you.",
        "Lunara's cycle predictions are estimates and can be wrong. They are not medical advice, not contraception "
        + "and not a diagnosis, and Lunara is not a medical device.",
      ],
    },
    {
      heading: "Reporting a problem with an app",
      body: [
        `Every app has a Report control that opens your phone's own mail app addressed to ${PUBLISHER_NAME}. `
        + REPORT_REPLY_PROMISE,
      ],
    },
    {
      heading: "Blocking an app",
      body: [
        "You can hide any app from Browse and Search on your own iPhone at any time. This is entirely local: "
        + `nothing is reported to ${PUBLISHER_NAME}, and no account is needed.`,
      ],
    },
    {
      heading: "Removing an app and its data",
      body: [
        // Narrower claim: RC-04 (WKWebsiteDataStore.remove wiring) has not
        // landed yet (round5/REPLAN.md, RC-04 still queued after MV4).
        "Removing an app removes it from your Home Screen and My apps. Your data for that app stays on your phone "
        + `unless you choose to delete it, and ${PUBLISHER_NAME} is still finishing the delete option itself.`,
      ],
    },
    {
      heading: "No account, no outside ads, nothing for sale",
      body: [
        "There is no account anywhere in Iris Apps or in any app inside it, no advertising from outside "
        + `${PUBLISHER_NAME}, and nothing to buy.`,
      ],
    },
    {
      heading: "Children",
      body: [
        "Iris Apps and the apps inside it are not directed at children and collect no personal information from "
        + "anyone.",
      ],
    },
    {
      heading: "Contact and updates",
      body: [
        `Questions: ${SUPPORT_EMAIL}. If what Iris Apps collects or sends ever changes, this page will say so.`,
      ],
    },
  ];
}

export function supportPageIntro() {
  return "Iris Apps is Publik's own collection of apps for iPhone. If something is not working, or an app did "
    + "something you did not expect, here is how to reach us.";
}
