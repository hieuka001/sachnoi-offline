# Sách Nói Offline

App đọc sách **PDF / EPUB / TXT** hoàn toàn **offline**, đọc bằng giọng **VieNeu tiếng Việt**
chạy ngay trên máy. App cài mới rất nhẹ (không kèm model) — muốn dùng bộ đọc/giọng nào
thì bấm tải gói đó từ **GitHub Releases** của chính repo này, tải xong là nghe offline mãi.

Thiết kế đầy đủ: [THIET-KE-FULL.md](THIET-KE-FULL.md) · Kế hoạch gốc: [KE-HOACH.md](KE-HOACH.md)

## Điểm chính
- **Text Engine tiếng Việt 7 lớp** (`src/text-engine/`): cứu chữ (Unicode NFC, nối từ ngắt dòng),
  chia câu không cắt nhầm viết tắt/số, chuẩn hoá số–ngày–viết tắt–đơn vị đúng quy tắc tiếng Việt
  (mốt/tư/lăm/lẻ, bẫy chấm nghìn & phẩy thập phân), từ điển cá nhân theo từng cuốn sách.
  Bộ test vàng: `text-engine/golden-v1-starter.json` — chạy `npm test` (sai 1 câu là đỏ).
- **Giọng tải theo nhu cầu**: danh mục ở `voices/voices.json` (25 giọng VieNeu Bắc/Trung/Nam).
  Gói Core int8 (~261MB, SHA-256 từng file trong manifest) đăng ở GitHub Releases,
  app tải bằng phiên tải nền iOS, kiểm toàn vẹn rồi mới kích hoạt.
- **iOS chạy nền đầy đủ** (xem dưới).

## Chạy nền trên iOS (`plugins/sachnoi-bridge` + `ios/App`)
1. **Nghe nền**: `UIBackgroundModes: [audio, processing]`, AVAudioSession `.playback/.spokenAudio`
   — khoá màn hình/chuyển app vẫn đọc tiếp.
2. **Màn hình khoá & tai nghe**: MPNowPlayingInfoCenter + MPRemoteCommandCenter
   (play/pause/câu trước/câu sau), xử lý ngắt quãng (cuộc gọi, Siri) và rút tai nghe.
3. **Tải nền**: URLSession background — bấm tải gói rồi khoá máy, iOS tải tiếp và mở lại app khi xong;
   tiến độ/hoàn tất/verify SHA-256 báo về giao diện.
4. **Tác vụ nền theo lịch**: BGProcessingTask (kiểm tra gói + nạp ấm engine) và
   BGAppRefreshTask (kiểm tra danh mục giọng mới).

## Phát triển
```bash
npm install
npm test              # test vàng + engine
npm run check:manifest
npm run build:web     # đóng gói web/ (mọi thư viện đóng kèm, không CDN)
npm run sync:ios      # build web + cap sync ios
```
Build IPA unsigned (cài qua ESign): GitHub Actions → workflow **Build unsigned IPA**
(macos-15, có bước chặn nếu IPA chứa model — app phải nhẹ).

Đăng gói Core lên Releases (sau khi tạo repo):
```bash
ASSETS_DIR=<thư mục 12 file assets VieNeu> tools/upload-core-release.sh
```

## Trạng thái
- Text Engine v1: 45/45 test đạt (40 câu vàng + 5 test engine).
- Web app: thư viện offline (IndexedDB), đọc EPUB/PDF/TXT, player highlight theo câu,
  quản lý gói/giọng, màn Kiểm tra đọc + Chẩn đoán.
- iOS: vỏ Capacitor 6 + plugin native (engine VieNeu dùng lại bản đã kiểm chứng ở Bút Nghiên,
  đổi sang nạp assets từ gói đã tải). IPA đầu tiên build qua CI — cần chạy workflow trên GitHub
  sau khi đẩy repo lên; nghe nền/tải nền chỉ kiểm chứng được trên iPhone thật.
- Icon/splash hiện tạm dùng của Bút Nghiên — thay trước khi phát hành.
