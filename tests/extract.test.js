// Test nhận diện bìa / mục lục cho EPUB (extract.js) — heuristic phải bắt được
// mục lục kiểu Đạo Đức Kinh (Nguyễn Hiến Lê) nhưng KHÔNG được nuốt chương thật.
import { test } from "node:test";
import assert from "node:assert/strict";
import { isTocLikeChapter, isCoverLikeChapter, isTocLikeText, EXTRACT_VERSION } from "../web-src/lib/extract.js";

test("extractVersion là số nguyên >= 2", () => {
  assert.ok(Number.isInteger(EXTRACT_VERSION) && EXTRACT_VERSION >= 3);
});

test("mục lục Đạo Đức Kinh (không số trang) bị nhận diện", () => {
  const toc = [
    "Vài lời thưa trước",
    "PHẦN I. ĐỜI SỐNG VÀ TÁC PHẨM",
    "§I. ĐỜI SỐNG",
    "1. Sự tích Lão tử",
    "2. Quê quán",
    "3. Tên họ",
    "4. Tác phẩm Đạo Đức Kinh",
    "§II. TƯ TƯỞNG",
    "1. Vũ trụ quan",
    "2. Nhân sinh quan",
    "PHẦN II. DỊCH NGHĨA",
    "Chương 1",
    "Chương 2",
  ];
  assert.equal(isTocLikeChapter(toc), true);
});

test("mục lục có chấm dẫn + số trang bị nhận diện", () => {
  const toc = [
    "Lời nói đầu .......... 5",
    "Chương một .......... 12",
    "Chương hai .......... 27",
    "Chương ba .......... 41",
    "Chương bốn .......... 58",
    "Chương năm .......... 73",
    "Phụ lục .......... 90",
  ];
  assert.equal(isTocLikeChapter(toc), true);
});

test("chương truyện thật (đoạn văn dài) KHÔNG bị coi là mục lục", () => {
  const prose = [
    "Sáng hôm ấy, trời còn chưa rạng hẳn, sương mù đã phủ kín mặt sông và tiếng gà gáy từ xóm dưới vọng lên từng hồi rời rạc, khiến lão Hạc tỉnh giấc sớm hơn mọi ngày.",
    "Lão ngồi dậy, quờ tay tìm chiếc áo bông đã sờn, khoác lên đôi vai gầy rồi bước ra hiên, nhìn về phía vườn chuối sau nhà mà thở dài một tiếng thật khẽ.",
    "Cậu Vàng nghe tiếng chân quen thuộc thì ngoe nguẩy đuôi chạy lại, dụi đầu vào ống quần của lão, đôi mắt ươn ướt ngước lên như muốn hỏi han điều gì.",
    "Lão cúi xuống vuốt ve bộ lông vàng óng của nó, miệng lẩm bẩm những câu không đầu không cuối, như thể đang trò chuyện với một người bạn tri kỷ lâu năm.",
    "Bữa sáng đạm bạc chỉ có bát cháo loãng với vài hạt muối, lão ăn chậm rãi từng thìa một, mắt vẫn không rời khỏi mảnh vườn nhỏ trước sân nhà mình.",
    "Xong bữa, lão chống gậy ra đồng, bắt đầu một ngày làm việc mới giữa cái nắng hanh hao của những ngày cuối thu đang dần chuyển sang đông giá rét.",
  ];
  assert.equal(isTocLikeChapter(prose), false);
});

test("đối thoại ngắn KHÔNG bị coi là mục lục", () => {
  const dialogue = [
    "— Anh đi đâu đấy?",
    "— Tôi ra chợ một lát.",
    "— Có mua gì không?",
    "— Mua ít rau thôi.",
    "— Ừ, đi sớm về sớm nhé.",
    "— Biết rồi, đừng lo.",
    "— Nhớ mang theo áo mưa.",
    "— Trời nắng thế này mưa sao được.",
  ];
  assert.equal(isTocLikeChapter(dialogue), false);
});

test("ít hơn 5 đoạn thì không kết luận mục lục", () => {
  assert.equal(isTocLikeChapter(["1. Một", "2. Hai", "3. Ba"]), false);
});

