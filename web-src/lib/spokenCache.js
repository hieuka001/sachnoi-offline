// spokenCache.js — Cache câu đã chuẩn hoá (spoken) để mở sách lớn nhanh.
// player.load() trước đây chạy prepareForSpeech (7 lớp text-engine) trên toàn
// bộ sách mỗi lần mở: đo bằng Node, ~3.800 câu mất ~2,1 giây, trong khi chỉ
// chia câu (cleanup + split) mất 23ms. Cache lưu spoken theo từng đoạn, kèm số
// câu gốc + vị trí câu bị lược (câu chỉ còn dấu câu, chuẩn hoá ra rỗng) để
// khôi phục khớp 1-1 với câu gốc. Cache vô hiệu khi: EXTRACT_VERSION đổi, từ
// điển gộp đổi (dictKey), số đoạn/câu đổi, hoặc cache thiếu/hỏng — khi đó dựng
// lại toàn bộ và trả cache mới. Không import text-engine trực tiếp (web-src
// không có text-engine ở dạng source, chỉ có sau build-web): player.js truyền
// các hàm engine thật vào, test truyền bản từ src/text-engine.

// Tăng khi định dạng cache đổi: cache cũ tự vô hiệu, dựng lại.
export const SPOKEN_CACHE_VERSION = 1;

/** Khoá ổn định của từ điển gộp (không phụ thuộc thứ tự key). */
export function dictKey(dict = {}) {
  const entries = Object.entries(dict || {}).sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0));
  return JSON.stringify(entries);
}

function totalParas(extracted) {
  return (extracted?.chapters || []).reduce((n, ch) => n + (ch.paragraphs?.length || 0), 0);
}

// Đối chiếu theo thứ tự: prepareForSpeech giữ nguyên thứ tự câu gốc, chỉ lược
// câu có spoken rỗng. Trả danh sách chỉ số câu gốc bị lược.
function findDropped(originals, kept) {
  const dropped = [];
  let j = 0;
  for (let i = 0; i < originals.length; i++) {
    if (j < kept.length && kept[j].original === originals[i]) j++;
    else dropped.push(i);
  }
  return dropped;
}

/**
 * Dựng danh sách câu để phát cho cả sách.
 * @param {object} extracted - kết quả extractBook ({chapters: [{title, paragraphs}]})
 * @param {object} bookDict - từ điển gộp (chung + riêng của sách)
 * @param {object|null} cache - cache đã lưu (progress.spokenCache) hoặc null
 * @param {number} extractVersion - EXTRACT_VERSION hiện tại
 * @param {object} engine - { cleanupText, splitSentences, prepareForSpeech }
 * @returns {{ sentences: Array<{original, spoken, chapterIndex, chapterTitle, paraEnd}>, cache: object, hit: boolean }}
 * hit=true khi mọi đoạn đều khôi phục từ cache (không chạy chuẩn hoá lần nào).
 */
export function buildBookSentences(extracted, bookDict = {}, cache = null, extractVersion = 0, engine) {
  const { cleanupText, splitSentences, prepareForSpeech } = engine;
  const dk = dictKey(bookDict);
  const cacheOk =
    !!cache &&
    cache.v === SPOKEN_CACHE_VERSION &&
    cache.ev === extractVersion &&
    cache.dk === dk &&
    Array.isArray(cache.paras) &&
    cache.paras.length === totalParas(extracted);
  const sentences = [];
  const paras = [];
  let hit = cacheOk;
  let pi = 0;
  for (let ci = 0; ci < (extracted?.chapters || []).length; ci++) {
    const ch = extracted.chapters[ci];
    for (const para of ch.paragraphs || []) {
      const originals = splitSentences(cleanupText(para));
      const saved = cacheOk ? cache.paras[pi] : null;
      let spokenList = null;
      let dropped = [];
      if (
        saved &&
        saved.o === originals.length &&
        Array.isArray(saved.s) &&
        Array.isArray(saved.d) &&
        saved.s.length === originals.length - saved.d.length &&
        saved.d.length === new Set(saved.d).size &&
        saved.d.every((i) => Number.isInteger(i) && i >= 0 && i < originals.length)
      ) {
        spokenList = saved.s;
        dropped = saved.d;
      }
      const startIdx = sentences.length;
      if (spokenList) {
        const droppedSet = new Set(dropped);
        let si = 0;
        originals.forEach((original, oi) => {
          if (droppedSet.has(oi)) return;
          sentences.push({ original, spoken: spokenList[si++], chapterIndex: ci, chapterTitle: ch.title, paraEnd: false });
        });
        paras.push({ o: originals.length, s: spokenList, d: dropped });
      } else {
        hit = false;
        const { sentences: prepared } = prepareForSpeech(para, { bookDict });
        const droppedNow = findDropped(originals, prepared);
        for (const s of prepared) {
          sentences.push({ ...s, chapterIndex: ci, chapterTitle: ch.title, paraEnd: false });
        }
        paras.push({ o: originals.length, s: prepared.map((s) => s.spoken), d: droppedNow });
      }
      if (sentences.length > startIdx) sentences[sentences.length - 1].paraEnd = true;
      pi++;
    }
  }
  return {
    sentences,
    cache: { v: SPOKEN_CACHE_VERSION, ev: extractVersion, dk, paras },
    hit,
  };
}
