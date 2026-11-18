// Test ô chọn giọng điền ngay lúc khởi động (lib/voiceOptions.js) — 1.9.3 P0-A
// Bối cảnh: cả 2 ô chọn giọng (thanh phát + sheet Tuỳ chỉnh) chỉ được điền
// trong renderVoices(), mà hàm đó chỉ chạy khi mở tab Giọng. Mở app rồi vào
// thẳng sheet Tuỳ chỉnh thì select trống -> iOS hiện "No Options".
// Sửa: builder thuần buildVoiceOptions() + app.js điền cả 2 select lúc init.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { buildVoiceOptions, escapeVoiceHtml } from "../web-src/lib/voiceOptions.js";

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, "..");
const appJs = readFileSync(join(root, "web-src/app.js"), "utf8");

test("buildVoiceOptions: luôn có option mặc định đầu tiên", () => {
  const html = buildVoiceOptions([]);
  assert.equal(html, `<option value="default">Giọng mặc định</option>`);
  assert.equal(buildVoiceOptions(undefined), `<option value="default">Giọng mặc định</option>`);
  assert.equal(buildVoiceOptions(null), `<option value="default">Giọng mặc định</option>`);
});

test("buildVoiceOptions: một option cho mỗi giọng trong manifest", () => {
  const html = buildVoiceOptions([
    { id: "mai-anh", name: "Mai Anh" },
    { id: "hai-dang", name: "Hải Đăng" },
  ]);
  assert.ok(html.includes(`<option value="mai-anh">Mai Anh</option>`));
  assert.ok(html.includes(`<option value="hai-dang">Hải Đăng</option>`));
  assert.equal((html.match(/<option/g) || []).length, 3);
});

test("buildVoiceOptions: escape id và tên giọng (không vỡ HTML)", () => {
  assert.equal(escapeVoiceHtml(`a"b<c>&d'e`), "a&quot;b&lt;c&gt;&amp;d&#39;e");
  const html = buildVoiceOptions([{ id: `x"><script`, name: `A & B <C>` }]);
  assert.ok(!html.includes("<script"));
  assert.ok(html.includes(`value="x&quot;&gt;&lt;script"`));
  assert.ok(html.includes("A &amp; B &lt;C&gt;"));
});

test("app.js: import buildVoiceOptions từ lib/voiceOptions.js", () => {
  assert.ok(appJs.includes(`from "./lib/voiceOptions.js"`), "thiếu import voiceOptions");
  assert.ok(appJs.includes("buildVoiceOptions"), "app.js không dùng buildVoiceOptions");
});

test("app.js: điền 2 select giọng ngay lúc khởi động, không chờ tab Giọng", () => {
  // Nhánh init = cuối file, sau lệnh renderLibrary() cuối cùng (không nằm
  // trong renderVoices hay handler của tab). Đây là khoá hồi quy cho lỗi
  // "No Options": nếu ai đó xoá lệnh này, test đỏ.
  const tail = appJs.slice(appJs.lastIndexOf("renderLibrary();"));
  assert.ok(tail.includes("fillVoiceSelects()"), "cuối file app.js phải gọi fillVoiceSelects() lúc khởi động");
  // fillVoiceSelects phải điền CẢ 2 select, không chỉ một.
  assert.ok(appJs.includes(`$("voiceSelect").innerHTML = options`), "không điền voiceSelect");
  assert.ok(appJs.includes(`$("voiceSelectSheet").innerHTML = options`), "không điền voiceSelectSheet");
});

test("app.js: renderVoices dùng chung fillVoiceSelects (không dựng options riêng)", () => {
  const start = appJs.indexOf("async function renderVoices()");
  assert.ok(start >= 0, "không tìm thấy renderVoices");
  const body = appJs.slice(start, appJs.indexOf("async function previewVoice", start));
  assert.ok(body.includes("await fillVoiceSelects()"), "renderVoices phải dùng chung fillVoiceSelects()");
  assert.ok(!body.includes("voiceOptions ="), "renderVoices vẫn còn dựng options riêng — phải dùng chung builder");
});
