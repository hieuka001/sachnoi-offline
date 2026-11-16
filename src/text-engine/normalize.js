// normalize.js — Lớp 0 (cứu chữ) + Lớp 3 (chuẩn hoá văn bản) của Text Engine.
// Pipeline có thứ tự bắt buộc — xem THIET-KE-FULL.md Phần B. Mọi thay đổi thứ tự
// đều phải qua bộ test vàng (tests/golden.test.js).

import { numberToVietnamese, digitsToVietnamese, romanToInt, isRoman, ordinalToVietnamese } from "./numbers.js";
import { ABBREVIATIONS, TITLE_CHAINS, UNITS, LETTER_NAMES, SPECIAL_TOKENS } from "./dictionaries.js";

const esc = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");

/** Đọc phần thập phân: 1 chữ số -> đọc số đó; bắt đầu bằng 0 -> đọc từng chữ số; còn lại đọc số nguyên. */
function decimalPartWords(part) {
  if (part.length === 1) return numberToVietnamese(part);
  if (part.startsWith("0")) return digitsToVietnamese(part);
  return numberToVietnamese(part);
}

/** Chuyển 1 token số ở mọi dạng VN/Anh (1.250,75 · 1,5 · 1.5 · 1250) thành chữ. */
export function numericTokenToWords(tok) {
  tok = String(tok).trim();
  if (/^\d{1,3}(\.\d{3})+(,\d+)?$/.test(tok)) {
    const [intPart, decPart] = tok.split(",");
    const words = numberToVietnamese(intPart.replace(/\./g, ""));
    return decPart ? `${words} phẩy ${decimalPartWords(decPart)}` : words;
  }
  if (/^\d+,\d+$/.test(tok)) {
    const [a, b] = tok.split(",");
    return `${numberToVietnamese(a)} phẩy ${decimalPartWords(b)}`;
  }
  if (/^\d+\.\d{1,2}$/.test(tok)) {
    const [a, b] = tok.split(".");
    return `${numberToVietnamese(a)} phẩy ${decimalPartWords(b)}`;
  }
  return numberToVietnamese(tok.replace(/\./g, ""));
}

const NUM = String.raw`\d[\d.,]*\d|\d`;

/** Lớp 0 — cứu chữ: Unicode, ligature, ngắt dòng, khoảng trắng quanh dấu câu. */
export function cleanupText(text) {
  let t = String(text ?? "");
  t = t.normalize("NFC");
  t = t.replace(/­/g, ""); // soft hyphen vô hình
  t = t.replace(/ﬁ/g, "fi").replace(/ﬂ/g, "fl");
  // Từ bị ngắt cuối dòng: "chuy- ển" / "chuy-\nển" -> "chuyển" (vế sau bắt đầu chữ thường)
  t = t.replace(/(\p{L})-\s*\n\s*(\p{Ll})/gu, "$1$2");
  t = t.replace(/(\p{L})-\s{1,3}(\p{Ll})/gu, "$1$2");
  // Dòng hội thoại gạch đầu dòng kiểu Việt Nam
  t = t.replace(/^\s*[-–—•·]\s+/gm, "");
  // Khoảng trắng thừa trước dấu câu: "đây , là ." -> "đây, là."
  t = t.replace(/\s+([,.!?;:…%])/g, "$1");
  t = t.replace(/\(\s+/g, "(").replace(/\s+\)/g, ")");
  t = t.replace(/[ \t]+/g, " ");
  t = t.replace(/\n{3,}/g, "\n\n");
  return t.trim();
}

function applyDictionaryOverrides(t, dict) {
  if (!dict) return t;
  const keys = Object.keys(dict).sort((a, b) => b.length - a.length);
  for (const k of keys) {
    t = t.replace(new RegExp(`(?<![\\p{L}\\d])${esc(k)}(?![\\p{L}\\d])`, "gu"), dict[k]);
  }
  return t;
}

