// A narrow compatibility check, not an HTML sanitizer or runtime certification.
// The current iOS Host preserves file-origin storage. External ES-module scripts
// need CORS loading that this runtime does not enable. Reject the known-broken
// entry shape before a developer packages it as a runnable mobile app.

function decodeAttribute(value) {
  return value.replace(/&#(?:x([0-9a-f]+)|([0-9]+));?|&(Tab|NewLine);/gi,
    (whole, hex, decimal, named) => {
      if (named) return named.toLowerCase() === "tab" ? "\t" : "\n";
      const point = Number.parseInt(hex ?? decimal, hex ? 16 : 10);
      return point > 0 && point <= 0x10ffff && !(point >= 0xd800 && point <= 0xdfff)
        ? String.fromCodePoint(point) : "\ufffd";
    });
}

function attributes(text) {
  const result = new Map();
  const pattern = /([^\s"'<>\/=]+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+)))?/g;
  for (const match of text.matchAll(pattern)) {
    const name = match[1].toLowerCase();
    // HTML uses the first occurrence, not an app's later duplicate attribute.
    if (!result.has(name)) result.set(name, decodeAttribute(match[2] ?? match[3] ?? match[4] ?? ""));
  }
  return result;
}

export function verifyFileRuntimeEntrypoint(htmlBytes) {
  const html = Buffer.from(htmlBytes).toString("utf8");
  let cursor = 0;
  while (cursor < html.length) {
    const start = html.indexOf("<", cursor);
    if (start < 0) return;
    if (html.startsWith("<!--", start)) {
      const end = html.indexOf("-->", start + 4);
      cursor = end < 0 ? html.length : end + 3;
      continue;
    }
    const tag = /^<([a-z][a-z0-9:-]*)\b/i.exec(html.slice(start, start + 128));
    if (!tag) { cursor = start + 1; continue; }
    const name = tag[1].toLowerCase();
    let end = start + tag[0].length, quote = null;
    for (; end < html.length; end += 1) {
      const character = html[end];
      if (quote) { if (character === quote) quote = null; }
      else if (character === '"' || character === "'") quote = character;
      else if (character === ">") break;
    }
    if (end === html.length) return;
    if (name === "script") {
      const attrs = attributes(html.slice(start + tag[0].length, end));
      if (attrs.has("src") && attrs.get("type")?.trim().toLowerCase() === "module") {
        throw new TypeError(
          "file-origin runtime cannot load an external module script; rebuild the reviewed app "
          + "with a file-compatible classic-script adapter, then test its actual startup in Iris. "
          + "Do not merely remove type=module from code that still contains imports.");
      }
    }
    cursor = end + 1;
    if (name === "plaintext") return;
    // Do not interpret code, CSS, JSON, or text examples as HTML script tags.
    if (["script", "style", "textarea", "title", "xmp", "iframe", "noembed", "noframes"].includes(name)) {
      const close = new RegExp(`</${name}\\s*>`, "gi");
      close.lastIndex = cursor;
      const match = close.exec(html);
      cursor = match ? close.lastIndex : html.length;
    }
  }
}
