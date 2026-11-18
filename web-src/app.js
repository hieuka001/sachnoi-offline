// app.js — Điều phối giao diện: thư viện -> đọc -> nghe; giọng; kiểm tra đọc.
import { store, newId, formatBytes } from "./lib/store.js";
import { extractBook, EXTRACT_VERSION } from "./lib/extract.js";
import { Player, native, isNative } from "./lib/player.js";
import { loadManifest, installedPackIds, downloadPack, deletePack } from "./lib/voices.js";
import { buildVoiceOptions } from "./lib/voiceOptions.js";
import { buildBackup, parseBackup } from "./lib/backup.js";
import { computeListeningStats, formatDuration, isFinished } from "./lib/stats.js";
import { filterBooks, sortBooks } from "./lib/library.js";
import { nowPlayingInfo, clampSeekIndex } from "./lib/nowPlaying.js";
import { loadGlobalDict, saveGlobalDict, mergeDicts } from "./lib/dict.js";
import { splitSentences, normalizeForSpeech, prepareForSpeech } from "./text-engine/index.js";

const $ = (id) => document.getElementById(id);
const state = {
  book: null, extracted: null, chapterIndex: 0, manifest: null,
  player: null, sentenceOffset: 0, // chỉ số câu đầu của chương đang xem
};

// ---------- Tabs ----------
document.querySelectorAll(".tab").forEach((btn) => btn.addEventListener("click", () => {
  document.querySelectorAll(".tab").forEach((b) => b.classList.toggle("active", b === btn));
  const tab = btn.dataset.tab;
  $("view-library").classList.toggle("active", tab === "library");
  $("view-history").classList.toggle("active", tab === "history");
  $("view-voices").classList.toggle("active", tab === "voices");
  $("view-lab").classList.toggle("active", tab === "lab");
  $("view-reader").classList.remove("active");
  if (tab === "voices") renderVoices();
  if (tab === "history") renderHistory();
}));

// ---------- Player ----------
state.player = new Player({
  onSentence: (idx, s) => {
    $("playerSentence").textContent = s.original;
    if (!seekDragging) $("seekSlider").value = String(idx);
    if (!npSeeking) $("npSeek").value = String(idx);
    $("playerProgress").textContent = `Câu ${idx + 1} / ${state.player.sentences.length} · ${s.chapterTitle || ""}`;
    refreshNowPlaying(idx, s);
    highlightSentence(idx);
    refreshBmBtn();
    store.setProgress(state.book.id, {
      sentenceIndex: idx,
      totalSentences: state.player.sentences.length,
      chapterTitle: s.chapterTitle || "",
      lastListenedAt: Date.now(),
    }).catch(() => {});
  },
  onState: (playing) => {
    $("playBtn").textContent = playing ? "⏸" : "▶";
    $("npPlayBtn").textContent = playing ? "⏸" : "▶";
  },
  onProgress: (pct) => {
    $("playerProgress").textContent = `Đang chuẩn bị sách… ${pct}%`;
    const st = $("openStatus");
    if (st) st.textContent = `Đang chuẩn bị sách… ${pct}%`;
  },
});
function togglePlay() {
  const p = state.player;
  if (p.playing) p.pause();
  else if (p.index >= 0) p.resume();
  else p.play(state.sentenceOffset || 0);
}
$("playBtn").addEventListener("click", togglePlay);
$("npPlayBtn").addEventListener("click", togglePlay);
$("nextBtn").addEventListener("click", () => state.player.next());
$("npNextBtn").addEventListener("click", () => state.player.next());
$("prevBtn").addEventListener("click", () => state.player.prev());
$("npPrevBtn").addEventListener("click", () => state.player.prev());
$("speedSelect").addEventListener("change", (e) => { state.player.setSpeed(parseFloat(e.target.value)); $("npSpeedSelect").value = e.target.value; markSpeedChips(); });
$("npSpeedSelect").addEventListener("change", (e) => { state.player.setSpeed(parseFloat(e.target.value)); $("speedSelect").value = e.target.value; markSpeedChips(); });
$("sleepSelect").addEventListener("change", (e) => {
  const v = e.target.value;
  if (v === "off") state.player.setSleep("off");
  else if (v === "chapter") state.player.setSleep("chapter");
  else state.player.setSleep("minutes", parseInt(v, 10));
});
$("voiceSelect").addEventListener("change", (e) => { state.player.setVoice(e.target.value); $("voiceSelectSheet").value = e.target.value; });
$("voiceSelectSheet").addEventListener("change", (e) => { state.player.setVoice(e.target.value); $("voiceSelect").value = e.target.value; });

// Khoá cứng thao tác (1.9.0): chặn pinch-zoom và zoom khi chạm 2 ngón — app
// chạy như app thật, không phóng to/tràn viền. Cuộn 1 ngón vẫn bình thường.
document.addEventListener("gesturestart", (e) => e.preventDefault());
document.addEventListener("touchmove", (e) => { if (e.touches.length > 1) e.preventDefault(); }, { passive: false });

// Thanh kéo tiến độ (1.2.0): kéo để nhảy tới câu bất kỳ trong sách
let seekDragging = false;
$("seekSlider").addEventListener("pointerdown", () => { seekDragging = true; });
$("seekSlider").addEventListener("input", () => {
  const s = state.player.sentences[parseInt($("seekSlider").value, 10)];
  if (s) $("playerSentence").textContent = s.original;
});
$("seekSlider").addEventListener("change", () => {
  seekDragging = false;
  if (state.book) state.player.play(parseInt($("seekSlider").value, 10));
});