/** Lớp 3 — chuẩn hoá toàn bộ: số, ngày giờ, viết tắt, đơn vị, ký hiệu. */
export function normalizeForSpeech(rawText, opts = {}) {
  let t = cleanupText(rawText);
  // Từ điển cá nhân theo sách + gói thể loại áp TRƯỚC mọi rule (Lớp 4/5)
  t = applyDictionaryOverrides(t, opts.genreDict);
  t = applyDictionaryOverrides(t, opts.bookDict);

  // Token đặc biệt cố định (SpO2, H2O...)
  for (const [k, v] of Object.entries(SPECIAL_TOKENS)) {
    t = t.replace(new RegExp(`(?<![\\p{L}\\d])${esc(k)}(?![\\p{L}\\d])`, "gu"), v);
  }
  // Chuỗi học vị "PGS.TS." -> bung trước, nuốt luôn dấu chấm cuối chuỗi
  for (const [k, v] of Object.entries(TITLE_CHAINS)) {
    t = t.replace(new RegExp(`(?<![\\p{L}\\d])${esc(k)}\\.?(?=[\\s,]|$)`, "gu"), v);
  }

  // Viết tắt dính số kiểu COVID-19 -> "COVID mười chín" (trước mọi bước số)
  t = t.replace(/(\p{L})-(\d+)\b/gu, (_, w, n) => `${w} ${numberToVietnamese(n)}`);

  // Số phiên bản 2.0.5 -> "hai chấm không chấm năm"
  t = t.replace(/\b\d+(?:\.\d{1,2}){2,}\b/g, (m) => m.split(".").map((x) => numberToVietnamese(x)).join(" chấm "));

  // Ngày tháng: dd/mm/yyyy · mm/yyyy · tháng La Mã/yyyy
  t = t.replace(/(ngày\s+)?(\d{1,2})[\/.](\d{1,2})[\/.](\d{4})\b/gi, (m0, pre, d, m, y) =>
    `${pre ? "ngày " : "ngày "}${numberToVietnamese(d)} tháng ${numberToVietnamese(m)} năm ${numberToVietnamese(y)}`);
  t = t.replace(/\b([IVXLCDM]{1,4})\/(\d{4})\b/g, (_, r, y) =>
    `tháng ${numberToVietnamese(romanToInt(r))} năm ${numberToVietnamese(y)}`);
  t = t.replace(/(tháng\s+)?(\d{1,2})[\/.](\d{4})\b/gi, (m0, pre, m, y) =>
    `tháng ${numberToVietnamese(m)} năm ${numberToVietnamese(y)}`);

  // Giờ: 15h30 · 10:30 (phút luôn 2 chữ số)
  t = t.replace(/\b(\d{1,2})h(\d{2})\b/g, (_, h, m) =>
    +m === 0 ? `${numberToVietnamese(h)} giờ` : `${numberToVietnamese(h)} giờ ${numberToVietnamese(m)}`);
  t = t.replace(/\b(\d{1,2}):(\d{2})\b/g, (_, h, m) =>
    +m === 0 ? `${numberToVietnamese(h)} giờ` : `${numberToVietnamese(h)} giờ ${numberToVietnamese(m)}`);

  // Huyết áp 120/80 mmHg — trước phân số và đơn vị
  t = t.replace(/\b(\d{2,3})\/(\d{2,3})\s*mmHg\b/g, (_, a, b) =>
    `${numberToVietnamese(a)} trên ${numberToVietnamese(b)} mi li mét thủy ngân`);

  // Số điện thoại: các nhóm cách nhau bằng space/dot, bắt đầu bằng 0
  t = t.replace(/\b0\d{2,3}(?:[ .]\d{3,4}){2}\b/g, (m) =>
    m.split(/[ .]+/).map((g) => digitsToVietnamese(g)).join(", "));
  t = t.replace(/\b0\d{9}\b/g, (m) => digitsToVietnamese(m));

  // Tỉ số thể thao "tỉ số 2-0" — trước khoảng số
  t = t.replace(/(tỉ số|tỷ số)\s*(\d+)\s*[-–]\s*(\d+)/gi, (_, w, a, b) =>
    `${w} ${numberToVietnamese(a)} ${numberToVietnamese(b)}`);
  // Khoảng số: 3–5 · 8–10 · 3 - 5
  t = t.replace(new RegExp(`(${NUM})\\s*[–—]\\s*(${NUM})`, "g"), (_, a, b) =>
    `${numericTokenToWords(a)} đến ${numericTokenToWords(b)}`);
  t = t.replace(new RegExp(`(${NUM})\\s+-\\s+(${NUM})`, "g"), (_, a, b) =>
    `${numericTokenToWords(a)} đến ${numericTokenToWords(b)}`);

  // Phân số 2/3 (ngày tháng và huyết áp đã xử lý ở trên)
  t = t.replace(/\b(\d+)\/(\d+)\b/g, (_, a, b) => `${numberToVietnamese(a)} phần ${numberToVietnamese(b)}`);

  // Phần trăm
  t = t.replace(new RegExp(`(${NUM})\\s*%`, "g"), (_, n) => `${numericTokenToWords(n)} phần trăm`);

  // Số thứ tự: thứ 3 · hạng 1
  t = t.replace(/\b(thứ|hạng)\s+(\d+)\b/gi, (_, w, n) => `${w.toLowerCase()} ${ordinalToVietnamese(+n)}`);
  // Quận/phường + số: Q.2 · P.5
  t = t.replace(/\bQ\.?\s*(\d+)\b/g, (_, n) => `quận ${numberToVietnamese(n)}`);
  t = t.replace(/\bP\.?\s*(\d+)\b/g, (_, n) => `phường ${numberToVietnamese(n)}`);
  // Trang: tr. 12
  t = t.replace(/\btr\.\s*(\d+)\b/gi, (_, n) => `trang ${numberToVietnamese(n)}`);

  // Số nghìn/thập phân/số nguyên còn lại
  t = t.replace(/\b\d{1,3}(?:\.\d{3})+(?:,\d+)?\b/g, (m) => numericTokenToWords(m));
  t = t.replace(/\b\d+,\d+\b/g, (m) => numericTokenToWords(m));
  t = t.replace(/\b\d+\.\d{1,2}\b/g, (m) => numericTokenToWords(m));
  t = t.replace(/\b\d+\b/g, (m) => numberToVietnamese(m));

  // Số La Mã theo ngữ cảnh + đứng độc lập (trước bước đánh vần chữ hoa)
  t = t.replace(/\b(thế kỷ|chương|phần|tập|mục)\s+([IVXLCDM]{1,7})\b/gi, (_, w, r) =>
    isRoman(r.toUpperCase()) ? `${w.toLowerCase()} ${numberToVietnamese(romanToInt(r.toUpperCase()))}` : _);
  t = t.replace(/\b([IVXLCDM]{2,7})\b/g, (m) => (isRoman(m) ? numberToVietnamese(romanToInt(m)) : m));

  // Viết tắt (bỏ qua key 1 ký tự và key đã xử lý riêng: Q, P, tr)
  const abbrKeys = Object.keys(ABBREVIATIONS).filter((k) => k.length > 1 && k !== "tr").sort((a, b) => b.length - a.length);
  for (const k of abbrKeys) {
    if (!k.includes(".")) {
      // Dạng có dấu chấm giữa câu: "TP. Hồ Chí Minh" -> nuốt dấu chấm
      t = t.replace(new RegExp(`(?<![\\p{L}\\d])${esc(k)}\\.(?=\\s+[\\p{L}\\d])`, "gu"), ABBREVIATIONS[k]);
    }
    t = t.replace(new RegExp(`(?<![\\p{L}\\d])${esc(k)}(?![\\p{L}\\d])`, "gu"), ABBREVIATIONS[k]);
  }
  // Viết tắt dính số kiểu COVID-19 -> "covid mười chín" (chữ-gạch-số còn sót)
  t = t.replace(/(\p{L})-(\d[\d\s]*\d|\d)/gu, (_, w, n) => `${w} ${numberToVietnamese(n.replace(/\s/g, ""))}`);

  // Đơn vị đo nhiều ký tự (đơn vị 1 ký tự chỉ mở khi đứng ngay sau số — đã thành chữ nên bỏ qua ở bản 1.0)
  const unitKeys = Object.keys(UNITS).filter((k) => k.length > 1).sort((a, b) => b.length - a.length);
  for (const k of unitKeys) {
    t = t.replace(new RegExp(`\\s*${esc(k)}(?![\\p{L}\\d])`, "gu"), ` ${UNITS[k]}`);
  }
  t = t.replace(/°/g, " độ ");

  // Ký hiệu toán / mũ
  t = t.replace(/([A-Za-zÀ-ỹ])²/gu, (_, c) => `${LETTER_NAMES[c.toLowerCase()] ?? c} bình phương`);
  t = t.replace(/²/g, " bình phương").replace(/³/g, " mũ ba").replace(/√/g, " căn bậc hai của ");
  t = t.replace(/\s\+\s/g, " cộng ").replace(/\s=\s/g, " bằng ")
   .replace(/\s×\s/g, " nhân ").replace(/\s÷\s/g, " chia ");

  // Chữ hoa viết tắt chưa có trong từ điển (2-6 ký tự): đánh vần từng chữ cái
  t = t.replace(/\b[A-ZÀ-Ỹ]{2,6}\b/g, (m) => {
    if (/[À-Ỹ]/.test(m) && !/^[A-Z]+$/.test(m)) return m; // từ Việt viết hoa đầu câu kiểu đặc biệt — giữ nguyên
    return m.split("").map((c) => LETTER_NAMES[c.toLowerCase()] ?? c).join(" ");
  });
  // Công thức hoá học còn sót kiểu NaCl2 / Fe2O3: tách chữ-số đánh vần
  t = t.replace(/\b(?:[A-Z][a-z]?\d*){2,}\b/g, (m) => {
    if (!/\d/.test(m)) return m;
    return m.split("").map((c) => (/\d/.test(c) ? numberToVietnamese(c) : LETTER_NAMES[c.toLowerCase()] ?? c)).join(" ");
  });

  t = t.toLowerCase();
  t = t.replace(/\s+([,.!?;:…])/g, "$1").replace(/[ \t]+/g, " ").replace(/ +([,.!?])\s/g, "$1 ");
  return t.trim();
}
