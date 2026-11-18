// app.js — Điều phối giao diện: thư viện -> đọc -> nghe; giọng; kiểm tra đọc.
import { store, newId, formatBytes } from "./lib/store.js";
import { extractBook, EXTRACT_VERSION } from "./lib/extract.js";
import { Player, native, isNative } from "./lib/player.js";
import { loadManifest, installedPackIds, downloadPack, deletePack } from "./lib/voices.js";
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
    $("playerProgress").textContent = `Câu ${idx + 1} / ${state.player.sentences.length} · ${s.chapterTitle || ""}`;
    highlightSentence(idx);
    refreshBmBtn();
    store.setProgress(state.book.id, {
      sentenceIndex: idx,
      totalSentences: state.player.sentences.length,
      chapterTitle: s.chapterTitle || "",
      lastListenedAt: Date.now(),
    }).catch(() => {});
  },
  onState: (playing) => { $("playBtn").textContent = playing ? "⏸" : "▶"; },
  onProgress: (pct) => { $("playerProgress").textContent = `Đang chuẩn bị sách… ${pct}%`; },
});
$("playBtn").addEventListener("click", () => {
  const p = state.player;
  if (p.playing) p.pause();
  else if (p.index >= 0) p.resume();
  else p.play(state.sentenceOffset || 0);
});
$("nextBtn").addEventListener("click", () => state.player.next());
$("prevBtn").addEventListener("click", () => state.player.prev());
$("speedSelect").addEventListener("change", (e) => { state.player.setSpeed(parseFloat(e.target.value)); });
$("sleepSelect").addEventListener("change", (e) => {
  const v = e.target.value;
  if (v === "off") state.player.setSleep("off");
  else if (v === "chapter") state.player.setSleep("chapter");
  else state.player.setSleep("minutes", parseInt(v, 10));
});
$("voiceSelect").addEventListener("change", (e) => { state.player.setVoice(e.target.value); });

// Panel Âm thanh (1.0.6): âm lượng / tông giọng / khoảng nghỉ
$("audioBtn").addEventListener("click", () => $("audioPanel").classList.toggle("hidden"));
(function initAudioPanel() {
  const s = state.player.audioSettings;
  const bind = (id, valId, key, fmt) => {
    const el = $(id);
    el.value = s[key];
    $(valId).textContent = fmt(s[key]);
    el.addEventListener("input", () => {
      const v = parseFloat(el.value);
      $(valId).textContent = fmt(v);
      state.player.setAudioSettings({ [key]: v });
    });
  };
  bind("setVolume", "setVolumeVal", "volume", (v) => `${v}%`);
  bind("setPitch", "setPitchVal", "pitch", (v) => (v > 0 ? `+${v}` : `${v}`));
  bind("setGapSentence", "setGapSentenceVal", "gapSentence", (v) => `${v.toFixed(2)}s`);
  bind("setGapComma", "setGapCommaVal", "gapComma", (v) => `${v.toFixed(2)}s`);
  bind("setGapPara", "setGapParaVal", "gapParagraph", (v) => `${v.toFixed(1)}s`);
})();

// ---------- Thư viện ----------
function progressPct(pr) {
  if (!pr || !pr.totalSentences) return 0;
  return Math.min(100, Math.round(((pr.sentenceIndex + 1) / pr.totalSentences) * 100));
}

