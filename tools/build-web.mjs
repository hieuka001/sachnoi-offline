// build-web.mjs — Đóng gói web/ từ web-src + text-engine + vendor (jszip, pdfjs).
// Mọi thứ đều đóng kèm trong app: chạy offline tuyệt đối, không CDN.
import { cpSync, rmSync, mkdirSync, existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const web = join(root, "web");
rmSync(web, { recursive: true, force: true });
mkdirSync(join(web, "vendor"), { recursive: true });

cpSync(join(root, "web-src"), web, { recursive: true });
cpSync(join(root, "src/text-engine"), join(web, "text-engine"), { recursive: true });
cpSync(join(root, "voices/voices.json"), join(web, "voices.json"));
cpSync(join(root, "node_modules/jszip/dist/jszip.min.js"), join(web, "vendor/jszip.min.js"));
cpSync(join(root, "node_modules/pdfjs-dist/build/pdf.min.mjs"), join(web, "vendor/pdf.min.mjs"));
cpSync(join(root, "node_modules/pdfjs-dist/build/pdf.worker.min.mjs"), join(web, "vendor/pdf.worker.min.mjs"));

for (const f of ["index.html", "app.js", "voices.json", "vendor/jszip.min.js", "vendor/pdf.min.mjs", "text-engine/index.js"]) {
  if (!existsSync(join(web, f))) throw new Error(`Thiếu file sau build: ${f}`);
}
console.log("web/ sẵn sàng:", web);
