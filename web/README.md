# IntelKB playground

Giao diện mô phỏng bàn phím: phím ảo sáng khi nhấn, gợi ý theo con trỏ, bung nhiều từ liên tiếp, Bung cả câu, hoàn tác, Nói thẳng/Nói nhẹ. Gõ bằng bàn phím thật hoặc phím ảo; Telex ảo mới hỗ trợ các tổ hợp phổ biến, chưa phải bộ gõ đầy đủ.

## Autocomplete

- Mặc định bật tự động điền khi gõ dấu cách hoặc dấu câu. Không thay giữa lúc bộ gõ tiếng Việt đang composition.
- Dán bằng Ctrl+V, menu dán hoặc nút Dán văn bản: bung cả đoạn, kể cả từ cuối chưa có dấu cách. Câu mẫu cũng bung ngay. Hai thao tác này vẫn chuyển đổi khi tắt tự động điền lúc gõ.
- Chọn một gợi ý: thay đúng từ được chọn rồi bung các từ đủ điều kiện còn lại trong câu. Từ nhiều nghĩa như `xl`, `t` luôn cần chọn; chỉ mục được cho phép tự động điền mới được thay tự động.
- Các từ còn lại có nút riêng ngay trên hàng gợi ý. Ctrl+Space chọn gợi ý đầu tiên. Ctrl+Z hoàn tác, Ctrl+Shift+Z hoặc Ctrl+Y làm lại. Gõ liên tục được gom thành một bước; việc bung chữ có bước hoàn tác riêng để lấy lại chữ gốc.
- Sao chép lấy nội dung trong ô nhập; nếu tự động điền đang bật, hoàn tất cả từ cuối trước khi sao chép. Nút Xóa có thể hoàn tác. Mở “Xem lần bung gần nhất” để đối chiếu chữ gốc với cách bung.
- Giữ nguyên URL HTTP/HTTPS/www, email, @tên, #hashtag, tên có dấu gạch dưới và đoạn trong dấu backtick. Chữ đã bung không tiếp tục bị bung lặp; sửa trực tiếp chữ đó sẽ cho phép nhận diện lại.

Các tính năng này dùng từ điển hiện có, không đoán nghĩa theo AI hay dịch mọi tiếng lóng. Dữ liệu chưa được chủ trang duyệt vẫn chỉ là mẫu thử khi offline.

## Chạy local

Từ `web/dist`: `python -m http.server 5050 --bind 127.0.0.1`, sau đó mở http://localhost:5050/.

Bản gộp mở trực tiếp: `web/preview.html`. Sau khi sửa source, từ thư mục web chạy `node build-preview.mjs`. Script này nhúng dữ liệu/module vào preview và gộp SQL setup cho Supabase. Trên Live Server có thể mở `/web/preview.html`.

## Đóng góp công khai

Tab Từ điển & đóng góp (`#dictionary`) tách riêng khỏi tab Thử bàn phím (`#playground`). Bảng từ có phân trang, tìm kiếm có/không dấu, lọc nhóm và trạng thái. Bất kỳ ai cũng được gửi từ mới, thêm nghĩa và góp ý sửa từ từng hàng mà không có tài khoản. Có trường giải thích/ví dụ và tên tùy chọn. Đề xuất không sửa bản chính thức hay đưa ngay vào bàn phím; cần chủ trang duyệt.

Tab tra cứu luôn có 419 mục trong bộ có sẵn được mặc định là đã duyệt, gắn nhãn “Đã duyệt · Bộ có sẵn”. Khi kết nối Supabase, các nghĩa approved thay thế toàn bộ mẫu của cùng viết tắt và bổ sung mục mới vào bảng, để nghĩa cũ không xuất hiện lại sau khi chủ trang chỉnh sửa. Nguồn “Bộ có sẵn” phân biệt dữ liệu đóng gói với dữ liệu cộng đồng; không tải hàng chờ hay bản nháp của người khác. Bàn phím luôn giữ bộ mẫu thử đóng gói sẵn để gợi ý và tự động điền không bị mất khi Supabase trả rỗng hoặc mới duyệt một phần. Các mục approved bổ sung từ mới và thay toàn bộ nghĩa mẫu của cùng trigger; cờ auto_replace của bản đã duyệt được tôn trọng. Bộ lọc “Đã duyệt” và số lượng đã duyệt bao gồm cả bộ có sẵn lẫn dữ liệu cộng đồng được công bố. Các đề xuất pending/draft từ server không được đưa vào bộ từ. Nội dung tin nhắn không rời thiết bị, chỉ các đề xuất được người dùng bấm gửi mới được gửi lên Supabase.

## Quản trị

Không có liên kết quản trị ở trang công khai. Trang riêng nằm tại `dist/workbench-ink-7c91.html`, cần Supabase Auth và UUID có trong danh sách admin ở database. Xem `../supabase/README.md` để chạy setup và cấp quyền cho tài khoản của bạn. Trang này hiển thị hàng chờ, so sánh nghĩa cũ/mới, cho chỉnh nội dung và Accept/Reject; quyền thật được kiểm tra trong SQL.

