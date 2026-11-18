// player.js — Bộ phát nghe sách: tổng hợp từng câu (prefetch 2 câu), highlight
// theo câu, phát nền qua <audio> + Media Session (web) và cầu native (iOS).
// Trong app iOS: giọng VieNeu native. Trên trình duyệt (dev): rơi về giọng hệ thống.

import { prepareForSpeech } from "../text-engine/index.js";

export const native = () => window.Capacitor?.Plugins?.SachNoiBridge ?? null;
export const isNative = () => !!window.Capacitor?.isNativePlatform?.();

export class Player {
  constructor({ onSentence, onState, onProgress } = {}) {
    this.onSentence = onSentence || (() => {});
    this.onState = onState || (() => {});
    this.onProgress = onProgress || (() => {});
    this.audio = new Audio();
    this.audio.preload = "auto";
    this.audio.addEventListener("ended", () => this.handleEnded());
    this.sentences = [];
    this.index = -1;
    this.playing = false;
    this.voice = "default";
    this.speed = 1;
    this.cache = new Map(); // idx -> objectURL (giữ tối đa 6 câu gần nhất)
    this.sleep = null; // {type:'minutes', at:timestamp} | {type:'chapter'}
    this.book = null;
    this._synthSeq = 0;
    // NativePlayer (iOS 1.0.3+): chuỗi phát chạy native -> khoá máy vẫn đọc tiếp.
    // JS chỉ nhận sự kiện để highlight/lưu tiến độ. null = chưa dò, false = không có.
    this.nativePlayer = null;
    this._nativeKey = null;
    // Tuỳ chỉnh âm thanh (1.0.6): âm lượng %, tông giọng (bán âm), khoảng nghỉ
    // sau câu/dấu phẩy/xuống đoạn (giây) — lưu trên máy, áp cho cả 2 đường phát.
    this.audioSettings = Player.loadAudioSettings();
    this.audio.volume = this.audioSettings.volume / 100;
    this._probeNativePlayer();
    this._wireNativeEvents();
  }

  static loadAudioSettings() {
    const defaults = { volume: 100, pitch: 0, gapSentence: 0.25, gapComma: 0, gapParagraph: 0.8 };
    try { return { ...defaults, ...JSON.parse(localStorage.getItem("sachnoi.audioSettings") || "{}") }; }
    catch { return defaults; }
  }

  _nativeAudio() {
    const s = this.audioSettings;
    return { volume: s.volume / 100, pitch: s.pitch * 100, gapSentence: s.gapSentence, gapComma: s.gapComma, gapParagraph: s.gapParagraph };
  }

  setAudioSettings(patch) {
    Object.assign(this.audioSettings, patch);
    try { localStorage.setItem("sachnoi.audioSettings", JSON.stringify(this.audioSettings)); } catch {}
    if (this.audio) this.audio.volume = this.audioSettings.volume / 100;
    const bridge = native();
    if (this.nativePlayer && bridge?.ttsSetAudio) bridge.ttsSetAudio(this._nativeAudio()).catch(() => {});
  }

  _probeNativePlayer() {
    const bridge = native();
    if (!bridge?.getInfo) { this.nativePlayer = false; return; }
    bridge.getInfo()
      .then((info) => { this.nativePlayer = !!info?.nativePlayer; })
      .catch(() => { this.nativePlayer = false; });
  }

  _nativeItems() {
    return this.sentences.map((s) => ({ t: s.spoken, c: s.chapterTitle || "", p: !!s.paraEnd }));
  }

  /** Dựng danh sách câu cho cả sách (theo chương), áp từ điển cá nhân của sách. */
  async load(book, extracted, bookDict = {}) {
    this.stop();
    this.book = { id: book.id, title: extracted.title, author: extracted.author };
    this.sentences = [];
    const total = extracted.chapters.length;
    for (let ci = 0; ci < total; ci++) {
      const ch = extracted.chapters[ci];
      for (const para of ch.paragraphs) {
        const { sentences } = prepareForSpeech(para, { bookDict });
        sentences.forEach((s, si) => this.sentences.push({ ...s, chapterIndex: ci, chapterTitle: ch.title, paraEnd: si === sentences.length - 1 }));
      }
      if (ci % 5 === 0) { this.onProgress(Math.round(((ci + 1) / total) * 100)); await tick(); }
    }
    this.onProgress(100);
    this.index = -1;
    return this.sentences.length;
  }