// ---------- Màn hình Đang nghe toàn màn hình (1.8.0) ----------
let npSeeking = false;
let npCoverUrl = null;
function refreshNowPlaying(idx, s) {
  const p = state.player;
  const info = nowPlayingInfo({
    title: state.book?.title || p.book?.title,
    author: state.book?.author || p.book?.author,
    chapterTitle: s?.chapterTitle || "",
    sentence: s?.original || "—",
    index: idx >= 0 ? idx : p.index,
    total: p.sentences.length,
  });
  $("npTitle").textContent = info.title;
  $("npAuthor").textContent = info.author;
  $("npChapter").textContent = info.chapterTitle;
  $("npSentence").textContent = info.sentence;
  $("npProgress").textContent = `${info.progressText} · ${info.percent}%`;
  $("npSeek").max = String(info.seekMax);
  if (!npSeeking) $("npSeek").value = String(info.seekValue);
  $("npCoverLetter").textContent = info.coverLetter;
}
async function loadNowPlayingCover() {
  if (!state.book) return;
  const blob = await store.getCover(state.book.id).catch(() => null);
  if (npCoverUrl) { URL.revokeObjectURL(npCoverUrl); npCoverUrl = null; }
  if (blob) {
    npCoverUrl = URL.createObjectURL(blob);
    $("npCover").src = npCoverUrl;
    $("npCover").classList.remove("hidden");
    $("npCoverLetter").classList.add("hidden");
  } else {
    $("npCover").classList.add("hidden");
    $("npCoverLetter").classList.remove("hidden");
  }
}
function openNowPlaying() {
  if (!state.book) return;
  refreshNowPlaying(state.player.index, state.player.sentences[state.player.index]);
  $("nowPlaying").classList.remove("hidden");
}
function closeNowPlaying() { $("nowPlaying").classList.add("hidden"); }
$("npOpenBtn").addEventListener("click", openNowPlaying);
$("playerInfo").addEventListener("click", openNowPlaying);
$("npCloseBtn").addEventListener("click", closeNowPlaying);
$("npSeek").addEventListener("pointerdown", () => { npSeeking = true; });
$("npSeek").addEventListener("input", () => {
  const s = state.player.sentences[clampSeekIndex(parseInt($("npSeek").value, 10), state.player.sentences.length)];
  if (s) $("npSentence").textContent = s.original;
});
$("npSeek").addEventListener("change", () => {
  npSeeking = false;
  if (state.book) state.player.play(clampSeekIndex(parseInt($("npSeek").value, 10), state.player.sentences.length));
});
// Tuỳ chỉnh (1.9.0): sheet trượt từ dưới, mở được cả từ màn hình Đang nghe.
function openSheet() {
  markSpeedChips();
  $("sheetOverlay").classList.remove("hidden");
  $("customSheet").classList.remove("hidden");
}
function closeSheet() {
  $("sheetOverlay").classList.add("hidden");
  $("customSheet").classList.add("hidden");
}
$("npAudioBtn").addEventListener("click", openSheet);
$("audioBtn").addEventListener("click", openSheet);
$("sheetClose").addEventListener("click", closeSheet);
$("sheetOverlay").addEventListener("click", closeSheet);
function markSpeedChips() {
  const cur = parseFloat($("speedSelect").value) || 1;
  document.querySelectorAll("#speedChips .chip-btn").forEach((b) =>
    b.classList.toggle("active", parseFloat(b.dataset.speed) === cur));
}
document.querySelectorAll("#speedChips .chip-btn").forEach((b) =>
  b.addEventListener("click", () => {
    $("speedSelect").value = b.dataset.speed;
    $("speedSelect").dispatchEvent(new Event("change"));
  }));

// Panel Âm thanh (1.0.6, chuyển vào sheet 1.9.0): âm lượng / tông / khoảng nghỉ
const audioPanelSyncs = [];
(function initAudioPanel() {
  const s = state.player.audioSettings;
  const bind = (id, valId, key, fmt) => {
    const el = $(id);
    el.value = s[key];
    $(valId).textContent = fmt(s[key]);
    audioPanelSyncs.push(() => { el.value = state.player.audioSettings[key]; $(valId).textContent = fmt(state.player.audioSettings[key]); });
    el.addEventListener("input", () => {
      const v = parseFloat(el.value);
      $(valId).textContent = fmt(v);
      state.player.setAudioSettings({ [key]: v });
    });
  };
  bind("setVolume", "setVolumeVal", "volume", (v) => `${v}%`);
  bind("setPitch", "setPitchVal", "pitch", (v) => (v > 0 ? `+${v}` : `${v}`));
  bind("setGapPunct", "setGapPunctVal", "gapPunct", (v) => `${v.toFixed(2)}s`);
  bind("setGapPara", "setGapParaVal", "gapParagraph", (v) => `${v.toFixed(1)}s`);
})();

// ---------- Thư viện ----------
function progressPct(pr) {
  if (!pr || !pr.totalSentences) return 0;
  return Math.min(100, Math.round(((pr.sentenceIndex + 1) / pr.totalSentences) * 100));
}

