// stats.js — Thống kê nghe cho tab Lịch sử (1.3.0). Thuần logic, không chạm DOM/IndexedDB.
// Thời gian nghe là ƯỚC TÍNH: tổng độ dài câu đã nói / tốc độ đọc, tính theo tốc
// độ đang chọn. Câu nào có bản trích trong máy thì đo đúng độ dài câu nói
// (normalizeForSpeech); không có bản trích thì tính theo trung bình.

// Tốc độ đọc tiếng Việt tự nhiên ≈ 150 từ/phút ≈ 13–15 ký tự/giây ở tốc độ 1×.
export const CHARS_PER_SECOND = 14;
// Độ dài trung bình một câu tiếng Việt (dùng khi không có bản trích để đo thật).
export const AVG_CHARS_PER_SENTENCE = 65;

// Sách được tính là "đã nghe xong" khi đã nghe tới câu cuối cùng.
export function isFinished(pr) {
  if (!pr || !pr.totalSentences) return false;
  return (pr.sentenceIndex || 0) + 1 >= pr.totalSentences;
}

// Số câu thực sự đã nghe của một bản ghi tiến độ. sentenceIndex = 0 lúc mới nhập
// sách chưa tính là đã nghe — chỉ tính khi có lastListenedAt (đã bấm nghe thật).
export function listenedCount(pr) {
  if (!pr || !pr.totalSentences || !pr.lastListenedAt) return 0;
  return Math.min((pr.sentenceIndex || 0) + 1, pr.totalSentences);
}

// Tổng độ dài (ký tự) của `listened` câu đầu trong bản trích. engine là
// { splitSentences, normalizeForSpeech } từ text-engine — truyền vào để module
// này không phụ thuộc đường dẫn build (web-src dùng ./text-engine, test dùng src/).
// Không có bản trích / thiếu câu thì phần thiếu tính theo trung bình.
export function listenedChars(extracted, listened, engine) {
  if (!listened) return 0;
  if (!extracted?.chapters?.length || !engine?.splitSentences || !engine?.normalizeForSpeech) {
    return listened * AVG_CHARS_PER_SENTENCE;
  }
  let chars = 0, n = 0;
  outer: for (const ch of extracted.chapters) {
    for (const para of ch.paragraphs || []) {
      for (const s of engine.splitSentences(para)) {
        if (n >= listened) break outer;
        chars += engine.normalizeForSpeech(s).length;
        n++;
      }
    }
  }
  if (n < listened) chars += (listened - n) * AVG_CHARS_PER_SENTENCE;
  return chars;
}

// Tổng hợp toàn bộ thư viện. opts: { speed = 1 (tốc độ đang chọn), engine? }.
// Trả: { booksStarted, sentencesListened, booksFinished, booksInProgress,
//         totalChars, estimatedSeconds }.
export function computeListeningStats(progressList, opts = {}) {
  const speed = opts.speed > 0 ? opts.speed : 1;
  let booksStarted = 0, sentencesListened = 0, booksFinished = 0, totalChars = 0;
  for (const pr of progressList || []) {
    const listened = listenedCount(pr);
    if (!listened) continue;
    booksStarted++;
    sentencesListened += listened;
    totalChars += listenedChars(pr.extractedCache, listened, opts.engine);
    if (isFinished(pr)) booksFinished++;
  }
  return {
    booksStarted,
    sentencesListened,
    booksFinished,
    booksInProgress: booksStarted - booksFinished,
    totalChars,
    estimatedSeconds: totalChars / (CHARS_PER_SECOND * speed),
  };
}

// "45 giây" / "12 phút" / "2 giờ 15 phút" / "1 giờ".
export function formatDuration(totalSeconds) {
  const s = Math.max(0, Math.round(totalSeconds || 0));
  if (s < 60) return `${s} giây`;
  const m = Math.floor(s / 60);
  if (m < 60) return `${m} phút`;
  const h = Math.floor(m / 60), rem = m % 60;
  return rem ? `${h} giờ ${rem} phút` : `${h} giờ`;
}