## Kiểm tra

Từ thư mục web: `npm install` rồi `npm test`. PGlite chỉ dùng kiểm thử local, không được tải vào trình duyệt hoặc bundle production. Trang tĩnh không cần bước build framework; Cloudflare Pages có thể phục vụ `web/dist` từ repo gốc với build command `exit 0`.

Dữ liệu mẫu do IntelKB biên tập tại `data/editorial/expansions.jsonl` ở repo cha. Chạy `python scripts/export_web_words.py` rồi `python scripts/export_community_seeds.py` từ repo gốc để cập nhật. Dataset bên thứ ba chưa rõ quyền sử dụng không được đưa lên web. SQL seed tạo bản nháp trung gian; gói setup đầy đủ tự duyệt bộ có sẵn ở bước cuối. Với database đang dùng, chạy `web/dist/reference-approval-upgrade.sql` sau bản nâng cấp kiểm duyệt theo chế độ: chỉ chuyển các seed bootstrap nguyên bản, chưa xử lý sang approved; bổ sung cả nghĩa còn thiếu trong nhóm đã công bố, giữ cài đặt ưu tiên của chủ trang, seed đã sửa/từ chối và mọi đề xuất cộng đồng. Cặp đã công bố trùng hoàn toàn được gộp; bản seed gốc được sao lưu riêng trong `intelkb_bootstrap_archive` (chỉ quản trị viên đọc được). Cài đặt tự động điền của bộ có sẵn được giữ nguyên. Có thể chạy lại an toàn. SQL này chưa được tự động chạy trên Supabase của bạn.

## Nhập liệu và bàn kiểm duyệt mới

Biểu mẫu cho xem trước cặp đang nhập và báo trùng cả hai trường, không phân biệt hoa/thường hay khoảng trắng. Mục đã công bố trùng hẳn không được gửi lại như từ mới; nút góp ý mở đúng mục gốc. Cặp trong bộ mẫu được cảnh báo để người dùng bổ sung ngữ cảnh. Nội dung đang nhập được giữ cục bộ (không bao gồm mật khẩu hay dữ liệu quản trị).

Chế độ Dán nhiều từ nhận tối đa 20 dòng từ Excel (Tab), CSV hoặc `viết tắt → nghĩa`. Xem trước lỗi từng dòng, tự bỏ qua các cặp trùng trong nội dung và danh sách hiện tại; gửi riêng từng dòng hợp lệ. Dòng gửi lỗi lưu vào bản nháp để thử lại, không tự công bố. Dòng nhiều từ mặc định chỉ gợi ý (không tự bật auto_replace).

Trang quản trị dùng bảng có độ cao cuộn riêng, gom cụm chỉ với những từ có nhiều mục trên trang và khung sửa bên cạnh. Có chọn trang/chọn cụm, Duyệt/Từ chối trực tiếp ngay trên mỗi dòng, không mở popup, chỉnh nhóm theo lô, tắt tự động điền theo lô, phím J/K và báo cáo kết quả tải JSON. Thay đổi nghĩa chưa gửi được giữ khi chuyển mục trong cùng trang; đổi bộ lọc hoặc tải lại sẽ bỏ chỉnh sửa tạm đó. Chọn nhiều chỉ áp dụng trong trang hiện tại, không chọn ngầm các trang khác.

Xem `supabase/README.md` ở repo gốc để chạy SQL nâng cấp và phân biệt dữ liệu giả kiểm tra với dữ liệu thật.

## Tra cứu ngay khi nhập từ mới

Bảng từ điển có cột và bộ lọc **Tự động điền**. Bấm **Bật/Tắt · Sửa** để đề xuất đổi riêng cài đặt, giữ nguyên nghĩa; trạng thái hiện tại và đề xuất được hiển thị trong biểu mẫu. Cài đặt vẫn cần chủ trang duyệt. Kết quả tìm nhanh cũng hiển thị Bật/Tắt. Mục tham khảo lấy mặc định từ bộ máy bàn phím; mục đã duyệt lấy cài đặt trong database. Bật là cho phép tự động điền, còn việc điền thực tế phụ thuộc chế độ bàn phím và lựa chọn nghĩa.

Ô viết tắt tìm ngay trong toàn bộ danh sách công khai đã tải (bộ mẫu và nghĩa đã duyệt), không cần nhập xong hoặc điền nghĩa. Kết quả không phân biệt hoa/thường; ưu tiên khớp toàn bộ, rồi bắt đầu bằng ký tự đã nhập, rồi chứa ký tự đó. Số nghĩa khớp toàn bộ được đếm riêng với các mục gần khớp; mỗi cặp chỉ đếm một lần. Hiện tối đa 6 mục để đối chiếu, có nút mở bảng tra cứu và nút góp ý từng mục. Không có kết quả thì ẩn khung; kiểm tra trùng cả cặp và hàng chờ vẫn hoạt động như trước. Không công khai nội dung hàng chờ.

## Thao tác nhanh với hàng chờ