async function renderLibrary() {
  const allBooks = await store.listBooks();
  const progressMap = new Map((await store.listProgress()).map((pr) => [pr.bookId, pr]));
  const books = sortBooks(filterBooks(allBooks, libQuery), progressMap, libSort);
  $("emptyLib").style.display = books.length ? "none" : "block";
  $("emptyLib").textContent = allBooks.length
    ? `Không tìm thấy sách nào khớp “${libQuery.trim()}”.`
    : "Chưa có sách nào. Bấm “Thêm sách” để chọn file EPUB, PDF hoặc TXT trên máy — sách chỉ lưu trong máy này.";
  $("bookGrid").innerHTML = books.map((b) => {
    const pr = progressMap.get(b.id);
    const pct = progressPct(pr);
    return `
    <div class="card">
      <div class="book-head">
        <span class="cover cover-letter" data-cover="${b.id}">${escapeHtml((b.title || "?").trim().charAt(0).toUpperCase())}</span>
        <div class="grow">
          <h4>${escapeHtml(b.title)}</h4>
          <p class="muted">${escapeHtml(b.author || "")} ${b.format?.toUpperCase() || ""} · ${b.chapters || "?"} chương/phần</p>
        </div>
      </div>
      ${pr?.totalSentences ? `<progress value="${pct}" max="100" style="width:100%"></progress>
      <p class="muted tnum">Đã nghe ${pct === 0 && pr.sentenceIndex > 0 ? "<1" : pct}% · câu ${pr.sentenceIndex + 1}/${pr.totalSentences}${pr.chapterTitle ? ` · ${escapeHtml(pr.chapterTitle)}` : ""}</p>` : ""}
      <div class="row">
        ${pr?.sentenceIndex > 0 && pct < 100 ? `<button class="btn jade" data-continue="${b.id}">▶ Nghe tiếp</button>` : ""}
        <button class="btn primary" data-open="${b.id}">Đọc & nghe</button>
        <button class="btn danger" data-del="${b.id}">Xoá</button>
      </div>
    </div>`;
  }).join("");
  // Ảnh bìa (1.2.0): nạp bất đồng bộ, có bìa thì thay chữ cái đại diện
  $("bookGrid").querySelectorAll("[data-cover]").forEach(async (el) => {
    const blob = await store.getCover(el.dataset.cover).catch(() => null);
    if (!blob) return;
    const img = document.createElement("img");
    img.className = "cover";
    img.alt = "";
    img.src = URL.createObjectURL(blob);
    el.replaceWith(img);
  });
  $("bookGrid").querySelectorAll("[data-open]").forEach((el) => el.addEventListener("click", () => openBook(el.dataset.open)));
  $("bookGrid").querySelectorAll("[data-continue]").forEach((el) => el.addEventListener("click", () => openBook(el.dataset.continue, true)));
  $("bookGrid").querySelectorAll("[data-del]").forEach((el) => el.addEventListener("click", async () => {
    if (confirm("Xoá sách này khỏi máy?")) { await store.deleteBook(el.dataset.del); renderLibrary(); }
  }));
}

// Tìm kiếm + sắp xếp thư viện (1.5.0): lựa chọn sắp xếp lưu trên máy.
let libQuery = "";
let libSort = "recent";
try {
  const s = localStorage.getItem("sachnoi-lib-sort");
  if (["recent", "title", "progress"].includes(s)) libSort = s;
} catch {}
$("libSort").value = libSort;
$("libSearch").addEventListener("input", (e) => { libQuery = e.target.value; renderLibrary(); });
$("libSort").addEventListener("change", (e) => {
  libSort = e.target.value;
  try { localStorage.setItem("sachnoi-lib-sort", libSort); } catch {}
  renderLibrary();
});

// OCR offline qua cầu native (Apple Vision). Chỉ có trong app iOS; bản web trả null.
function blobToBase64(blob) {
  return new Promise((resolve, reject) => {
    const r = new FileReader();
    r.onload = () => resolve(String(r.result).split(",")[1] || "");
    r.onerror = () => reject(r.error);
    r.readAsDataURL(blob);
  });
}
function makeExtractOpts(statusEl) {
  const bridge = native();
  const ocr = bridge?.ocrImage ? async (blob) => {
    const res = await bridge.ocrImage({ image: await blobToBase64(blob) });
    return res?.text || "";
  } : null;
  return { ocr, onProgress: (_pct, msg) => { if (statusEl && msg) statusEl.textContent = msg; } };
}

$("fileInput").addEventListener("change", async (e) => {
  const file = e.target.files[0];
  if (!file) return;
  $("importStatus").textContent = `Đang đọc file ${file.name}…`;
  try {
    const extracted = await extractBook(file, makeExtractOpts($("importStatus")));
    const coverBlob = extracted.coverBlob || null;
    delete extracted.coverBlob; // bìa lưu ở store riêng, không nhét vào cache trích
    const meta = {
      id: newId(), title: extracted.title, author: extracted.author,
      format: file.name.split(".").pop().toLowerCase(), chapters: extracted.chapters.length,
      scanned: extracted.scanned, addedAt: Date.now(),
    };
    await store.addBook(meta, file);
    if (coverBlob) await store.putCover(meta.id, coverBlob).catch(() => {});
    // Lưu kèm bản đã trích để mở lại không phải trích lại từ đầu
    await store.setProgress(meta.id, { extractedCache: extracted, sentenceIndex: 0 });
    $("importStatus").textContent = extracted.ocr
      ? `Đã thêm “${meta.title}” — sách scan đã nhận dạng chữ (OCR) xong ${extracted.pages} trang, mở sách nghe bình thường.`
      : extracted.scanned
        ? `Đã thêm “${meta.title}” — nhưng đây là sách scan (${extracted.pages} trang, chỉ trích được ${extracted.totalChars ?? 0} ký tự) và OCR chưa chạy được trên máy này; mở sách sẽ thấy phần giải thích.`
        : `Đã thêm “${meta.title}” (${meta.chapters} chương/phần).`;
    renderLibrary();
  } catch (err) {
    $("importStatus").textContent = "Không đọc được file: " + err.message;
  }
  e.target.value = "";
});

