# IntelKB — từ điển cộng đồng có kiểm duyệt

Người đóng góp không đăng ký/đăng nhập. Họ xem các nghĩa đã công bố, gửi từ mới, thêm nghĩa hoặc đề xuất sửa nghĩa hiện tại. Đóng góp đi vào hàng chờ riêng; chỉ tài khoản quản trị được Accept/Reject. Nội dung chat không được gửi lên database.

## Thiết lập trên project Supabase của bạn

1. Mở SQL Editor, chạy toàn bộ `../web/dist/supabase-setup.sql`. File này gộp migration `migrations/20261017_community_moderation.sql` và 419 mục khởi tạo ở `seeds/initial_dictionary.sql`. Các mục khởi tạo đều là **draft**, không tự coi là đã duyệt. Có thể chạy lại setup mà không ghi đè các quyết định đã duyệt.
2. Trong Authentication → Users, tạo tài khoản riêng của bạn. Tài khoản dùng Supabase Auth, không phải thông tin đăng nhập Dashboard Supabase. Không cần mở đăng ký cho người đóng góp.
3. Sửa `EMAIL_QUAN_TRI` trong `grant-admin.sql` thành email Auth của bạn, rồi chạy file này trong SQL Editor. Đây là bước cấp quyền quản trị; đăng nhập thành công không tự cho phép duyệt.
4. Mở `http://localhost:5050/workbench-ink-7c91.html`, đăng nhập. Nếu dùng Live Server từ repo gốc thì đường dẫn là `/web/dist/workbench-ink-7c91.html`.
5. Chọn Bộ từ khởi tạo để duyệt các mục có sẵn; chọn Đóng góp cộng đồng để duyệt đề xuất của khách. Bạn có thể chỉnh nghĩa, nhóm, quyền tự bung trước khi Accept. Người dùng nhấn Tải lại trong từ điển để nhận nội dung đã duyệt.

Trang công khai không có nút/liên kết đến trang quản trị. Đường dẫn riêng chỉ tránh người dùng mở nhầm, không phải ranh giới bảo mật: dữ liệu hàng chờ và thao tác duyệt đều được SQL kiểm tra quyền. Không cấp quyền dựa vào email/role người dùng tự khai trong frontend hay user_metadata. Không đưa secret/service-role key vào web.

## Mô hình database

- `intelkb_dictionary`: bản chính thức, revision, trạng thái draft/approved/rejected, lịch sử người và thời điểm duyệt. Khách chỉ đọc nội dung approved; không ghi trực tiếp.
- `intelkb_proposals`: từ mới / thêm nghĩa / sửa nghĩa, ví dụ, tên tùy chọn, trạng thái pending/accepted/rejected, ghi chú và người duyệt. Khách không đọc hàng chờ, không insert/update trực tiếp; chỉ gọi RPC nhận đề xuất với trường được cho phép.
- `intelkb_admins`: UUID tài khoản được quyền duyệt. Không cho browser đọc hay ghi danh sách này. Cấp quyền từ SQL Editor.
- RPC nhận đề xuất luôn tạo pending. RPC Accept/Reject yêu cầu admin thật, khóa hàng, kiểm tra revision và cập nhật đề xuất + từ điển trong cùng transaction. Đề xuất sửa dựa trên bản cũ sẽ bị chặn.

## Khi database chưa được thiết lập

Tab tra cứu hiển thị bộ mẫu công khai với nhãn Tham khảo, kết hợp các mục approved từ server và phân biệt rõ trạng thái. Đây không phải quyền đọc draft hay hàng chờ của database. Đóng góp gửi lỗi chỉ nằm ở bản nháp trên trình duyệt, không được báo là đã gửi và không vào bàn phím. Bàn phím giữ bộ mẫu thử đóng gói sẵn và kết hợp nguồn approved từ server để luôn dùng được khi chưa duyệt hết seed. Khi server có bản duyệt cho một trigger, toàn bộ nghĩa mẫu của trigger đó được thay bởi các nghĩa đã duyệt và tuân theo cờ auto_replace. Các đề xuất pending/draft từ database không bao giờ được đưa vào bàn phím. Số nghĩa mẫu và số nghĩa đã duyệt được ghi riêng dưới bàn phím.