  async play(fromIndex = null) {
    if (fromIndex !== null) this.index = fromIndex;
    if (this.index < 0) this.index = 0;
    if (this.index >= this.sentences.length) return;
    if (this.nativePlayer) {
      const key = `${this.book?.id || ""}|${this.voice}`;
      const bridge = native();
      this.playing = true;
      this.onState(true);
      if (fromIndex !== null || this._nativeKey !== key) {
        this._nativeKey = key;
        await bridge.ttsPlay({
          items: this._nativeItems(), startIndex: this.index, voice: this.voice,
          title: this.book?.title || "", author: this.book?.author || "",
          audio: this._nativeAudio(),
        }).catch(() => {});
        bridge.ttsSetRate?.({ rate: this.speed }).catch(() => {});
      } else {
        await bridge.ttsResume().catch(() => {});
      }
      return;
    }
    this.playing = true;
    this.onState(true);
    await this.playCurrent();
  }

  pause() {
    this.playing = false;
    this.onState(false);
    if (this.nativePlayer) { native()?.ttsPause?.().catch(() => {}); return; }
    this.audio.pause();
    if (!isNative()) window.speechSynthesis?.pause();
    this.pushNowPlaying();
  }

  async resume() {
    if (this.nativePlayer) {
      if (this._nativeKey) {
        this.playing = true;
        this.onState(true);
        await native()?.ttsResume?.().catch(() => {});
        return;
      }
      return this.play(this.index < 0 ? 0 : null);
    }
    if (this.index < 0) return this.play(0);
    this.playing = true;
    this.onState(true);
    if (this.audio.src && this.audio.currentTime > 0 && !this.audio.ended) {
      await this.audio.play().catch(() => this.playCurrent());
    } else {
      await this.playCurrent();
    }
    this.pushNowPlaying();
  }

  stop() {
    this.playing = false;
    if (this.nativePlayer) { native()?.ttsStopPlayback?.().catch(() => {}); this._nativeKey = null; }
    this._synthSeq++;
    this.audio.pause();
    this.audio.removeAttribute("src");
    if (!isNative()) window.speechSynthesis?.cancel();
    for (const url of this.cache.values()) URL.revokeObjectURL(url);
    this.cache.clear();
    native()?.clearNowPlaying?.().catch(() => {});
    if ("mediaSession" in navigator) navigator.mediaSession.playbackState = "none";
  }

  next() {
    if (this.nativePlayer) { native()?.ttsNext?.().catch(() => {}); return; }
    if (this.index + 1 < this.sentences.length) { this.index++; if (this.playing) this.playCurrent(); else this.onSentence(this.index, this.sentences[this.index]); }
  }
  prev() {
    if (this.nativePlayer) { native()?.ttsPrev?.().catch(() => {}); return; }
    if (this.index > 0) { this.index--; if (this.playing) this.playCurrent(); else this.onSentence(this.index, this.sentences[this.index]); }
  }

  setSpeed(v) {
    this.speed = v;
    this.audio.playbackRate = v;
    if (this.nativePlayer) native()?.ttsSetRate?.({ rate: v }).catch(() => {});
  }

  setVoice(v) {
    this.voice = v;
    this.cache.clear();
    if (this.nativePlayer) { this._nativeKey = null; native()?.ttsSetVoice?.({ voice: v }).catch(() => {}); }
  }

  setSleep(mode, minutes = 0) {
    if (this.nativePlayer) {
      native()?.ttsSetSleep?.({ mode, minutes }).catch(() => {});
    }
    if (mode === "off") this.sleep = null;
    else if (mode === "chapter") this.sleep = { type: "chapter" };
    else this.sleep = { type: "minutes", at: Date.now() + minutes * 60000 };
  }

  async playCurrent() {
    const i = this.index;
    const s = this.sentences[i];
    if (!s) return;
    this.onSentence(i, s);
    this.pushNowPlaying();
    const seq = ++this._synthSeq;
    // Prefetch 2 câu tiếp theo (tổng hợp nền trong lúc phát câu hiện tại)
    this.prefetch(i + 1); this.prefetch(i + 2);
    try {
      const url = await this.synthUrl(i);
      if (seq !== this._synthSeq || !this.playing) return;
      if (url) {
        this.audio.src = url;
        this.audio.playbackRate = this.speed;
        this.audio.volume = this.audioSettings.volume / 100;
        await this.audio.play();
      } else {
        this.speakFallback(s.spoken, seq);
      }
    } catch (e) {
      console.warn("Tổng hợp lỗi, dùng giọng dự phòng:", e);
      if (seq === this._synthSeq && this.playing) this.speakFallback(s.spoken, seq);
    }
  }

  prefetch(i) {
    if (i >= 0 && i < this.sentences.length && !this.cache.has(i)) {
      this.synthUrl(i).catch(() => {});
    }
  }