// ---------- Sao lưu / khôi phục (1.2.0) ----------
$("backupBtn").addEventListener("click", async () => {
  const st = $("importStatus");
  st.textContent = "Đang tạo bản sao lưu…";
  try {
    const books = await store.listBooks();
    const progressList = await store.listProgress();
    const bookmarksByBook = {}, dictsByBook = {};
    for (const b of books) {
      bookmarksByBook[b.id] = await store.listBookmarks(b.id);
      dictsByBook[b.id] = await store.getBookDict(b.id);
    }
    const backup = buildBackup({ books, progressList, bookmarksByBook, dictsByBook });
    if (!backup.books.length) { st.textContent = "Chưa có sách nào đã trích để sao lưu."; return; }
    const json = JSON.stringify(backup);
    const name = `sachnoi-backup-${new Date().toISOString().slice(0, 10)}.json`;
    const bridge = native();
    if (bridge?.saveFile) {
      await bridge.saveFile({ name, base64: await blobToBase64(new Blob([json], { type: "application/json" })) });
      st.textContent = `Đã tạo sao lưu ${backup.books.length} cuốn${backup.skipped ? ` (bỏ qua ${backup.skipped} cuốn chưa từng mở)` : ""} — chọn nơi lưu trong hộp chia sẻ vừa mở.`;
    } else {
      const a = document.createElement("a");
      a.href = URL.createObjectURL(new Blob([json], { type: "application/json" }));
      a.download = name;
      a.click();
      st.textContent = `Đã tải file sao lưu ${backup.books.length} cuốn.`;
    }
  } catch (err) { st.textContent = "Sao lưu lỗi: " + err.message; }
});
$("restoreInput").addEventListener("change", async (e) => {
  const file = e.target.files[0];
  if (!file) return;
  const st = $("importStatus");
  st.textContent = "Đang khôi phục…";
  try {
    const { books } = parseBackup(await file.text());
    const existing = new Set((await store.listBooks()).map((b) => b.id));
    let restored = 0;
    for (const item of books) {
      let id = item.meta.id;
      if (existing.has(id)) id = newId(); // trùng sách đã có -> thêm như cuốn mới, không ghi đè
      const meta = { ...item.meta, id };
      await store.addBook(meta, null);
      await store.setProgress(id, {
        extractedCache: item.extracted, sentenceIndex: item.progress.sentenceIndex || 0,
        totalSentences: item.progress.totalSentences || 0, chapterTitle: item.progress.chapterTitle || "",
        lastListenedAt: item.progress.lastListenedAt || 0,
      });
      for (const bm of item.bookmarks) await store.putBookmark({ ...bm, id: `${id}:${bm.sentenceIndex}`, bookId: id });
      if (Object.keys(item.dict).length) await store.setBookDict(id, item.dict);
      existing.add(id);
      restored++;
    }
    st.textContent = `Đã khôi phục ${restored} cuốn sách từ bản sao lưu.`;
    renderLibrary();
  } catch (err) { st.textContent = "Khôi phục lỗi: " + err.message; }
  e.target.value = "";
});

// ---------- Đọc ----------
let openingBook = false;
async function openBook(id, autoplay = false) {
  if (openingBook) return;
  openingBook = true;
  const setStatus = (msg) => { const el = $("openStatus"); if (el) el.textContent = msg || ""; };
  try {
    const books = await store.listBooks();
    const meta = books.find((b) => b.id === id);
    if (!meta) return;
    state.book = meta;
    // 1.9.1: chuyển sang màn hình đọc NGAY và hiện trạng thái từng bước.
    // Trước đây trích xuất + dựng câu chạy xong mới chuyển màn hình, lại không
    // có dòng trạng thái nào — mở sách lớn trông y như app treo.
    document.querySelectorAll(".view").forEach((v) => v.classList.remove("active"));
    $("view-reader").classList.add("active");
    $("readerTitle").textContent = meta.title;
    setStatus("Đang mở sách…");
    const progress = await store.getProgress(id);
    let extracted = progress?.extractedCache;
    // Cache trích bằng logic cũ (vd còn bìa/mục lục) -> trích lại từ file gốc.
    // Chỉ số câu toàn cục đã đổi nên tiến độ nghe của sách này quay về đầu.
    const cacheStale = !!extracted && (extracted.extractVersion || 1) !== EXTRACT_VERSION;
    let startSentence = progress?.sentenceIndex || 0;
    if (!extracted || cacheStale) {
      const blob = await store.getBlob(id);
      if (!blob) {
        if (!extracted) { setStatus(""); alert("Không tìm thấy file sách trên máy."); return; }
      } else {
        setStatus("Đang trích xuất sách…");
        extracted = await extractBook(new File([blob], meta.title + "." + meta.format), makeExtractOpts($("openStatus")));
        if (extracted.coverBlob) { await store.putCover(id, extracted.coverBlob).catch(() => {}); delete extracted.coverBlob; }
        if (cacheStale) startSentence = 0;
        await store.setProgress(id, { extractedCache: extracted, sentenceIndex: startSentence });
        if (extracted.chapters.length !== meta.chapters) {
          meta.chapters = extracted.chapters.length;
          await store.updateBook(id, { chapters: extracted.chapters.length });
        }
      }
    }
    state.extracted = extracted;
    $("readerTitle").textContent = extracted.title;
    $("scanWarn").classList.toggle("hidden", !extracted.scanned);
    $("chapterSelect").innerHTML = extracted.chapters.map((c, i) => `<option value="${i}">${escapeHtml(c.title || `Phần ${i + 1}`)}</option>`).join("");
    setStatus("Đang chuẩn bị sách…");
    await state.player.load(meta, extracted, mergeDicts(loadGlobalDict(), await store.getBookDict(id)), progress?.spokenCache);
    // 1.7.0: cache câu đã chuẩn hoá vừa dựng mới (lần mở đầu / từ điển đổi /
    // trích lại) thì lưu lại để lần sau mở nhanh; cache trúng thì khỏi ghi.
    if (state.player.lastSpokenCache && !state.player.spokenCacheHit) {
      await store.setProgress(id, { spokenCache: state.player.lastSpokenCache });
    }
    $("seekSlider").max = String(Math.max(0, state.player.sentences.length - 1));
    $("seekSlider").value = String(Math.max(0, startSentence));
    $("npSeek").max = String(Math.max(0, state.player.sentences.length - 1));
    $("npSeek").value = String(Math.max(0, startSentence));
    loadNowPlayingCover();
    refreshNowPlaying(startSentence > 0 ? startSentence : -1, state.player.sentences[startSentence]);
    state.bookmarks = await store.listBookmarks(id);
    renderBookmarks();
    refreshBmBtn();
    // Tìm chương chứa câu đã nghe dở
    let startChapter = 0;
    for (let i = 0; i < state.player.sentences.length; i++) { if (i === startSentence) { startChapter = state.player.sentences[i].chapterIndex; break; } }
    state.player.index = startSentence > 0 ? startSentence : -1;
    showChapter(startChapter);
    $("playerBar").classList.remove("hidden");
    $("playerTitle").textContent = extracted.title;
    if (startSentence > 0) $("playerProgress").textContent = `Đã nghe tới câu ${startSentence + 1} — bấm ▶ để nghe tiếp.`;
    setStatus("");
    if (autoplay) state.player.play(startSentence);
  } catch (err) {
    // Lỗi phải HIỆN rõ thay vì màn hình chết im lặng như trước
    setStatus("");
    $("readerBody").innerHTML = `<p class="warn">Không mở được sách: ${escapeHtml(err?.message || String(err))}</p>`;
  } finally {
    openingBook = false;
  }
}

