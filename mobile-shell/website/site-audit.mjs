// RC-03 (round5/rc03-website). A person-following-links oracle for the
// built site: independent of build-site.mjs (it re-reads bytes from disk
// and re-parses them; it does not import anything build-site.mjs computed
// in memory), so a bug in the generator cannot also hide from this check.
//
// Three checks, matching the unit's gates:
//   1. every link on every generated HTML page resolves to a generated
//      file (an internal path) or an explicitly allowed external URL;
//   2. the Privacy and Support pages are reachable within two taps of
//      every app page;
//   3. every AASA universal-link path pattern matches an actual
//      /iris/apps/<slug> route this build generated, and every app route
//      is covered by some AASA pattern.

import { readFile, readdir, stat } from "node:fs/promises";
import { join, posix, relative } from "node:path";

const ORIGIN = "https://publikhq.com";
// Links this static build may point at without a corresponding generated
// file: the live Publik marketing root (out of this unit's scope, RC-03
// owns only /iris/* and /api/iris/mobile/* and the AASA file), plus the two
// non-file link schemes the pages use (mailto: for contact/report,
// iris-apps: for the in-app open fallback).
const ALLOWED_EXTERNAL_EXACT = new Set([`${ORIGIN}/`, ORIGIN]);

const HREF_SRC_PATTERN = /\s(?:href|src)="([^"]*)"/g;

export function extractLinks(html) {
  const links = [];
  for (const match of html.matchAll(HREF_SRC_PATTERN)) links.push(match[1]);
  return links;
}

async function walkHTMLFiles(root) {
  const out = [];
  async function walk(dir) {
    for (const entry of await readdir(dir, { withFileTypes: true })) {
      const full = join(dir, entry.name);
      if (entry.isDirectory()) await walk(full);
      else if (entry.name.endsWith(".html")) out.push(full);
    }
  }
  await walk(root);
  return out.sort();
}

/** True when `pattern` (an AASA path, possibly ending in "*") matches `path`, Apple's own simple prefix-glob rule. */
export function aasaPathMatches(pattern, path) {
  if (pattern.endsWith("*")) return path.startsWith(pattern.slice(0, -1));
  return pattern === path;
}

function isMailtoLink(link) {
  return /^mailto:[^\s?]+@[^\s?]+(\?.*)?$/.test(link);
}

function isIrisAppsSchemeLink(link, knownSlugs) {
  const match = /^iris-apps:\/\/install\/([a-z0-9][a-z0-9._-]{0,127})$/.exec(link);
  return match !== null && knownSlugs.has(match[1]);
}

/** Resolves a link found on `fromRelativePath` to a site-relative path ("" has no leading slash), or null if it is not a file-resolving internal link. */
function resolveInternalPath(link, fromRelativePath) {
  let pathPart = link;
  if (link.startsWith(`${ORIGIN}/`)) pathPart = link.slice(ORIGIN.length);
  else if (!link.startsWith("/") && !/^[a-z][a-z0-9+.-]*:/i.test(link)) {
    // A relative link (none are emitted today, but resolve correctly if one is added).
    pathPart = posix.join(posix.dirname(`/${fromRelativePath}`), link);
  } else if (!link.startsWith("/")) {
    return null; // some other scheme (mailto:, iris-apps:, an unrecognized external absolute URL)
  }
  const [withoutHash] = pathPart.split("#");
  const clean = withoutHash.replace(/^\/+/, "").replace(/\/+$/, "");
  return clean;
}

/** A site path ("iris/privacy") to the file that answers it, mirroring a static host with directory index files ("iris/privacy" -> "iris/privacy/index.html"). */
function candidateFilesForPath(sitePath) {
  if (sitePath === "") return ["index.html"];
  if (sitePath.endsWith(".html") || sitePath.endsWith(".json") || sitePath.endsWith(".png") || sitePath.endsWith(".css")) return [sitePath];
  if (sitePath === ".well-known/apple-app-site-association") return [sitePath];
  return [`${sitePath}/index.html`, `${sitePath}.html`];
}

/**
 * Reads every HTML file under `root` and checks every href/src on it.
 * Returns { errors: string[], graph: Map<relativePath, Set<resolvedRelativePath>> }
 * where `graph` only carries edges between two generated pages (used for
 * the two-tap reachability check), and `errors` covers both a broken
 * internal link and a disallowed external one.
 */
