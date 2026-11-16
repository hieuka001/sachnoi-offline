// index.js — API công khai của Text Engine.
// Pipeline đầy đủ: Lớp 0 cleanup -> Lớp 2 chia câu (trên text gốc)
// -> Lớp 3 chuẩn hoá từng câu -> đóng gói đoạn tổng hợp cho TTS.

import { cleanupText, normalizeForSpeech } from "./normalize.js";
import { splitSentences, chunkSentences } from "./segment.js";

export { cleanupText, normalizeForSpeech } from "./normalize.js";
export { splitSentences, chunkSentences, splitLongSentence } from "./segment.js";
export { numberToVietnamese, digitsToVietnamese, romanToInt } from "./numbers.js";

/**
 * Chuẩn bị 1 đoạn văn để đọc:
 * @returns {{ sentences: Array<{original: string, spoken: string}>, chunks: string[] }}
 * sentences giữ cặp gốc/chuẩn hoá để reader highlight đúng câu và màn Chẩn đoán đối chiếu được.
 */
export function prepareForSpeech(text, opts = {}) {
  const cleaned = cleanupText(text);
  const originals = splitSentences(cleaned);
  const sentences = originals.map((original) => ({
    original,
    spoken: normalizeForSpeech(original, opts),
  })).filter((s) => s.spoken.length > 0);
  const chunks = chunkSentences(sentences.map((s) => s.spoken), opts.maxChunkChars ?? 180);
  return { sentences, chunks };
}