// ---------- Lịch sử nghe ----------
async function renderHistory() {
  const books = await store.listBooks();
  const byId = new Map(books.map((b) => [b.id, b]));
  const allProgress = await store.listProgress();
  const items = allProgress
    .filter((pr) => pr.totalSentences && byId.has(pr.bookId))
    .sort((a, b) => (b.lastListenedAt || b.updatedAt || 0) - (a.lastListenedAt || a.updatedAt || 0));
  // Thống kê nghe (1.3.0): tổng câu đã nghe, thời gian ước tính, số sách đã xong
  const speed = parseFloat($("speedSelect").value) || 1;
  const stats = computeListeningStats(allProgress.filter((pr) => byId.has(pr.bookId)), {
    speed, engine: { splitSentences, normalizeForSpeech },
  });
  $("historyStats").innerHTML = stats.booksStarted ? `<div class="card" style="margin-bottom:10px">
    <div class="row between"><h4>Thống kê nghe</h4><span class="chip">ước tính theo tốc độ ${speed}×</span></div>
    <p class="muted tnum">Đã nghe <b>${stats.sentencesListened} câu</b> · khoảng <b>${formatDuration(stats.estimatedSeconds)}</b> · <b>${stats.booksFinished} cuốn</b> đã nghe xong · ${stats.booksInProgress} cuốn đang nghe dở</p>
  </div>` : "";
  $("emptyHistory").style.display = items.length ? "none" : "block";
  $("historyList").innerHTML = items.map((pr) => {
    const b = byId.get(pr.bookId);
    const pct = progressPct(pr);
    const done = isFinished(pr);
    const when = pr.lastListenedAt ? new Date(pr.lastListenedAt).toLocaleString("vi-VN") : "";
    return `<div class="card" style="margin-bottom:10px">
      <div class="row between"><h4>${escapeHtml(b.title)}</h4><span class="chip ${done ? "ok" : ""}">${done ? "✓ Đã nghe xong" : `Đã nghe ${pct === 0 && pr.sentenceIndex > 0 ? "<1" : pct}%`}</span></div>
      <progress value="${pct}" max="100" style="width:100%"></progress>
      <p class="muted tnum">Câu ${pr.sentenceIndex + 1}/${pr.totalSentences}${pr.chapterTitle ? ` · ${escapeHtml(pr.chapterTitle)}` : ""}${when ? ` · Nghe gần nhất: ${when}` : ""}</p>
      <div class="row">
        ${done ? `<button class="btn jade" data-h-replay="${b.id}">↺ Nghe lại từ đầu</button>` : `<button class="btn jade" data-h-continue="${b.id}">▶ Nghe tiếp</button>`}
        <button class="btn" data-h-open="${b.id}">Mở sách</button>
      </div></div>`;
  }).join("");
  $("historyList").querySelectorAll("[data-h-continue]").forEach((el) => el.addEventListener("click", () => openBook(el.dataset.hContinue, true)));
  $("historyList").querySelectorAll("[data-h-replay]").forEach((el) => el.addEventListener("click", async () => {
    await store.setProgress(el.dataset.hReplay, { sentenceIndex: 0 });
    openBook(el.dataset.hReplay, true);
  }));
  $("historyList").querySelectorAll("[data-h-open]").forEach((el) => el.addEventListener("click", () => openBook(el.dataset.hOpen)));
}

function showChapter(ci) {
  state.chapterIndex = ci;
  $("chapterSelect").value = String(ci);
  const ch = state.extracted.chapters[ci];
  // Chỉ số câu bắt đầu của chương này trong danh sách phẳng
  state.sentenceOffset = state.player.sentences.findIndex((s) => s.chapterIndex === ci);
  let globalIdx = state.sentenceOffset;
  const marked = new Set((state.bookmarks || []).map((b) => b.sentenceIndex));
  $("readerBody").innerHTML = ch.paragraphs.map((para) => {
    const sents = splitSentences(para);
    const html = sents.map((s) => {
      const gi = globalIdx++;
      return `<span class="sent${marked.has(gi) ? " marked" : ""}" data-idx="${gi}">${escapeHtml(s)}</span>`;
    }).join(" ");
    return `<p>${html}</p>`;
  }).join("");
  $("readerBody").querySelectorAll(".sent").forEach((el) => {
    el.addEventListener("click", () => state.player.play(parseInt(el.dataset.idx, 10)));
    el.addEventListener("contextmenu", async (ev) => {
      ev.preventDefault();
      const word = window.getSelection()?.toString().trim();
      if (!word) { alert("Bôi đen từ cần sửa cách đọc rồi nhấn giữ lại."); return; }
      const reading = prompt(`Đọc từ “${word}” thành:`);
      if (!reading) return;
      // 1.2.0: chọn phạm vi — mọi sách (từ điển chung) hay chỉ sách này
      const allBooks = confirm(`Áp dụng cách đọc “${reading}” cho từ “${word}” ở:\nOK = MỌI sách\nHuỷ = chỉ sách này`);
      if (allBooks) {
        const g = loadGlobalDict();
        g[word] = reading;
        saveGlobalDict(g);
      } else {
        const dict = await store.getBookDict(state.book.id);
        dict[word] = reading;
        await store.setBookDict(state.book.id, dict);
      }
      await state.player.load(state.book, state.extracted, mergeDicts(loadGlobalDict(), await store.getBookDict(state.book.id)));
      // Từ điển đổi nên cache cũ vô hiệu, load đã dựng cache mới — lưu lại.
      if (state.player.lastSpokenCache) await store.setProgress(state.book.id, { spokenCache: state.player.lastSpokenCache });
      $("seekSlider").max = String(Math.max(0, state.player.sentences.length - 1));
      $("npSeek").max = String(Math.max(0, state.player.sentences.length - 1));
      refreshNowPlaying(state.player.index, state.player.sentences[state.player.index]);
      alert(`Đã nhớ: từ nay “${word}” đọc là “${reading}” ${allBooks ? "trong mọi sách" : "trong sách này"}.`);
    });
  });
  highlightSentence(state.player.index);
}