Bấm nền dòng hoặc nhấn Space/Enter khi dòng đang được focus để chọn/bỏ chọn. Các nút, ô nhập và checkbox vẫn hoạt động riêng, không làm đổi lựa chọn ngoài ý muốn. Dòng được chọn có nền nổi bật. Nút Duyệt/Từ chối trên dòng được chọn áp dụng cho toàn bộ các dòng đã chọn trên trang, đồng thời hiển thị số lượng. Nút ở dòng chưa chọn chỉ xử lý dòng đó. Không mở popup xác nhận. Cài đặt nhóm/tự động điền/ghi chú theo lô nằm ngay trên trang; trạng thái đang xử lý khóa thao tác lặp. Ở phần đóng góp, bấm cả thẻ tự động điền để đổi lựa chọn, hoặc bấm nền dòng/kết quả tìm nhanh để mở góp ý.

## Quy tắc trùng đầy đủ / chỉnh sửa

Giống cả viết tắt, nghĩa, nhóm và tự động điền thì chặn gửi, kể cả thêm ghi chú hoặc đổi tên người góp. Thay đổi nhóm, tự động điền hoặc nghĩa được chuyển thành đề xuất chỉnh sửa trên mục hiện có. Với nhiều nghĩa, chọn đúng mục để chỉnh sửa hoặc bấm ＋ Nghĩa để bổ sung. Có thể sửa viết tắt khi đã chọn mục cần sửa. Bộ mẫu không có revision trong database nên phần khác bộ mẫu được gửi làm ứng viên mới. Dán nhiều dòng giữ các cột bị bỏ trống của mục cũ; không tự đề xuất tắt tự động điền. Cần chạy `web/dist/entry-changes-upgrade.sql` trước khi dùng luồng gửi mới.

## Tự động điền theo chế độ và kiểm duyệt có hoàn tác

Nhắn tục ưu tiên tập nghĩa `profanity`; nếu không có nghĩa tục thì dùng tập nghĩa không tục. Nhắn nhẹ chỉ dùng nghĩa không tục (`chat`, `euphemism`, `english`, `game`). Trong nhóm nhiều nghĩa, mỗi chế độ có một ứng viên thì tự điền ứng viên đó; nhiều ứng viên cùng chế độ phải có đúng một nghĩa ưu tiên do chủ trang chọn. Không lấy nghĩa đầu tiên theo thứ tự sắp xếp. Với mục một nghĩa, giữ quyền tự động điền hiện có. Chọn gợi ý/câu mẫu có nghĩa chỉ định vẫn là lựa chọn rõ ràng của người dùng.

Mở **Kiểm tra tự động điền theo chế độ** trên bàn kiểm duyệt. Chọn nghĩa đang chờ cũng chọn dòng vào lượt duyệt; bấm nút Duyệt trên dòng được chọn áp dụng cả nhóm đã chọn. Nghĩa đã công bố có thể đổi ưu tiên bằng nút Lưu riêng. Từ cùng cặp một tục/một nhẹ tự được cấu hình khi duyệt. Khi một phía còn nhiều nghĩa chưa chọn ưu tiên, toàn bộ lượt duyệt đó được rollback và giao diện mở phần chọn ưu tiên.

Các dòng chỉnh sửa tô trước/sau cho bốn trường từ vựng. Duyệt xong mở mục tiếp, ưu tiên dòng bị lỗi và giữ vị trí cuộn bảng. Nút **Hoàn tác lượt cuối** khôi phục trạng thái trước lượt duyệt hoặc đổi ưu tiên với phiên bản mới; nếu có thay đổi tiếp trên các dữ liệu liên quan thì từ chối hoàn tác. Không xóa vĩnh viễn mục vừa tạo; mục được thu hồi và đề xuất trở lại hàng chờ. Không gửi lại tự động sau lỗi mạng; dùng Tải lại để xem kết quả.

Chạy `web/dist/review-efficiency-upgrade.sql` trong Supabase SQL Editor. Kiểm tra UI bằng `node web/tests/style-review-preview.mjs 8772`: PostgreSQL thử trong bộ nhớ, tài khoản giả, không kết nối Supabase thật.

### Chỉnh sửa mục đã công bố

Trong trang quản trị, mở mục đã chấp nhận, sửa nghĩa/nhóm/tự động điền rồi bấm **Lưu thay đổi** ở đầu khung chi tiết. Database đang dùng cần chạy `web/dist/published-edit-upgrade.sql` một lần sau các nâng cấp kiểm duyệt trước đó. Chỉ chủ trang được lưu; RPC kiểm tra phiên bản, chặn cặp trùng, ghi lịch sử và hỗ trợ nút hoàn tác. Khi lưu lỗi, nội dung form được giữ để thử lại. Nút lưu không tự công bố đề xuất của người đóng góp.

Bản rà soát phát hành: bản sửa trong trang quản trị được giữ khi lọc/chuyển trang/tải lại; nếu phiên bản máy chủ thay đổi thì chặn ghi đè và cho bỏ bản sửa cũ để đối chiếu bản mới. Đóng tab khi có bản sửa chưa lưu sẽ được trình duyệt cảnh báo. Các yêu cầu quản trị dùng chung một lần refresh token để tránh xung đột phiên.