test("trang bìa/thông tin xuất bản bị nhận diện", () => {
  const cover = [
    "LÃO TỬ",
    "ĐẠO ĐỨC KINH",
    "Chú dịch và giới thiệu: Nguyễn Hiến Lê",
    "NHÀ XUẤT BẢN VĂN HOÁ - THÔNG TIN",
    "Năm 2006",
  ];
  assert.equal(isCoverLikeChapter(cover), true);
});

test("chương mở đầu thật (đoạn dài) KHÔNG bị coi là bìa", () => {
  const firstChapter = [
    "Đạo khả đạo phi thường đạo. Câu mở đầu nổi tiếng ấy đã làm tốn không biết bao nhiêu giấy mực của các học giả suốt hơn hai nghìn năm qua, và cho đến nay vẫn chưa có một cách hiểu nào được coi là dứt khoát.",
    "Có người dịch là: đạo mà nói ra được thì không còn là đạo vĩnh hằng nữa. Có người lại hiểu theo một nghĩa khác hẳn, thiên về sự bất khả tri của con người trước vũ trụ bao la vô cùng tận này.",
    "Trong bản dịch này, chúng tôi cố gắng giữ sát nguyên văn chữ Hán, đồng thời chú thích những chỗ khó để độc giả tiện theo dõi và đối chiếu với các bản dịch trước đây của nhiều dịch giả uy tín.",
  ];
  assert.equal(isCoverLikeChapter(firstChapter), false);
});


test("mục lục dạng văn xuôi chảy (1 đoạn dồn, kiểu Đạo Đức Kinh) bị nhận diện", () => {
  const flowing = ["MỤC LỤC: Vài lời thưa trước PHẦN I. ĐỜI SỐNG VÀ TÁC PHẨM §I. ĐỜI SỐNG 1. Sự tích Lão tử 2. Quê quán 3. Tên họ 4. Chức tước 5. Lão tử với Khổng tử có gặp nhau không? 6. Lão tử có phải là Lão Lai tử không? 7. Tuổi thọ §II. TÁC PHẨM A. XUẤT HIỆN THỜI NÀO? 1. Về nội dung 2. Về hình thức 3. Dư Bồi Lâm còn đưa ra lí do này nữa B. DO AI VIẾT? C. BẢN LÃO TỬ LƯU HÀNH NGÀY NAY D. CÁC BẢN CHÚ THÍCH PHẦN II. HỌC THUYẾT §I. ĐẠO VÀ ĐỨC A. ĐẠO: BẢN NGUYÊN CỦA VŨ TRỤ B. ĐỨC: SỰ TRƯỞNG THÀNH CỦA VẠN VẬT §II. TÍNH CÁCH VÀ QUI LUẬT CỦA ĐẠO a) Phác b) Tự nhiên c) Luật Phản phục"];
  assert.equal(isTocLikeText(flowing), true);
});

test("chương thật có liệt kê đánh số KHÔNG bị coi là mục lục chảy", () => {
  const chapter = ["Trong chương này chúng ta sẽ điểm qua toàn bộ quá trình hình thành và phát triển của học thuyết, từ những ngày đầu còn phôi thai cho tới khi nó trở thành một hệ thống tư tưởng hoàn chỉnh có ảnh hưởng sâu rộng. 1. Giai đoạn đầu tiên kéo dài rất lâu với nhiều biến động lớn lao của thời cuộc và những tranh luận gay gắt giữa các trường phái đối lập nhau về cả phương pháp lẫn mục đích cuối cùng. 2. Giai đoạn thứ hai chứng kiến sự trưởng thành vượt bậc khi các tác phẩm lớn lần lượt ra đời, đặt nền móng vững chắc cho những thế hệ học giả về sau tiếp tục đào sâu nghiên cứu và phát triển thêm nhiều khía cạnh mới mẻ chưa từng được đề cập tới trước đây trong bất kỳ tài liệu nào."];
  assert.equal(isTocLikeText(chapter), false);
});

test("đoạn văn thường không bị coi là mục lục chảy", () => {
  const prose = ["Đạo khả đạo phi thường đạo, danh khả danh phi thường danh. Vô danh thiên địa chi thủy, hữu danh vạn vật chi mẫu. Cố thường vô dục dĩ quan kỳ diệu, thường hữu dục dĩ quan kỳ kiếu. Thử lưỡng giả đồng xuất nhi dị danh, đồng vị chi huyền, huyền chi hựu huyền, chúng diệu chi môn."];
  assert.equal(isTocLikeText(prose), false);
});