function highlightSentence(idx) {
  document.querySelectorAll(".sent.current").forEach((e) => e.classList.remove("current"));
  const s = state.player.sentences[idx];
  if (!s) return;
  if (s.chapterIndex !== state.chapterIndex) { showChapter(s.chapterIndex); }
  const el = document.querySelector(`.sent[data-idx="${idx}"]`);
  if (el) { el.classList.add("current"); el.scrollIntoView({ block: "center", behavior: "smooth" }); }
}

$("chapterSelect").addEventListener("change", (e) => showChapter(parseInt(e.target.value, 10)));
$("backBtn").addEventListener("click", () => {
  document.querySelectorAll(".view").forEach((v) => v.classList.remove("active"));
  $("view-library").classList.add("active");
  renderLibrary();
});

// ---------- Dấu trang / tìm trong sách / giao diện đọc (1.1.0) ----------
function currentSentenceIdx() {
  if (state.player.index >= 0) return state.player.index;
  return state.sentenceOffset >= 0 ? state.sentenceOffset : 0;
}
function isBookmarked(idx) { return (state.bookmarks || []).some((b) => b.sentenceIndex === idx); }
function refreshBmBtn() {
  if (!state.book) return;
  $("bmBtn").textContent = isBookmarked(currentSentenceIdx()) ? "Bỏ đánh dấu câu này" : "Đánh dấu câu này";
}
async function renderBookmarks() {
  const list = state.bookmarks || [];
  $("bmCount").textContent = String(list.length);
  $("bmPanel").innerHTML = list.length ? list.map((b) => `
    <div class="hit" data-bm-jump="${b.sentenceIndex}">
      <div class="where">${escapeHtml(b.chapterTitle || "")} · Câu ${b.sentenceIndex + 1}</div>
      <div class="snip">${escapeHtml(b.text)}</div>
      <button class="btn small" data-bm-del="${b.id}">Xoá dấu</button>
    </div>`).join("") : `<p class="muted">Chưa có dấu trang nào trong sách này. Nghe tới câu hay, bấm “Đánh dấu câu này”.</p>`;
  $("bmPanel").querySelectorAll("[data-bm-jump]").forEach((el) => el.addEventListener("click", (ev) => {
    if (ev.target.closest("[data-bm-del]")) return;
    jumpToSentence(parseInt(el.dataset.bmJump, 10));
  }));
  $("bmPanel").querySelectorAll("[data-bm-del]").forEach((el) => el.addEventListener("click", async () => {
    await store.deleteBookmark(el.dataset.bmDel);
    state.bookmarks = await store.listBookmarks(state.book.id);
    renderBookmarks(); refreshBmBtn();
    showChapter(state.chapterIndex);
  }));
}
function jumpToSentence(idx) {
  const s = state.player.sentences[idx];
  if (!s) return;
  $("bmPanel").classList.add("hidden");
  $("searchPanel").classList.add("hidden");
  showChapter(s.chapterIndex);
  state.player.play(idx);
}
$("bmBtn").addEventListener("click", async () => {
  if (!state.book) return;
  const idx = currentSentenceIdx();
  const id = `${state.book.id}:${idx}`;
  if (isBookmarked(idx)) {
    await store.deleteBookmark(id);
  } else {
    const s = state.player.sentences[idx];
    await store.putBookmark({
      id, bookId: state.book.id, sentenceIndex: idx,
      chapterTitle: s?.chapterTitle || "", text: (s?.original || "").slice(0, 140), createdAt: Date.now(),
    });
  }
  state.bookmarks = await store.listBookmarks(state.book.id);
  renderBookmarks(); refreshBmBtn();
  showChapter(state.chapterIndex);
});
$("bmListBtn").addEventListener("click", () => { $("bmPanel").classList.toggle("hidden"); $("searchPanel").classList.add("hidden"); });
$("searchBtn").addEventListener("click", () => { $("searchPanel").classList.toggle("hidden"); $("bmPanel").classList.add("hidden"); $("searchInput").focus(); });

// Tìm không dấu: bỏ dấu tiếng Việt để "dao duc" cũng tìm được "Đạo Đức"
function foldText(s) {
  return String(s || "").normalize("NFD").replace(/[\u0300-\u036f]/g, "").replace(/đ/g, "d").replace(/Đ/g, "D").toLowerCase();
}
function runSearch() {
  const q = foldText($("searchInput").value.trim());
  const box = $("searchResults");
  if (q.length < 2) { box.innerHTML = `<p class="muted">Nhập ít nhất 2 ký tự.</p>`; return; }
  const hits = [];
  let total = 0;
  state.player.sentences.forEach((s, i) => {
    if (foldText(s.original).includes(q)) { total++; if (hits.length < 100) hits.push(i); }
  });
  box.innerHTML = hits.length ? `<p class="muted">${total > hits.length ? `${hits.length}+` : total} kết quả${total > hits.length ? ` (hiện 100 đầu)` : ""} — chạm để nghe từ câu đó:</p>` + hits.map((i) => {
    const s = state.player.sentences[i];
    return `<div class="hit" data-hit="${i}"><div class="where">${escapeHtml(s.chapterTitle || "")} · Câu ${i + 1}</div><div class="snip">${escapeHtml(s.original.slice(0, 160))}</div></div>`;
  }).join("") : `<p class="muted">Không tìm thấy “${escapeHtml($("searchInput").value.trim())}” trong sách này.</p>`;
  box.querySelectorAll("[data-hit]").forEach((el) => el.addEventListener("click", () => jumpToSentence(parseInt(el.dataset.hit, 10))));
}
$("searchGo").addEventListener("click", runSearch);
$("searchInput").addEventListener("keydown", (e) => { if (e.key === "Enter") runSearch(); });

