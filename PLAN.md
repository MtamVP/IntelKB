# IntelKB — Kế hoạch triển khai

Cập nhật sau mỗi giai đoạn. Commit riêng cho từng milestone.

## Ưu tiên hiện hành — 19/10/2026: web trước, không AI

Nguồn lực có hạn: tập trung công cụ nhập liệu chạy trên thiết bị, không cần mô hình AI hay API trả phí. Giữ theme tối hiện tại. Các mục bên dưới là lộ trình mới; những danh sách cũ phía sau giữ lại làm backlog, không phải cam kết đã hoàn thành.

### Đợt 1 — Hộp công cụ cục bộ

- [x] Nút Công cụ và phím Alt+K trên trang thử bàn phím.
- [x] 12 thao tác văn bản: hoa/thường, viết hoa đầu từ/câu, bỏ dấu, NFC, khoảng trắng, xử lý dòng và đánh số.
- [x] Áp dụng cho vùng chọn hoặc cả ô nhập; xem trước, xác nhận áp dụng và dùng chung hoàn tác/làm lại.
- [x] Kho câu thường dùng/đoạn đã lưu: thêm, sửa, ghim, tìm kiếm không dấu, lọc, chèn nguyên văn, bỏ và khôi phục mục vừa bỏ.
- [x] Bảng ký hiệu, thống kê văn bản và tải phần văn bản gốc TXT.
- [x] Sao lưu/nhập JSON kho cá nhân, gộp trùng, kiểm tra giới hạn và lỗi lưu; chặn ghi đè từ tab cũ.

Kho này chỉ nằm trong trình duyệt, tối đa 300 mục; chưa đồng bộ tài khoản và chưa phải phím tắt tự điền cá nhân. Không tự thu thập clipboard. Không thay đổi quyền duyệt từ điển cộng đồng.

### Đợt 2 — Nhập liệu đáng tin cậy

- [ ] Mở rộng kiểm thử Telex, thêm VNI và chế độ không bộ gõ; tách rõ bộ gõ hệ điều hành với bộ gõ ảo.
- [ ] Phím tắt cá nhân có tiền tố rõ ràng (ví dụ /diachi), kiểm tra xung đột và cho hoàn tác tức thì.
- [ ] Bảo vệ URL, email, số, mã nguồn; tránh thay nhầm trong văn bản nhiều ngôn ngữ.
- [ ] Điều hướng con trỏ/vùng chọn, xóa theo từ, giữ phím để lặp; thao tác touch và bàn phím vật lý nhất quán.
- [ ] Lựa chọn cách viết hoa theo ngữ cảnh, ngoại lệ cá nhân, giải thích lý do một từ chưa được tự điền.
- [ ] Bộ kiểm thử hồi quy gõ/dán/IME/vùng chọn/undo/redo; đo độ trễ trên máy yếu và dữ liệu lớn trước khi phát hành.

### Đợt 3 — Dữ liệu là lợi thế cốt lõi

- [ ] Nhập CSV/JSON/JSONL có ánh xạ cột, xem trước, tiếp tục sau lỗi và báo cáo từng dòng.
- [ ] Lịch sử, nguồn, ví dụ dùng, thu hồi công bố, khôi phục và đồng bộ từ bị thu hồi về client.
- [ ] Hàng chờ ưu tiên theo lỗi/trùng/đa nghĩa; thao tác theo cụm với kiểm tra xung đột, nhật ký và hoàn tác.
- [ ] Gói từ điển theo nhu cầu: công việc, học tập, game; tải theo gói, vẫn giữ một nghĩa ưu tiên cho mỗi chế độ.
- [ ] Chống spam đóng góp và kiểm soát tần suất trước khi mở quy mô lớn; không bắt người góp đăng nhập.

### Đợt 4 — Web hoàn chỉnh rồi mới mobile

- [ ] PWA cài từ trình duyệt, tài nguyên ngoại tuyến có phiên bản, cập nhật an toàn và chỉ báo trạng thái đồng bộ.
- [ ] Cấu hình kích thước/phím, một tay, tương phản, cỡ chữ và hỗ trợ trình đọc màn hình.
- [ ] Tách engine nhập liệu thành thư viện độc lập; dùng lại cùng dữ liệu và test giữa web với mobile.
- [ ] Chỉ bắt đầu Android IME sau khi web ổn định; tiếp theo mới đánh giá iOS Keyboard Extension và giới hạn nền tảng.

AI, dịch tự do, sinh câu và nhận dạng giọng nói qua API chưa thuộc các đợt ưu tiên này. Web chỉ thao tác trong ô nhập của IntelKB; muốn gõ xuyên ứng dụng cần bàn phím hệ thống hoặc tích hợp riêng về sau.

---

## Trạng thái tổng quan

