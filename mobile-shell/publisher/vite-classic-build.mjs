import { createRequire } from "node:module";
import { lstat, mkdir, readFile, realpath, readdir, writeFile } from "node:fs/promises";
import { dirname, isAbsolute, join, relative, resolve, sep } from "node:path";
import { pathToFileURL } from "node:url";

// A publisher-side build adapter, NOT a WebView permission override. The native
// shell keeps its file-origin, navigation, storage and capability restrictions.
// This explicitly executes a caller-reviewed project's installed Vite toolchain.
// It never installs dependencies, downloads content or publishes a package.

function inside(root, candidate) {
  const path = relative(root, candidate);
  return path === "" || (!isAbsolute(path) && path !== ".." && !path.startsWith(`..${sep}`));
}

export function classicEntrypointHTML(template, { sourceEntry, hasCSS }) {
  if (typeof template !== "string" || Buffer.byteLength(template) > 1_048_576) {
    throw new TypeError("reviewed HTML entrypoint must be bounded text");
  }
  const scripts = [...template.matchAll(/<script\b[^>]*>[\s\S]*?<\/script\s*>/gi)];
  if (scripts.length !== 1) throw new TypeError("classic adapter requires exactly one reviewed module entry script");
  const tag = scripts[0][0];
  const type = tag.match(/\btype\s*=\s*(["'])module\1/i);
  const source = tag.match(/\bsrc\s*=\s*(["'])([^"']+)\1/i);
  if (!type || !source || source[2].replace(/^\.\//, "").replace(/^\//, "") !== sourceEntry) {
    throw new TypeError("HTML module entry does not match the explicitly reviewed source entry");
  }
  if (/<base\b/i.test(template) || /\bimportmap\b/i.test(template)) {
    throw new TypeError("base/import-map HTML requires a separately reviewed build adapter");
  }
  return template.replace(tag,
    `${hasCSS ? '<link rel="stylesheet" href="./app.css">\n    ' : ''}<script defer src="./app.js"></script>`);
}

export async function buildClassicViteApp({ sourceRoot, sourceEntry = "src/main.tsx", outputRoot }) {
  if (!isAbsolute(sourceRoot ?? "") || !isAbsolute(outputRoot ?? "")) {
    throw new TypeError("source/output roots must be explicit absolute paths");
  }
  const root = await realpath(sourceRoot);
  const requestedOutput = resolve(outputRoot);
  const outputParent = await realpath(dirname(requestedOutput));
  const output = join(outputParent, requestedOutput.slice(dirname(requestedOutput).length + 1));
  if (inside(root, output) || inside(output, root)) throw new TypeError("output must be separate from reviewed source");
  try {
    await lstat(output);
    throw new TypeError("output already exists; previous build is preserved");
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
  }
  if (isAbsolute(sourceEntry) || sourceEntry.includes("\\") || sourceEntry.split("/").includes("..")) {
    throw new TypeError("source entry must be a confined relative file");
  }
  const entry = await realpath(join(root, sourceEntry));
  if (!inside(root, entry) || !(await lstat(entry)).isFile()) throw new TypeError("source entry is outside the reviewed root");
  const template = await readFile(join(root, "index.html"), "utf8");
  // Validate the source-to-HTML relationship before executing the build.
  classicEntrypointHTML(template, { sourceEntry, hasCSS: false });
  const requireFromSource = createRequire(join(root, "package.json"));
  const viteRoot = dirname(requireFromSource.resolve("vite/package.json"));
  const { build } = await import(pathToFileURL(join(viteRoot, "dist/node/index.js")).href);
  await mkdir(output);
  await build({
    root,
    configFile: join(root, "vite.config.ts"),
    base: "./",
    define: { "process.env.NODE_ENV": JSON.stringify("production") },
    build: {
      target: "safari16",
      outDir: output,
      emptyOutDir: false,
      copyPublicDir: true,
      sourcemap: false,
      modulePreload: false,
      cssCodeSplit: false,
      lib: { entry, name: "IrisHostedApp", formats: ["iife"], fileName: () => "app.js", cssFileName: "app" },
      rollupOptions: { output: { inlineDynamicImports: true } },
    },
  });
  const names = await readdir(output);
  if (!names.includes("app.js")) throw new TypeError("classic entry bundle was not produced");
  const html = classicEntrypointHTML(template, { sourceEntry, hasCSS: names.includes("app.css") });
  await writeFile(join(output, "index.html"), html, { flag: "wx", mode: 0o600 });
  return { outputRoot: output, entrypoint: "index.html", format: "classic-iife", sourceEntry };
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const [sourceRoot, outputRoot, sourceEntry] = process.argv.slice(2);
  try {
    const result = await buildClassicViteApp({ sourceRoot, outputRoot, sourceEntry: sourceEntry ?? "src/main.tsx" });
    process.stdout.write(`${JSON.stringify(result)}\n`);
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
  }
}