// Cỡ chữ + nền màn hình đọc (lưu trên máy)
const readerPrefs = (() => {
  const d = { fontSize: 18, theme: "dark" };
  try { return { ...d, ...JSON.parse(localStorage.getItem("sachnoi.reader") || "{}") }; } catch { return d; }
})();
const THEMES = [["dark", "Tối"], ["paper", "Giấy"], ["light", "Sáng"]];
function applyReaderPrefs() {
  const rb = $("readerBody");
  rb.style.fontSize = `${readerPrefs.fontSize}px`;
  const fv = $("fontSizeVal");
  if (fv) fv.textContent = String(readerPrefs.fontSize);
  rb.dataset.theme = readerPrefs.theme;
  document.querySelectorAll("#themeChips .chip-btn").forEach((b) =>
    b.classList.toggle("active", b.dataset.theme === readerPrefs.theme));
  try { localStorage.setItem("sachnoi.reader", JSON.stringify(readerPrefs)); } catch {}
}
$("fontMinus").addEventListener("click", () => { readerPrefs.fontSize = Math.max(14, readerPrefs.fontSize - 2); applyReaderPrefs(); });
$("fontPlus").addEventListener("click", () => { readerPrefs.fontSize = Math.min(28, readerPrefs.fontSize + 2); applyReaderPrefs(); });
document.querySelectorAll("#themeChips .chip-btn").forEach((b) =>
  b.addEventListener("click", () => { readerPrefs.theme = b.dataset.theme; applyReaderPrefs(); }));
applyReaderPrefs();

// Đặt lại mặc định (1.9.0): âm thanh + cỡ chữ + nền đọc về giá trị gốc
$("resetSettingsBtn").addEventListener("click", () => {
  state.player.setAudioSettings({ volume: 100, pitch: 0, gapPunct: 0.25, gapParagraph: 0.8 });
  audioPanelSyncs.forEach((f) => f());
  readerPrefs.fontSize = 18;
  readerPrefs.theme = "dark";
  applyReaderPrefs();
});

// ---------- Giọng ----------
// 1.9.3 (P0-A): nạp manifest giọng 1 lần, dùng chung cho khởi động và tab Giọng.
// Trước đây manifest chỉ được nạp trong renderVoices() (khi mở tab Giọng) nên
// cả 2 ô chọn giọng đều trống cho tới lúc đó -> sheet Tuỳ chỉnh hiện "No Options".
async function ensureManifest() {
  if (state.manifest) return state.manifest;
  if (!state.manifestPromise) {
    state.manifestPromise = loadManifest().then(({ manifest, source }) => {
      state.manifest = manifest;
      $("manifestSource").textContent = source === "online" ? "Danh mục mới nhất" : "Danh mục kèm app (đang offline)";
      if (isNative()) native()?.markManifestSeen?.({ version: manifest.version }).catch(() => {});
      return manifest;
    }).catch((err) => { state.manifestPromise = null; throw err; });
  }
  return state.manifestPromise;
}

// Điền options giọng cho cả 2 select (thanh phát + sheet Tuỳ chỉnh) và đặt
// value theo giọng đã lưu — chạy ngay khi khởi động, không chờ mở tab Giọng.
async function fillVoiceSelects() {
  const m = await ensureManifest();
  const options = buildVoiceOptions(m.voices || []);
  $("voiceSelect").innerHTML = options;
  $("voiceSelectSheet").innerHTML = options;
  // 1.9.0: giọng đã lưu không còn trong danh sách thì về mặc định
  if (state.player.voice !== "default" && !(m.voices || []).some((v) => v.id === state.player.voice)) {
    state.player.setVoice("default");
  }
  $("voiceSelect").value = state.player.voice;
  $("voiceSelectSheet").value = state.player.voice;
  return m;
}