async function renderLibrary() {
  const books = await store.listBooks();
  const progressMap = new Map((await store.listProgress()).map((pr) => [pr.bookId, pr]));
  $("emptyLib").style.display = books.length ? "none" : "block";
  $("bookGrid").innerHTML = books.map((b) => {
    const pr = progressMap.get(b.id);
    const pct = progressPct(pr);
    return `
    <div class="card">
      <h4>${escapeHtml(b.title)}</h4>
      <p class="muted">${escapeHtml(b.author || "")} ${b.format?.toUpperCase() || ""} · ${b.chapters || "?"} chương/phần</p>
      ${pr?.totalSentences ? `<progress value="${pct}" max="100" style="width:100%"></progress>
      <p class="muted tnum">Đã nghe ${pct === 0 && pr.sentenceIndex > 0 ? "<1" : pct}% · câu ${pr.sentenceIndex + 1}/${pr.totalSentences}${pr.chapterTitle ? ` · ${escapeHtml(pr.chapterTitle)}` : ""}</p>` : ""}
      <div class="row">
        ${pr?.sentenceIndex > 0 && pct < 100 ? `<button class="btn jade" data-continue="${b.id}">▶ Nghe tiếp</button>` : ""}
        <button class="btn primary" data-open="${b.id}">Đọc & nghe</button>
        <button class="btn danger" data-del="${b.id}">Xoá</button>
      </div>
    </div>`;
  }).join("");
  $("bookGrid").querySelectorAll("[data-open]").forEach((el) => el.addEventListener("click", () => openBook(el.dataset.open)));
  $("bookGrid").querySelectorAll("[data-continue]").forEach((el) => el.addEventListener("click", () => openBook(el.dataset.continue, true)));
  $("bookGrid").querySelectorAll("[data-del]").forEach((el) => el.addEventListener("click", async () => {
    if (confirm("Xoá sách này khỏi máy?")) { await store.deleteBook(el.dataset.del); renderLibrary(); }
  }));
}

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
    const meta = {
      id: newId(), title: extracted.title, author: extracted.author,
      format: file.name.split(".").pop().toLowerCase(), chapters: extracted.chapters.length,
      scanned: extracted.scanned, addedAt: Date.now(),
    };
    await store.addBook(meta, file);
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

// ---------- Đọc ----------
async function openBook(id, autoplay = false) {
  const books = await store.listBooks();
  const meta = books.find((b) => b.id === id);
  if (!meta) return;
  state.book = meta;
  const progress = await store.getProgress(id);
  let extracted = progress?.extractedCache;
  // Cache trích bằng logic cũ (vd còn bìa/mục lục) -> trích lại từ file gốc.
  // Chỉ số câu toàn cục đã đổi nên tiến độ nghe của sách này quay về đầu.
  const cacheStale = !!extracted && (extracted.extractVersion || 1) !== EXTRACT_VERSION;
  let startSentence = progress?.sentenceIndex || 0;
  if (!extracted || cacheStale) {
    const blob = await store.getBlob(id);
    if (!blob) {
      if (!extracted) { alert("Không tìm thấy file sách trên máy."); return; }
    } else {
      extracted = await extractBook(new File([blob], meta.title + "." + meta.format), makeExtractOpts($("readerTitle")));
      if (cacheStale) startSentence = 0;
      await store.setProgress(id, { extractedCache: extracted, sentenceIndex: startSentence });
      if (extracted.chapters.length !== meta.chapters) {
        meta.chapters = extracted.chapters.length;
        await store.updateBook(id, { chapters: extracted.chapters.length });
      }
    }
  }
  state.extracted = extracted;
  document.querySelectorAll(".view").forEach((v) => v.classList.remove("active"));
  $("view-reader").classList.add("active");
  $("readerTitle").textContent = extracted.title;
  $("scanWarn").classList.toggle("hidden", !extracted.scanned);
  $("chapterSelect").innerHTML = extracted.chapters.map((c, i) => `<option value="${i}">${escapeHtml(c.title || `Phần ${i + 1}`)}</option>`).join("");
  await state.player.load(meta, extracted, await store.getBookDict(id));
  state.bookmarks = await store.listBookmarks(id);
  renderBookmarks();
  refreshBmBtn();
  // Tìm chương chứa câu đã nghe dở
  let acc = 0, startChapter = 0;
  for (let i = 0; i < state.player.sentences.length; i++) { if (i === startSentence) { startChapter = state.player.sentences[i].chapterIndex; break; } }
  state.player.index = startSentence > 0 ? startSentence : -1;
  showChapter(startChapter);
  $("playerBar").classList.remove("hidden");
  $("playerTitle").textContent = extracted.title;
  if (startSentence > 0) $("playerProgress").textContent = `Đã nghe tới câu ${startSentence + 1} — bấm ▶ để nghe tiếp.`;
  if (autoplay) state.player.play(startSentence);
}

