// segment.js — Lớp 2: chia câu tiếng Việt + đóng gói đoạn tổng hợp.
// Không cắt ở: viết tắt có dấu chấm, số thập phân, ngày tháng, tên viết tắt.

const PROTECTED_DOTS = [
  /\b(PGS|GS|TS|ThS|BS|Dr|Mr|Mrs|Ms|TP|NXB|tr|v\.v|etc|e\.g|i\.e)\./gi, // xử lý bằng placeholder
];

/** Chia văn bản (đã hoặc chưa chuẩn hoá) thành câu, giữ dấu câu cuối. */
export function splitSentences(text) {
  let t = String(text ?? "").replace(/\s+/g, " ").trim();
  if (!t) return [];
  // Bảo vệ dấu chấm không phải cuối câu bằng placeholder \u0001
  t = t.replace(/\b(PGS|GS|TSKH|TS|ThS|BS|Dr|Mr|Mrs|Ms|TP|Q|P|NXB|tr|etc)\.(?=\s|[A-ZÀ-Ỹ])/g, "$1\u0001");
  t = t.replace(/\bv\.v\./g, "v\u0001v\u0001");
  t = t.replace(/(\d)\.(\d)/g, "$1\u0001$2"); // số thập phân / phiên bản / nghìn
  t = t.replace(/(\d),(\d)/g, "$1\u0002$2");
  t = t.replace(/\.\.\./g, "\u0003");
  const raw = t.match(/[^.!?…]+[.!?…]+["”’)]*\s*|[^.!?…]+$/g) || [];
  return raw
    .map((s) => s.replace(/\u0001/g, ".").replace(/\u0002/g, ",").replace(/\u0003/g, "...").trim())
    .filter((s) => s.length > 0);
}

/** Cắt 1 câu quá dài ở biên mệnh đề (, ; — :) rồi biên từ, không cắt giữa cụm số đã chuẩn hoá. */
export function splitLongSentence(sentence, maxChars = 180) {
  if (sentence.length <= maxChars) return [sentence];
  const out = [];
  let rest = sentence;
  while (rest.length > maxChars) {
    let cut = -1;
    const window = rest.slice(0, maxChars + 1);
    for (const sep of ["; ", " — ", ", ", ": "]) {
      const i = window.lastIndexOf(sep);
      if (i > maxChars * 0.4) { cut = i + sep.length; break; }
    }
    if (cut < 0) {
      const i = window.lastIndexOf(" ");
      cut = i > 0 ? i + 1 : maxChars;
    }
    out.push(rest.slice(0, cut).trim());
    rest = rest.slice(cut).trim();
  }
  if (rest) out.push(rest);
  return out;
}

/** Đóng gói câu thành đoạn tổng hợp 120–180 ký tự (mặc định tối đa 180). */
export function chunkSentences(sentences, maxChars = 180) {
  const chunks = [];
  let current = "";
  const push = () => { if (current.trim()) chunks.push(current.trim()); current = ""; };
  for (const s of sentences) {
    for (const piece of splitLongSentence(s, maxChars)) {
      if (!current) current = piece;
      else if ((current + " " + piece).length <= maxChars) current += " " + piece;
      else { push(); current = piece; }
    }
  }
  push();
  return chunks;
}
