// Copies the CesiumJS runtime (workers, assets, widgets CSS) into public/cesium so it is served as static files.
import { cpSync, existsSync, mkdirSync, rmSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const src = join(root, "node_modules", "cesium", "Build", "Cesium");
const dst = join(root, "public", "cesium");
if (!existsSync(src)) { console.error("cesium is not installed; run npm install"); process.exit(1); }
rmSync(dst, { recursive: true, force: true });
mkdirSync(dst, { recursive: true });
for (const d of ["Workers", "Assets", "ThirdParty", "Widgets"]) cpSync(join(src, d), join(dst, d), { recursive: true });
cpSync(join(src, "Cesium.js"), join(dst, "Cesium.js"));
console.log("Cesium runtime copied to public/cesium");