// ---------- Lịch sử nghe ----------
async function renderHistory() {
  const books = await store.listBooks();
  const byId = new Map(books.map((b) => [b.id, b]));
  const items = (await store.listProgress())
    .filter((pr) => pr.totalSentences && byId.has(pr.bookId))
    .sort((a, b) => (b.lastListenedAt || b.updatedAt || 0) - (a.lastListenedAt || a.updatedAt || 0));
  $("emptyHistory").style.display = items.length ? "none" : "block";
  $("historyList").innerHTML = items.map((pr) => {
    const b = byId.get(pr.bookId);
    const pct = progressPct(pr);
    const when = pr.lastListenedAt ? new Date(pr.lastListenedAt).toLocaleString("vi-VN") : "";
    return `<div class="card" style="margin-bottom:10px">
      <div class="row between"><h4>${escapeHtml(b.title)}</h4><span class="chip ${pct >= 100 ? "ok" : ""}">${pct >= 100 ? "✓ Đã nghe xong" : `Đã nghe ${pct === 0 && pr.sentenceIndex > 0 ? "<1" : pct}%`}</span></div>
      <progress value="${pct}" max="100" style="width:100%"></progress>
      <p class="muted tnum">Câu ${pr.sentenceIndex + 1}/${pr.totalSentences}${pr.chapterTitle ? ` · ${escapeHtml(pr.chapterTitle)}` : ""}${when ? ` · Nghe gần nhất: ${when}` : ""}</p>
      <div class="row">
        ${pct < 100 ? `<button class="btn jade" data-h-continue="${b.id}">▶ Nghe tiếp</button>` : ""}
        <button class="btn" data-h-open="${b.id}">Mở sách</button>
      </div></div>`;
  }).join("");
  $("historyList").querySelectorAll("[data-h-continue]").forEach((el) => el.addEventListener("click", () => openBook(el.dataset.hContinue, true)));
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
      const dict = await store.getBookDict(state.book.id);
      dict[word] = reading;
      await store.setBookDict(state.book.id, dict);
      await state.player.load(state.book, state.extracted, dict);
      alert(`Đã nhớ: từ nay “${word}” đọc là “${reading}” trong sách này.`);
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
  state.player.sentences.forEach((s, i) => {
    if (hits.length >= 100) return;
    if (foldText(s.original).includes(q)) hits.push(i);
  });
  box.innerHTML = hits.length ? `<p class="muted">${hits.length} kết quả — chạm để nghe từ câu đó:</p>` + hits.map((i) => {
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
  rb.dataset.theme = readerPrefs.theme;
  $("themeBtn").textContent = "Nền: " + (THEMES.find(([k]) => k === readerPrefs.theme)?.[1] || "Tối");
  try { localStorage.setItem("sachnoi.reader", JSON.stringify(readerPrefs)); } catch {}
}
$("fontMinus").addEventListener("click", () => { readerPrefs.fontSize = Math.max(14, readerPrefs.fontSize - 2); applyReaderPrefs(); });
$("fontPlus").addEventListener("click", () => { readerPrefs.fontSize = Math.min(28, readerPrefs.fontSize + 2); applyReaderPrefs(); });
$("themeBtn").addEventListener("click", () => {
  const i = THEMES.findIndex(([k]) => k === readerPrefs.theme);
  readerPrefs.theme = THEMES[(i + 1) % THEMES.length][0];
  applyReaderPrefs();
});
applyReaderPrefs();

// ---------- Giọng ----------
async function renderVoices() {
  if (!state.manifest) {
    const { manifest, source } = await loadManifest();
    state.manifest = manifest;
    $("manifestSource").textContent = source === "online" ? "Danh mục mới nhất" : "Danh mục kèm app (đang offline)";
    if (isNative()) native()?.markManifestSeen?.({ version: manifest.version }).catch(() => {});
  }
  const m = state.manifest;
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
  // Giọng VieNeu preset
  const voices = m.voices || [];
  $("voiceSelect").innerHTML = `<option value="default">Giọng mặc định</option>` +
    voices.map((v) => `<option value="${escapeHtml(v.id)}">${escapeHtml(v.name)}</option>`).join("");
  $("voiceList").innerHTML = voices.map((v) => `
    <div class="card">
      <h4>${escapeHtml(v.name)} ${v.pick ? '<span class="chip star">★ Đề xuất</span>' : ""}</h4>
      <p class="muted">${escapeHtml(v.region || "")} · ${escapeHtml(v.gender || "")} · ${escapeHtml(v.character || "")}</p>
      ${v.sample ? `<audio controls preload="none" src="${escapeHtml(v.sample)}" style="width:100%"></audio>` : ""}
    </div>`).join("");
}

// ---------- Kiểm tra đọc / chẩn đoán ----------
$("labRun").addEventListener("click", () => {
  const input = $("labInput").value;
  const { sentences, chunks } = prepareForSpeech(input);
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
