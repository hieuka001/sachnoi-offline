// assets.test.js — Icon + splash riêng của Sách Nói Offline (không còn
// placeholder Bút Nghiên). Chạy: npm test
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, existsSync } from "node:fs";
import { createHash } from "node:crypto";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, "..");
const iconPath = join(root, "ios/App/App/Assets.xcassets/AppIcon.appiconset/AppIcon-512@2x.png");
const splashDir = join(root, "ios/App/App/Assets.xcassets/Splash.imageset");
const splashFiles = ["splash-2732x2732.png", "splash-2732x2732-1.png", "splash-2732x2732-2.png"];

// Hash SHA-256 của ảnh placeholder Bút Nghiên cũ — nếu ai đó vô tình
// khôi phục lại ảnh cũ thì test này đỏ.
const OLD_ICON_HASH = "3190081c191f66fb356055e9e552859357d13f936e4c16d79cc36b897279155e";
const OLD_SPLASH_HASH = "e3e29a130b8c31819ffde9e2ab27bffac7f45baa41d6a2e3a5f943230ab79c19";

// Đọc kích thước PNG từ chunk IHDR (không cần thư viện ngoài).
function pngSize(buf) {
  assert.equal(buf.subarray(0, 8).toString("hex"), "89504e470d0a1a0a", "không phải file PNG");
  assert.equal(buf.subarray(12, 16).toString("ascii"), "IHDR", "thiếu chunk IHDR");
  return { width: buf.readUInt32BE(16), height: buf.readUInt32BE(20), colorType: buf[25] };
}

function sha256(buf) {
  return createHash("sha256").update(buf).digest("hex");
}

test("AppIcon tồn tại, 1024x1024, RGB (không alpha), không phải placeholder cũ", () => {
  assert.ok(existsSync(iconPath), "thiếu AppIcon-512@2x.png");
  const buf = readFileSync(iconPath);
  const { width, height, colorType } = pngSize(buf);
  assert.equal(width, 1024);
  assert.equal(height, 1024);
  assert.equal(colorType, 2, "icon iOS phải là RGB (colorType 2), không alpha");
  assert.notEqual(sha256(buf), OLD_ICON_HASH, "icon vẫn là placeholder Bút Nghiên cũ");
  assert.ok(buf.length > 50000, "icon quá nhỏ, có thể là ảnh rỗng/hỏng");
});

for (const f of splashFiles) {
  test(`Splash ${f} tồn tại, 2732x2732, không phải placeholder cũ`, () => {
    const p = join(splashDir, f);
    assert.ok(existsSync(p), `thiếu ${f}`);
    const buf = readFileSync(p);
    const { width, height } = pngSize(buf);
    assert.equal(width, 2732);
    assert.equal(height, 2732);
    assert.notEqual(sha256(buf), OLD_SPLASH_HASH, "splash vẫn là placeholder Bút Nghiên cũ");
    assert.ok(buf.length > 100000, "splash quá nhỏ, có thể là ảnh rỗng/hỏng");
  });
}

test("Contents.json của AppIcon và Splash vẫn trỏ đúng tên file", () => {
  const iconJson = JSON.parse(readFileSync(join(root, "ios/App/App/Assets.xcassets/AppIcon.appiconset/Contents.json"), "utf8"));
  assert.equal(iconJson.images[0].filename, "AppIcon-512@2x.png");
  assert.equal(iconJson.images[0].size, "1024x1024");
  const splashJson = JSON.parse(readFileSync(join(splashDir, "Contents.json"), "utf8"));
  const names = splashJson.images.map((i) => i.filename).sort();
  assert.deepEqual(names, [...splashFiles].sort());
});
