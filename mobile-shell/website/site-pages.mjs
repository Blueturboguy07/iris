// RC-03 (round5/rc03-website). Renders the human-facing HTML pages: the
// Iris Apps hub, one page per published app, the privacy policy, the
// support page, and a not-found page. Plain words for a non-technical
// reader on a phone; every functional or pricing sentence traces to
// site-content.mjs, which cites apple-compliance/LISTING.md and
// PRIVACY_POLICY_OUTLINE.md (unit RC-13).
//
// Every page carries the same header/footer navigation (Home, Privacy,
// Support), so Privacy and Support are reachable in exactly one tap from
// any app page, well inside the "two taps" gate.

import { renderCatalogHandoffHTML } from "./integration.mjs";
import {
  COST_COPY,
  IRIS_DISTRIBUTION_URL,
  PUBLISHER_NAME,
  SUPPORT_EMAIL,
  dataLeavesPhoneCopy,
  howToGetItCopy,
  privacyPolicySections,
  supportPageIntro,
} from "./site-content.mjs";

export function htmlEscape(value) {
  return String(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

const NAV_LINKS = [
  { href: "/iris/privacy", label: "Privacy" },
  { href: "/iris/support", label: "Support" },
];

function nav() {
  const items = NAV_LINKS.map((link) => `      <a href="${htmlEscape(link.href)}">${htmlEscape(link.label)}</a>`).join("\n");
  return `  <div class="wrap">\n`
    + `    <a class="brand" href="/iris/">Iris Apps</a>\n`
    + `    <nav aria-label="Main">\n${items}\n    </nav>\n`
    + `  </div>`;
}

function footer() {
  return '  <footer class="site-footer">\n'
    + '    <div class="wrap">\n'
    + `      <p>${htmlEscape(PUBLISHER_NAME)}</p>\n`
    + `      <p><a href="mailto:${SUPPORT_EMAIL}">${htmlEscape(SUPPORT_EMAIL)}</a></p>\n`
    + `      <p><a href="https://publikhq.com">publikhq.com</a></p>\n`
    + "    </div>\n"
    + "  </footer>";
}

/** One shared page shell. `title` and `description` are plain text (escaped here). `bodyHTML` is already-safe HTML. */
export function pageShell({ title, description, bodyHTML }) {
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${htmlEscape(title)}</title>
<meta name="description" content="${htmlEscape(description)}">
<link rel="stylesheet" href="/iris/site.css">
</head>
<body>
<header class="site-header">
${nav()}
</header>
<main>
<div class="wrap">
${bodyHTML}
</div>
</main>
${footer()}
</body>
</html>
`;
}

function permissionListHTML(permissions) {
  if (permissions.length === 0) return "  <p>This app does not ask for any device permission.</p>";
  const items = permissions.map((permission) => `    <li>${htmlEscape(permission.label)}</li>`).join("\n");
  return `  <ul>\n${items}\n  </ul>`;
}

/**
 * One app's page. `row`/`catalogRows` feed renderCatalogHandoffHTML (the
 * existing, already-escaped "Open in Iris" / age-rating / privacy /
 * report block); `appPage` is the CatalogAppPageV1 document (description,
 * permissions, privacySummary) for this same app.
 */
export function renderAppPageHTML({ slug, name, categoryNames, appPage, catalogRows, irisDistributionURL = IRIS_DISTRIBUTION_URL }) {
  const title = `${name}, an app in Iris Apps`;
  const description = appPage.description.length > 160 ? `${appPage.description.slice(0, 157)}...` : appPage.description;
  // Both the sentence above the box and the box itself (renderCatalogHandoffHTML)
  // read this exact same fact, so they can never again disagree about
  // whether there is something to tap and download today.
  const isDownloadable = Boolean(irisDistributionURL);
  const body = `<article>
  <h1>${htmlEscape(name)}</h1>
  <p class="lede">${htmlEscape(appPage.description)}</p>
  <h2>What it costs</h2>
  <p>${htmlEscape(COST_COPY)}</p>
  <h2>What data leaves your phone</h2>
  <p>${htmlEscape(dataLeavesPhoneCopy(name, appPage.privacySummary))}</p>
  <h2>What it can use on your phone</h2>
${permissionListHTML(appPage.permissions)}
  <h2>Category</h2>
  <p>${htmlEscape(categoryNames.join(", "))}</p>
  <h2>How to get it</h2>
  <p>${htmlEscape(howToGetItCopy(name, isDownloadable))}</p>
${renderCatalogHandoffHTML({ catalogRows, selectedSlug: slug, irisDistributionURL })}
</article>`;
  return pageShell({ title, description, bodyHTML: body });
}

/** The Iris Apps hub page: every app grouped by category, linking to each app page. */
export function renderHubPageHTML({ categories, appsByCategory, catalogRows }) {
  const sections = categories.map((category) => {
    const apps = appsByCategory.get(category.id) ?? [];
    const items = apps.map((app) => (
      `      <li><a class="app-link" href="/iris/apps/${htmlEscape(app.slug)}">${htmlEscape(app.name)}`
      + `<span class="app-summary">${htmlEscape(app.summary)}</span></a></li>`
    )).join("\n");
    return `  <section class="category-block">\n    <h2>${htmlEscape(category.name)}</h2>\n    <ul class="app-list">\n${items}\n    </ul>\n  </section>`;
  }).join("\n");
  const body = `<article>
  <h1>Iris Apps</h1>
  <p class="lede">${htmlEscape(PUBLISHER_NAME)}'s own apps for your iPhone. Free, with nothing to buy and no account.</p>
${sections}
</article>`;
  void catalogRows;
  return pageShell({
    title: "Iris Apps by Publik",
    description: "Publik's own apps for your iPhone: browse what's inside Iris Apps.",
    bodyHTML: body,
  });
}

export function renderPrivacyPageHTML({ appNames }) {
  const sections = privacyPolicySections({ appNames }).map((section) => {
    const paragraphs = section.body.map((paragraph) => `    <p>${htmlEscape(paragraph)}</p>`).join("\n");
    return `  <section>\n    <h2>${htmlEscape(section.heading)}</h2>\n${paragraphs}\n  </section>`;
  }).join("\n");
  const body = `<article>
  <h1>Privacy</h1>
${sections}
</article>`;
  return pageShell({
    title: "Iris Apps privacy",
    description: "What Iris Apps and the apps inside it do and do not send off your iPhone.",
    bodyHTML: body,
  });
}

export function renderSupportPageHTML({ apps }) {
  const rows = apps.map((app) => (
    `    <li>${htmlEscape(app.name)}: <a href="/iris/apps/${htmlEscape(app.slug)}">its page</a>, `
    + `or <a href="mailto:${SUPPORT_EMAIL}?subject=${encodeURIComponent(`Iris Apps: ${app.name}`)}">email us about it</a></li>`
  )).join("\n");
  const body = `<article>
  <h1>Support</h1>
  <p class="lede">${htmlEscape(supportPageIntro())}</p>
  <h2>Contact ${htmlEscape(PUBLISHER_NAME)}</h2>
  <p><a class="btn btn-primary" href="mailto:${SUPPORT_EMAIL}">Email ${htmlEscape(SUPPORT_EMAIL)}</a></p>
  <h2>Report a problem with a specific app</h2>
  <p>Each app's own page has a Report button. You can also use these direct links:</p>
  <ul class="contact-list">
${rows}
  </ul>
  <h2>Read our <a href="/iris/privacy">privacy page</a></h2>
</article>`;
  return pageShell({
    title: "Iris Apps support",
    description: "How to reach Publik about Iris Apps or one of the apps inside it.",
    bodyHTML: body,
  });
}

export function renderNotFoundPageHTML() {
  const body = `<article class="not-found">
  <h1>This page isn't here</h1>
  <p class="lede">The page you're looking for may have moved, or the link may have a typo.</p>
  <p><a class="btn btn-primary" href="/iris/">Go to the Iris Apps home page</a></p>
  <p><a href="/iris/support">Or reach Publik on the support page</a></p>
</article>`;
  return pageShell({
    title: "Page not found, Iris Apps",
    description: "This Iris Apps page could not be found.",
    bodyHTML: body,
  });
}