export async function auditSiteLinks(root) {
  const errors = [];
  const htmlFiles = await walkHTMLFiles(root);
  const knownFiles = new Set(htmlFiles.map((file) => relative(root, file)));
  // Also recognize non-HTML generated files (icons, json, AASA) as valid
  // link targets, since a real page could reference the catalog or icons.
  async function collectAllFiles(dir, base = "") {
    for (const entry of await readdir(dir, { withFileTypes: true })) {
      const rel = base ? `${base}/${entry.name}` : entry.name;
      const full = join(dir, entry.name);
      const info = await stat(full);
      if (info.isDirectory()) await collectAllFiles(full, rel);
      else knownFiles.add(rel);
    }
  }
  await collectAllFiles(root);

  const slugMatch = /^iris\/apps\/([^/]+)\/index\.html$/;
  const knownSlugs = new Set(
    [...knownFiles].map((file) => slugMatch.exec(file)?.[1]).filter(Boolean),
  );

  const graph = new Map();
  for (const file of htmlFiles) {
    const relPath = relative(root, file);
    const html = await readFile(file, "utf8");
    const edges = new Set();
    for (const link of extractLinks(html)) {
      if (ALLOWED_EXTERNAL_EXACT.has(link)) continue;
      if (isMailtoLink(link)) continue;
      if (isIrisAppsSchemeLink(link, knownSlugs)) continue;
      const sitePath = resolveInternalPath(link, relPath);
      if (sitePath === null) {
        errors.push(`${relPath}: link "${link}" is neither an internal path nor an allowed external URL`);
        continue;
      }
      const candidates = candidateFilesForPath(sitePath);
      const resolved = candidates.find((candidate) => knownFiles.has(candidate));
      if (!resolved) {
        errors.push(`${relPath}: link "${link}" does not resolve to any generated file (tried ${candidates.join(", ")})`);
        continue;
      }
      if (resolved.endsWith(".html")) edges.add(resolved);
    }
    graph.set(relPath, edges);
  }
  return { errors, graph, knownFiles, knownSlugs };
}

/** BFS depth (0 = itself) from `from` to any of `targets` within `graph`, or Infinity if unreachable within `maxDepth`. */
function shortestDepth(graph, from, targets, maxDepth) {
  let frontier = new Set([from]);
  const visited = new Set([from]);
  for (let depth = 0; depth <= maxDepth; depth += 1) {
    for (const node of frontier) if (targets.has(node)) return depth;
    const next = new Set();
    for (const node of frontier) {
      for (const edge of graph.get(node) ?? []) {
        if (!visited.has(edge)) {
          visited.add(edge);
          next.add(edge);
        }
      }
    }
    frontier = next;
  }
  return Infinity;
}

/** Errors for any app page more than two taps (edges) from Privacy or Support. */
export function checkTwoTapReachability(graph) {
  const errors = [];
  const targets = new Set(["iris/privacy/index.html", "iris/support/index.html"]);
  for (const node of graph.keys()) {
    if (!/^iris\/apps\/[^/]+\/index\.html$/.test(node)) continue;
    const depth = shortestDepth(graph, node, targets, 2);
    if (depth > 2) errors.push(`${node}: Privacy/Support are not reachable within two taps (shortest found: ${depth})`);
  }
  return errors;
}

/** Errors when the AASA's universal-link paths and the generated /iris/apps/<slug> routes disagree either way. */
export function checkAASAPaths({ aasaJSON, appSlugs }) {
  const errors = [];
  const patterns = aasaJSON?.applinks?.details?.[0]?.paths ?? [];
  const routes = [...appSlugs].map((slug) => `/iris/apps/${slug}`);
  for (const route of routes) {
    if (!patterns.some((pattern) => aasaPathMatches(pattern, route))) {
      errors.push(`AASA has no path pattern matching the generated route ${route}`);
    }
  }
  for (const pattern of patterns) {
    if (!pattern.startsWith("/iris/apps/")) {
      errors.push(`AASA path pattern "${pattern}" does not match any /iris/apps/<slug> route this build generates`);
    }
  }
  return errors;
}