| Giai đoạn | Mô tả | Trạng thái |
|-----------|-------|------------|
| P0 | Quản lý và nhập dữ liệu | 🔄 Đang triển khai |
| P1 | Kiểm duyệt hàng loạt | ⏳ Chờ P0 |
| P2 | Nâng cấp bàn phím & hồi quy | ⏳ Chờ P1 |

---

## P0 — Nhập, chỉnh sửa và làm sạch dữ liệu

### P0-A: Trang quản trị dữ liệu (admin data table)

- [ ] Bảng toàn bộ từ vựng với tìm kiếm, lọc trạng thái/nhóm/nguồn/tự bung/đa nghĩa
- [ ] Thêm mới, sửa trực tiếp inline, bổ sung nghĩa, chỉnh nhóm và quyền tự bung
- [ ] Trường ví dụ, giải thích, nguồn tham khảo, ghi chú nội bộ
- [ ] Lịch sử thay đổi: trước/sau, người sửa, thời điểm, lý do
- [ ] Thu hồi công bố (soft-delete / trash) thay vì xóa vĩnh viễn
- [ ] Giữ nội dung đang sửa khi chuyển trang; cảnh báo trước khi rời form chưa lưu

### P0-B: Nhập hàng loạt (bulk import)

- [ ] Nhận CSV, JSON, JSONL hoặc paste từ Excel/Google Sheets
- [ ] File mẫu tải xuống, ánh xạ cột, màn hình xem trước
- [ ] Báo lỗi từng dòng: thiếu nghĩa, sai nhóm, trùng dữ liệu
- [ ] Chuẩn hóa Unicode/chữ hoa/khoảng trắng, phát hiện trùng cả viết tắt lẫn nghĩa
- [ ] Dòng tồn tại → bỏ qua + báo cáo; cùng viết tắt nghĩa khác → ứng viên riêng
- [ ] Mọi dữ liệu nhập → chờ duyệt, không tự công bố; lưu nguồn + quyền sử dụng
- [ ] Giới hạn 10 MB / 10.000 dòng; chia lô 100, hiển thị tiến độ; tiếp tục sau lỗi
- [ ] Xuất CSV/JSONL theo bộ lọc; xuất báo cáo dòng lỗi; CSV safe (chống formula injection)

### P0-C: Database migration cho P0

- [ ] Thêm cột `example`, `explanation`, `source_ref`, `internal_note` vào `intelkb_dictionary`
- [ ] Bảng `intelkb_history` theo dõi thay đổi (before/after JSON, changed_by, changed_at, reason)
- [ ] Hỗ trợ trạng thái `trashed` (thu hồi mềm)
- [ ] RPC `intelkb_admin_upsert`, `intelkb_admin_trash`, `intelkb_admin_restore`
- [ ] RPC `intelkb_bulk_import` — nhận batch JSON, trả kết quả từng dòng
- [ ] RLS và kiểm tra quyền tại database cho tất cả RPC mới

---

## P1 — Kiểm duyệt hàng loạt

### P1-A: Bàn làm việc kiểm duyệt mới

- [ ] Thay thẻ card bằng bảng có checkbox; chọn từng dòng / toàn trang
- [ ] Không tự chọn trang chưa xem
- [ ] Gộp bộ từ khởi tạo + dữ liệu nhập + đóng góp cộng đồng trong một giao diện
- [ ] Xem chi tiết từ: mọi nghĩa liên quan, ví dụ, nguồn, so sánh đề xuất vs bản hiện tại
- [ ] Accept/Reject/gán nhóm/bật-tắt tự bung theo lô; xác nhận trước khi thực thi
- [ ] Từ nhiều nghĩa không tự bật tự bung theo lô
- [ ] Phím tắt duyệt dòng tiếp; lý do từ chối mẫu; ghi nhớ bộ lọc + vị trí

### P1-B: Thống kê và dashboard

- [ ] Số chờ duyệt, đã công bố, bị từ chối, trùng, lỗi nhập

### P1-C: Database migration cho P1

- [ ] RPC `intelkb_bulk_review` — nhận mảng id + quyết định, trả kết quả từng dòng
- [ ] Revision check và transaction riêng cho từng dòng
- [ ] Idempotency: gửi lại không tạo quyết định trùng
- [ ] Hủy giữa lô và thử lại dòng thất bại
- [ ] Khôi phục = revision mới, không ghi đè thay đổi mới hơn

---

## P2 — Nâng cấp bàn phím thử nghiệm

- [ ] Gợi ý và autocomplete ổn định khi DB rỗng / mạng mất / chuyển tab
- [ ] Thu hồi từ → đồng bộ vô hiệu hóa; ngăn bộ mẫu làm sống lại từ đã tắt
- [ ] Xếp hạng gợi ý theo từ đang gõ và lựa chọn thiết bị trước đó
- [ ] Gõ giữa câu, thay vùng chọn, dán nhiều dòng, IME, Telex ảo, hoàn tác/làm lại
- [ ] Tối ưu tìm kiếm khi dữ liệu lớn
- [ ] Khu vực thử câu và đối chiếu chữ gốc/kết quả; báo từ chưa nhận diện; mở nhanh form đóng góp
- [ ] Lịch sử lựa chọn cá nhân chỉ lưu trên thiết bị