Bản nháp và cache phụ thuộc origin. localhost:5050, 127.0.0.1:5050 và cổng 5500 có kho lưu riêng. Bản nháp có nút Gửi lại/Bỏ nháp. Không tự gửi nội dung đang nhập khi mạng trở lại.

## Kiểm thử

Từ thư mục web: `npm install` rồi `npm test`. PGlite là devDependency, chạy PostgreSQL trong bộ nhớ. Kiểm thử thực thi migration và RLS với role anon, authenticated thường và admin, kiểm tra không tự duyệt, không lộ hàng chờ, Accept atomic, chặn sửa bản cũ và không công bố seed draft. Đây là kiểm thử database local; vẫn cần chạy setup và xác minh Auth/RPC trên project Supabase thật.

API công khai có giới hạn độ dài, chống trùng đề xuất pending và receipt để retry. Chưa có Turnstile/rate-limit theo IP; nên bổ sung trước khi mở tiếp nhận ở quy mô lớn.

Migration từ mô hình từ điển cá nhân trước đây vẫn được giữ để bảo toàn lịch sử, nhưng giao diện hiện tại không dùng bảng `intelkb_entries`. Không cần chạy migration cũ để dùng luồng cộng đồng.

## Nâng cấp giao diện nhập và kiểm duyệt (18/10/2026)

Project đã cài đặt trước đây chỉ cần chạy `migrations/20261018_review_tools.sql` một lần trong SQL Editor. Bản sao thuận tiện nằm ở `web/dist/review-tools-upgrade.sql`; không cần xóa bảng, nhập lại seed hay tạo lại Auth. Project mới chạy `web/dist/supabase-setup.sql` đã bao gồm bản nâng cấp này. File nháp P0 cũ không phải điều kiện để dùng các chức năng mới.

- Báo trùng kiểm tra cả viết tắt và nghĩa theo NFC, khoảng trắng và chữ hoa/thường; không bỏ dấu tiếng Việt. Endpoint công khai chỉ trả `none/published/pending` cho đúng cặp được hỏi, không trả nội dung hay danh tính trong hàng chờ.
- Đề xuất trùng cặp đã công bố bị chặn ở database; góp ý sửa cùng mục được phép gửi kèm thay đổi nhóm hoặc giải thích. Gửi lại cùng receipt không tạo đề xuất thứ hai.
- Quản trị có tìm kiếm và lọc toàn bộ hàng chờ, gom cụm theo viết tắt, chọn tối đa 50 mục trong trang, xem trước rồi Accept/Reject theo lô. Mỗi dòng được xử lý riêng và trả kết quả; mục đã duyệt hoặc revision cũ không bị ghi đè.
- Có thể giữ nhóm/tự bung của từng mục hoặc gán nhóm, tắt tự bung cho cả lượt. Lượt duyệt không tự bật tự bung đồng loạt. Nhật ký lô nằm trong `intelkb_review_log`, chỉ admin đọc được.
- Nếu chưa chạy nâng cấp, giao diện vẫn dùng RPC duyệt cũ lần lượt cho các dòng đã chọn và báo cần nâng cấp cho tìm kiếm/thống kê ở server. Kiểm tra trùng tại client vẫn hoạt động; kiểm tra hàng chờ và chống trùng mới ở server cần SQL nâng cấp.

Kiểm tra giao diện quản trị với dữ liệu giả: `python web/tests/manual-review-preview.py`, mở `http://127.0.0.1:8770/workbench-ink-7c91.html`, dùng email bất kỳ hợp lệ và mật khẩu bất kỳ. Server chỉ bind localhost, không kết nối Supabase; đây không phải tài khoản cho website thật. Không triển khai server fixture lên hosting.
