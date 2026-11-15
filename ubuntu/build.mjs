// Bundles the main process, the preload script and the windows into dist/.
import { build } from "esbuild";
import fs from "node:fs";

fs.rmSync("dist", { recursive: true, force: true });
fs.mkdirSync("dist/renderer", { recursive: true });

const common = { bundle: true, sourcemap: false, logLevel: "warning", target: "es2022" };

await Promise.all([
  build({ ...common, entryPoints: ["src/main/main.ts"], outfile: "dist/main.js", platform: "node", format: "cjs", external: ["electron", "usocket", "x11", "event-stream"] }),
  build({ ...common, entryPoints: ["src/main/preload.ts"], outfile: "dist/preload.js", platform: "node", format: "cjs", external: ["electron"] }),
  build({
    ...common,
    entryPoints: { index: "src/renderer/index.tsx" },
    outdir: "dist/renderer",
    platform: "browser",
    format: "iife",
    jsx: "automatic",
    jsxImportSource: "preact",
    loader: { ".woff2": "file", ".woff": "file" },
    assetNames: "fonts/[name]-[hash]",
  }),
]);

fs.copyFileSync("src/renderer/index.html", "dist/renderer/index.html");
fs.copyFileSync("resources/icon.png", "dist/icon.png");
console.log("Build fertig: dist/");