---

## Điều kiện hoàn thành chung

- [ ] Test nhập lại cùng file, trùng nguồn, khác dấu/Unicode, cùng viết tắt khác nghĩa
- [ ] Test nhập 10.000 dòng, lỗi giữa lô, thử lại, hủy, tải lại trang
- [ ] Test duyệt hàng loạt, revision cũ, thao tác lặp, hai phiên quản trị cùng sửa
- [ ] Xác minh khách không đọc hàng chờ, không tự công bố, không truy cập thao tác admin
- [ ] Test thu hồi/khôi phục từ, đồng bộ cache, ngăn bộ mẫu làm sống lại từ đã tắt
- [ ] Cập nhật `preview.html` sau mỗi giai đoạn
- [ ] Migration không reset database; giữ nguyên quyết định duyệt đang có

---

## Nhật ký commit

| Ngày | Commit | Nội dung |
|------|--------|----------|
| 2026-10-17 | `33732ab` | Add admin/ folder với URL đẹp |
| 2026-10-17 | `cb8eafc` | Serve web app từ root index.html cho GitHub Pages |
| 2026-10-17 | `612dee6` | Open IntelKB app từ GitHub Pages root |


---

## Tiến độ bổ sung 18/10/2026

## Đã triển khai
- [x] Tab tra cứu và đóng góp riêng, bảng tìm kiếm/lọc/phân trang.
- [x] So trùng theo cặp viết tắt + nghĩa, chuẩn hóa hoa/thường, Unicode và khoảng trắng.
- [x] Xem trước khi nhập, giữ nội dung cục bộ, góp ý trên mục đã có.
- [x] Dán nhiều dòng có kiểm tra lỗi/trùng và báo kết quả từng dòng.
- [x] Bàn kiểm duyệt dạng bảng gọn, khung sửa cạnh bên, lọc và gom cụm.
- [x] Chọn mục/cụm/trang, xem trước rồi duyệt/từ chối theo lô.
- [x] Sửa nghĩa, nhóm, tự bung; phím điều hướng và xuất báo cáo lô.
- [x] RPC quyền admin, kiểm tra revision, kết quả riêng từng mục và nhật ký lô.

## Cần chủ project thiết lập
- [ ] Chạy `supabase/migrations/20261018_review_tools.sql` trên Supabase thật để bật các RPC mới. Không cần xóa hoặc nhập lại dữ liệu.
- [ ] Kiểm tra đăng nhập và lượt duyệt thật bằng tài khoản chủ trang.

## Tiếp theo
- [ ] Nhập file CSV/JSON/JSONL quy mô lớn với ánh xạ cột và tiếp tục sau lỗi.
- [ ] Quản lý toàn bộ dữ liệu: lịch sử phiên bản, thu hồi công bố, thùng rác và khôi phục.
- [ ] Đồng bộ trạng thái vô hiệu hóa để bộ mẫu không làm sống lại từ đã thu hồi.
- [ ] Chống spam theo IP/Turnstile trước khi mở đóng góp quy mô lớn.
- [ ] Tiếp tục kiểm tra và tối ưu bàn phím sau khi hoàn thiện các công cụ dữ liệu.

Giữ quyền công bố cuối cùng cho chủ trang. Đóng góp mới luôn vào hàng chờ; bộ mẫu và nghĩa đã duyệt được ghi nhãn riêng.

## Bổ sung: nghĩa theo chế độ và ba ưu tiên UX

- [x] Tự điền theo nhắn tục / nhắn nhẹ, dùng chung cho gõ và dán.
- [x] Một nghĩa phù hợp được tự chọn; nhiều nghĩa cùng chế độ yêu cầu chủ trang chọn đúng một ưu tiên.
- [x] Kiểm tra nhóm tại database khi duyệt; không tự lấy nghĩa đầu tiên.
- [x] So sánh trước/sau ngay trên dòng và khung chi tiết.
- [x] Duyệt xong tự chuyển mục, giữ vị trí cuộn bảng.
- [x] Hoàn tác lượt duyệt/từ chối/đổi ưu tiên, có kiểm tra thay đổi mới hơn và phiên bản mới.
- [ ] Chủ project chạy `web/dist/review-efficiency-upgrade.sql`, rồi thử bằng tài khoản quản trị thật.

Các đề xuất tiếp theo vẫn là nhập file lớn, quản lý thu hồi từ độc lập, ví dụ/nguồn, biên nhận đóng góp và hàng chờ ưu tiên.