  async synthUrl(i) {
    if (this.cache.has(i)) return this.cache.get(i);
    const bridge = native();
    if (!bridge?.ttsSynthesize) return null;
    const { base64 } = await bridge.ttsSynthesize({ text: this.sentences[i].spoken, voice: this.voice });
    const bytes = Uint8Array.from(atob(base64), (c) => c.charCodeAt(0));
    const url = URL.createObjectURL(new Blob([bytes], { type: "audio/wav" }));
    this.cache.set(i, url);
    // Giữ cache gọn: chỉ 6 câu quanh vị trí hiện tại
    for (const [k, v] of this.cache) if (Math.abs(k - this.index) > 4) { URL.revokeObjectURL(v); this.cache.delete(k); }
    return url;
  }

  speakFallback(text, seq) {
    if (!("speechSynthesis" in window)) { this.handleEnded(); return; }
    window.speechSynthesis.cancel();
    const u = new SpeechSynthesisUtterance(text);
    u.lang = "vi-VN";
    u.rate = this.speed;
    u.volume = this.audioSettings.volume / 100;
    u.pitch = Math.min(2, Math.max(0.5, Math.pow(2, this.audioSettings.pitch / 12)));
    const v = window.speechSynthesis.getVoices().find((x) => x.lang?.startsWith("vi"));
    if (v) u.voice = v;
    u.onend = () => { if (seq === this._synthSeq) this.handleEnded(); };
    u.onerror = () => { if (seq === this._synthSeq) this.handleEnded(); };
    window.speechSynthesis.speak(u);
  }

  handleEnded() {
    if (!this.playing) return;
    const cur = this.sentences[this.index];
    if (this.sleep?.type === "minutes" && Date.now() >= this.sleep.at) return this.pause();
    if (this.sleep?.type === "chapter") {
      const nxt = this.sentences[this.index + 1];
      if (!nxt || nxt.chapterIndex !== cur.chapterIndex) return this.pause();
    }
    if (this.index + 1 >= this.sentences.length) { this.pause(); this.index = -1; return; }
    this.index++;
    this.playCurrent();
  }

  pushNowPlaying() {
    const s = this.sentences[this.index];
    if (!s || !this.book) return;
    const title = this.book.title, author = this.book.author || "", chapter = s.chapterTitle || "";
    if ("mediaSession" in navigator) {
      navigator.mediaSession.metadata = new MediaMetadata({ title: chapter || title, artist: author || title, album: title });
      navigator.mediaSession.playbackState = this.playing ? "playing" : "paused";
      navigator.mediaSession.setActionHandler("play", () => this.resume());
      navigator.mediaSession.setActionHandler("pause", () => this.pause());
      navigator.mediaSession.setActionHandler("nexttrack", () => this.next());
      navigator.mediaSession.setActionHandler("previoustrack", () => this.prev());
    }
    native()?.setNowPlaying?.({
      title, author, chapter,
      elapsed: this.index, duration: this.sentences.length, isPlaying: this.playing,
    }).catch(() => {});
  }

  _wireNativeEvents() {
    const bridge = native();
    if (!bridge?.addListener) return;
    // Sự kiện của NativePlayer: native tự phát, JS chỉ đồng bộ UI/lưu tiến độ
    bridge.addListener("ttsSentence", ({ index }) => {
      if (!this.nativePlayer) return;
      this.index = index;
      const s = this.sentences[index];
      if (s) this.onSentence(index, s);
    });
    bridge.addListener("ttsState", ({ playing }) => {
      if (!this.nativePlayer) return;
      this.playing = playing;
      this.onState(playing);
    });
    bridge.addListener("ttsEnded", () => {
      if (!this.nativePlayer) return;
      this.playing = false;
      this.onState(false);
    });
    bridge.addListener("remoteCommand", ({ command }) => {
      if (this.nativePlayer) return; // native đã xử lý trực tiếp, UI theo ttsState

      if (command === "play") this.resume();
      else if (command === "pause") this.pause();
      else if (command === "toggle") this.playing ? this.pause() : this.resume();
      else if (command === "next") this.next();
      else if (command === "prev") this.prev();
    });
    bridge.addListener("audioInterruption", ({ phase, shouldResume }) => {
      if (this.nativePlayer) return; // native tự xử lý ngắt quãng
      if (phase === "began") { this._wasPlaying = this.playing; if (this.playing) this.pause(); }
      else if (phase === "ended" && shouldResume && this._wasPlaying) this.resume();
    });
  }
}

const tick = () => new Promise((r) => setTimeout(r, 0));
