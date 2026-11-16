// numbers.js — Đọc số tiếng Việt đúng quy tắc biến âm.
// Quy tắc áp dụng (đã đối chiếu nguồn chuẩn):
// - Hàng đơn vị sau "mươi" (hàng chục >= 2): 1 -> "mốt", 5 -> "lăm", 4 -> "tư" (tuỳ chọn, mặc định tư)
// - Hàng chục = 1 ("mười"): 5 -> "lăm", 1 -> "một", 4 -> "bốn"
// - Hàng chục = 0 và có hàng trăm: đọc "lẻ" (Bắc, mặc định) — 5 giữ "năm", 1 giữ "một"
// - Lớp (nghìn/triệu/tỷ...) toàn 0: bỏ hẳn. Lớp có hàng trăm = 0 nhưng lớp không phải lớp đầu: đọc "không trăm".

const DIGITS = ["không", "một", "hai", "ba", "bốn", "năm", "sáu", "bảy", "tám", "chín"];
const SCALES = ["", "nghìn", "triệu", "tỷ", "nghìn tỷ", "triệu tỷ", "tỷ tỷ"];

/** Đọc 1 lớp 3 chữ số. isFirst: lớp cao nhất của số (không đọc "không trăm"). */
function readGroup(hundreds, tens, units, isFirst, opts) {
  const parts = [];
  if (hundreds > 0) {
    parts.push(DIGITS[hundreds], "trăm");
  } else if (!isFirst) {
    parts.push("không", "trăm");
  }
  if (tens === 0) {
    if (units > 0) {
      if (hundreds > 0 || !isFirst) parts.push("lẻ");
      parts.push(DIGITS[units]);
    }
  } else if (tens === 1) {
    parts.push("mười");
    if (units === 5) parts.push("lăm");
    else if (units > 0) parts.push(DIGITS[units]);
  } else {
    parts.push(DIGITS[tens], "mươi");
    if (units === 1) parts.push("mốt");
    else if (units === 5) parts.push("lăm");
    else if (units === 4) parts.push(opts.tuFor4 === false ? "bốn" : "tư");
    else if (units > 0) parts.push(DIGITS[units]);
  }
  return parts;
}

/** Số nguyên (Number hoặc chuỗi số) -> chữ tiếng Việt. Hỗ trợ số âm. */
export function numberToVietnamese(input, opts = {}) {
  let s = String(input).replace(/[^\d-]/g, "");
  if (s === "" || s === "-") return "";
  let negative = false;
  if (s.startsWith("-")) { negative = true; s = s.slice(1); }
  s = s.replace(/^0+(?=\d)/, "");
  if (s === "0") return negative ? "âm không" : "không";
  const groups = [];
  for (let i = s.length; i > 0; i -= 3) groups.unshift(s.slice(Math.max(0, i - 3), i));
  const words = [];
  groups.forEach((g, idx) => {
    const val = parseInt(g, 10);
    if (val === 0) return; // lớp toàn 0: bỏ hẳn, không đọc tên lớp
    const padded = g.padStart(3, "0");
    const isFirst = idx === 0 || groups.slice(0, idx).every((x) => parseInt(x, 10) === 0);
    const parts = readGroup(+padded[0], +padded[1], +padded[2], isFirst, opts);
    const scale = SCALES[groups.length - 1 - idx];
    if (scale) parts.push(scale);
    words.push(...parts);
  });
  return (negative ? "âm " : "") + words.join(" ");
}

/** Đọc từng chữ số (số điện thoại, mã số): "0903" -> "không chín không ba" */
export function digitsToVietnamese(s) {
  return String(s).split("").filter((c) => /\d/.test(c)).map((c) => DIGITS[+c]).join(" ");
}

const ROMAN_VALUES = { I: 1, V: 5, X: 10, L: 50, C: 100, D: 500, M: 1000 };
export function romanToInt(roman) {
  let total = 0, prev = 0;
  for (let i = roman.length - 1; i >= 0; i--) {
    const v = ROMAN_VALUES[roman[i]];
    if (!v) return NaN;
    total += v < prev ? -v : v;
    prev = Math.max(prev, v);
  }
  return total;
}
export function isRoman(s) {
  return /^[IVXLCDM]{1,7}$/.test(s) && !Number.isNaN(romanToInt(s)) && romanToInt(s) > 0 && romanToInt(s) < 4000;
}

/** Số thứ tự: 1 -> "nhất", 4 -> "tư", còn lại đọc số đếm. */
export function ordinalToVietnamese(n) {
  if (n === 1) return "nhất";
  if (n === 4) return "tư";
  return numberToVietnamese(n);
}