async function renderVoices() {
  const m = await fillVoiceSelects();
  const installed = await installedPackIds();
  if (state.coreBundled === undefined && isNative()) {
    try { state.coreBundled = !!(await native().getInfo())?.coreBundled; } catch { state.coreBundled = false; }
  }
  const packHtml = (p) => {
    const isIn = installed.has(p.id);
    const isBundledCore = p.id === "vieneu-turbo-int8" && !!state.coreBundled;
    const size = p.files.reduce((a, f) => a + (f.size || 0), 0);
    return `<div class="card" style="margin-bottom:10px">
      <div class="row between"><h4>${escapeHtml(p.name)}</h4><span class="chip ${isIn || isBundledCore ? "ok" : ""}">${isBundledCore ? "✓ Có sẵn trong app" : isIn ? "✓ Đã tải" : formatBytes(size)}</span></div>
      <p class="muted">${escapeHtml(p.description || "")}</p>
      <progress id="prog-${p.id}" value="0" max="100" class="hidden"></progress>
      <div class="row">
        ${p.status === "coming-soon" ? `<span class="chip">Sắp có</span>`
          : isBundledCore ? (isIn ? `<button class="btn danger" data-del-pack="${p.id}">Xoá bản đã tải (trùng với bản gắn sẵn)</button>` : `<span class="chip ok">Mở app là nghe — không cần tải</span>`)
          : isIn ? `<button class="btn danger" data-del-pack="${p.id}">Xoá gói</button>`
               : `<button class="btn primary" data-dl-pack="${p.id}">Tải về máy</button>`}
      </div></div>`;
  };
  $("packList").innerHTML = (m.packs || []).map(packHtml).join("");
  $("packList").querySelectorAll("[data-dl-pack]").forEach((el) => el.addEventListener("click", async () => {
    const pack = m.packs.find((p) => p.id === el.dataset.dlPack);
    const bar = $(`prog-${pack.id}`);
    bar.classList.remove("hidden");
    el.disabled = true;
    try {
      await downloadPack(pack, (pct) => { bar.value = pct; });
      renderVoices();
    } catch (err) { alert("Tải gói lỗi: " + err.message); el.disabled = false; }
  }));
  $("packList").querySelectorAll("[data-del-pack]").forEach((el) => el.addEventListener("click", async () => {
    const pack = m.packs.find((p) => p.id === el.dataset.delPack);
    if (confirm(`Xoá gói “${pack.name}” khỏi máy?`)) { await deletePack(pack); renderVoices(); }
  }));
  // Giọng VieNeu preset (options của 2 select đã điền trong fillVoiceSelects)
  const voices = m.voices || [];
  $("voiceList").innerHTML = voices.map((v) => `
    <div class="card">
      <h4>${escapeHtml(v.name)} ${v.pick ? '<span class="chip star">★ Đề xuất</span>' : ""}</h4>
      <p class="muted">${escapeHtml(v.region || "")} · ${escapeHtml(v.gender || "")} · ${escapeHtml(v.character || "")}</p>
      <button class="btn small" data-preview="${escapeHtml(v.id)}">▶ Nghe thử</button>
      ${v.sample ? `<audio controls preload="none" src="${escapeHtml(v.sample)}" style="width:100%"></audio>` : ""}
    </div>`).join("");
  $("voiceList").querySelectorAll("[data-preview]").forEach((el) => el.addEventListener("click", () => previewVoice(el)));
}

// Nghe thử giọng (1.2.0): tổng hợp 1 câu mẫu bằng chính giọng đó, phát ngay.
const previewState = { audio: new Audio(), voiceId: null };
async function previewVoice(btn) {
  const voiceId = btn.dataset.preview;
  if (previewState.voiceId === voiceId) { // bấm lại = dừng
    previewState.audio.pause();
    previewState.voiceId = null;
    btn.textContent = "▶ Nghe thử";
    return;
  }
  document.querySelectorAll("[data-preview]").forEach((b) => { b.textContent = "▶ Nghe thử"; });
  previewState.voiceId = voiceId;
  btn.textContent = "⏳ Đang tạo…";
  const sample = "Xin chào, đây là giọng đọc mẫu. Hôm nay chúng ta cùng nghe một cuốn sách thật hay nhé.";
  try {
    const bridge = native();
    if (bridge?.ttsSynthesize) {
      const { base64 } = await bridge.ttsSynthesize({ text: sample, voice: voiceId });
      const bytes = Uint8Array.from(atob(base64), (c) => c.charCodeAt(0));
      previewState.audio.src = URL.createObjectURL(new Blob([bytes], { type: "audio/wav" }));
      await previewState.audio.play();
      btn.textContent = "⏹ Dừng";
      previewState.audio.onended = () => { if (previewState.voiceId === voiceId) { previewState.voiceId = null; btn.textContent = "▶ Nghe thử"; } };
    } else if ("speechSynthesis" in window) {
      const u = new SpeechSynthesisUtterance(sample);
      u.lang = "vi-VN";
      const v = window.speechSynthesis.getVoices().find((x) => x.lang?.startsWith("vi"));
      if (v) u.voice = v;
      u.onend = () => { previewState.voiceId = null; btn.textContent = "▶ Nghe thử"; };
      window.speechSynthesis.speak(u);
      btn.textContent = "⏹ Dừng";
    } else {
      btn.textContent = "▶ Nghe thử";
      previewState.voiceId = null;
    }
  } catch (err) {
    previewState.voiceId = null;
    btn.textContent = "▶ Nghe thử";
    alert("Nghe thử lỗi: " + err.message);
  }
}

// ---------- Kiểm tra đọc / chẩn đoán ----------
$("labRun").addEventListener("click", () => {
  const input = $("labInput").value;
  const { sentences, chunks } = prepareForSpeech(input, { bookDict: loadGlobalDict() });
  $("labOutput").textContent =
    "Câu sau chuẩn hoá:\n" + sentences.map((s) => "• " + s.spoken).join("\n") +
    "\n\nĐoạn tổng hợp gửi vào máy đọc:\n" + chunks.map((c, i) => `${i + 1}. ${c}`).join("\n");
});
$("diagRun").addEventListener("click", async () => {
  const bridge = native();
  if (bridge?.ttsDiagnostics) {
    try { $("diagOutput").textContent = JSON.stringify(await bridge.ttsDiagnostics(), null, 2); }
    catch (e) { $("diagOutput").textContent = "Lỗi chẩn đoán: " + e.message; }
  } else if (bridge?.getInfo) {
    $("diagOutput").textContent = JSON.stringify(await bridge.getInfo(), null, 2);
  } else {
    $("diagOutput").textContent = "Đang chạy trên trình duyệt (không có cầu native) — giọng nghe thử sẽ là giọng hệ thống của trình duyệt. Mở bằng app iOS để dùng giọng VieNeu offline và nghe nền.";
  }
});

function escapeHtml(s) {
  return String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
}

renderLibrary();

// 1.9.3 (P0-A): điền ô chọn giọng ngay khi mở app — trước đây chỉ điền khi
// mở tab Giọng nên sheet Tuỳ chỉnh mở sớm hiện "No Options".
fillVoiceSelects().catch(() => {});
