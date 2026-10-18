# IntelKB playground

Giao diện mô phỏng bàn phím: phím ảo sáng khi nhấn, gợi ý theo con trỏ, bung nhiều từ liên tiếp, Bung cả câu, hoàn tác, Nói thẳng/Nói nhẹ. Gõ bằng bàn phím thật hoặc phím ảo; Telex ảo mới hỗ trợ các tổ hợp phổ biến, chưa phải bộ gõ đầy đủ.

## Autocomplete

- Mặc định bật tự bung khi gõ dấu cách hoặc dấu câu. Không thay giữa lúc bộ gõ tiếng Việt đang composition.
- Dán bằng Ctrl+V, menu dán hoặc nút Dán văn bản: bung cả đoạn, kể cả từ cuối chưa có dấu cách. Câu mẫu cũng bung ngay. Hai thao tác này vẫn chuyển đổi khi tắt tự bung lúc gõ.
- Chọn một gợi ý: thay đúng từ được chọn rồi bung các từ đủ điều kiện còn lại trong câu. Từ nhiều nghĩa như `xl`, `t` luôn cần chọn; chỉ mục được cho phép tự bung mới được thay tự động.
- Các từ còn lại có nút riêng ngay trên hàng gợi ý. Ctrl+Space chọn gợi ý đầu tiên. Ctrl+Z hoàn tác, Ctrl+Shift+Z hoặc Ctrl+Y làm lại. Gõ liên tục được gom thành một bước; việc bung chữ có bước hoàn tác riêng để lấy lại chữ gốc.
- Sao chép lấy nội dung trong ô nhập; nếu tự bung đang bật, hoàn tất cả từ cuối trước khi sao chép. Nút Xóa có thể hoàn tác. Mở “Xem lần bung gần nhất” để đối chiếu chữ gốc với cách bung.
- Giữ nguyên URL HTTP/HTTPS/www, email, @tên, #hashtag, tên có dấu gạch dưới và đoạn trong dấu backtick. Chữ đã bung không tiếp tục bị bung lặp; sửa trực tiếp chữ đó sẽ cho phép nhận diện lại.

Các tính năng này dùng từ điển hiện có, không đoán nghĩa theo AI hay dịch mọi tiếng lóng. Dữ liệu chưa được chủ trang duyệt vẫn chỉ là mẫu thử khi offline.

## Chạy local

Từ `web/dist`: `python -m http.server 5050 --bind 127.0.0.1`, sau đó mở http://localhost:5050/.

Bản gộp mở trực tiếp: `web/preview.html`. Sau khi sửa source, từ thư mục web chạy `node build-preview.mjs`. Script này nhúng dữ liệu/module vào preview và gộp SQL setup cho Supabase. Trên Live Server có thể mở `/web/preview.html`.

## Đóng góp công khai

Tab Từ điển & đóng góp (`#dictionary`) tách riêng khỏi tab Thử bàn phím (`#playground`). Bảng từ có phân trang, tìm kiếm có/không dấu, lọc nhóm và trạng thái. Bất kỳ ai cũng được gửi từ mới, thêm nghĩa và góp ý sửa từ từng hàng mà không có tài khoản. Có trường giải thích/ví dụ và tên tùy chọn. Đề xuất không sửa bản chính thức hay đưa ngay vào bàn phím; cần chủ trang duyệt.

Tab tra cứu luôn có 419 mẫu công khai gắn nhãn Tham khảo, kể cả khi chưa duyệt bộ seed. Khi kết nối Supabase, các nghĩa approved thay thế mẫu trùng và bổ sung mục mới vào bảng. Nhãn Tham khảo không phản ánh dữ liệu draft riêng trong database; không tải hàng chờ hay bản nháp của người khác. Bàn phím luôn giữ bộ mẫu thử đóng gói sẵn để gợi ý và tự bung không bị mất khi Supabase trả rỗng hoặc mới duyệt một phần. Các mục approved bổ sung từ mới và thay toàn bộ nghĩa mẫu của cùng trigger; cờ auto_replace của bản đã duyệt được tôn trọng. Mẫu thử được ghi rõ dưới bàn phím, không mang nhãn đã duyệt. Các đề xuất pending/draft từ server không được đưa vào bộ từ. Nội dung tin nhắn không rời thiết bị, chỉ các đề xuất được người dùng bấm gửi mới được gửi lên Supabase.

## Quản trị

Không có liên kết quản trị ở trang công khai. Trang riêng nằm tại `dist/workbench-ink-7c91.html`, cần Supabase Auth và UUID có trong danh sách admin ở database. Xem `../supabase/README.md` để chạy setup và cấp quyền cho tài khoản của bạn. Trang này hiển thị hàng chờ, so sánh nghĩa cũ/mới, cho chỉnh nội dung và Accept/Reject; quyền thật được kiểm tra trong SQL.

## Kiểm tra

Từ thư mục web: `npm install` rồi `npm test`. PGlite chỉ dùng kiểm thử local, không được tải vào trình duyệt hoặc bundle production. Trang tĩnh không cần bước build framework; Cloudflare Pages có thể phục vụ `web/dist` từ repo gốc với build command `exit 0`.

Dữ liệu mẫu do IntelKB biên tập tại `data/editorial/expansions.jsonl` ở repo cha. Chạy `python scripts/export_web_words.py` rồi `python scripts/export_community_seeds.py` từ repo gốc để cập nhật. Dataset bên thứ ba chưa rõ quyền sử dụng không được đưa lên web. Các seed xuất ra SQL là draft để chủ trang duyệt.

## Nhập liệu và bàn kiểm duyệt mới

Biểu mẫu cho xem trước cặp đang nhập và báo trùng cả hai trường, không phân biệt hoa/thường hay khoảng trắng. Mục đã công bố trùng hẳn không được gửi lại như từ mới; nút góp ý mở đúng mục gốc. Cặp trong bộ mẫu được cảnh báo để người dùng bổ sung ngữ cảnh. Nội dung đang nhập được giữ cục bộ (không bao gồm mật khẩu hay dữ liệu quản trị).

Chế độ Dán nhiều từ nhận tối đa 20 dòng từ Excel (Tab), CSV hoặc `viết tắt → nghĩa`. Xem trước lỗi từng dòng, tự bỏ qua các cặp trùng trong nội dung và danh sách hiện tại; gửi riêng từng dòng hợp lệ. Dòng gửi lỗi lưu vào bản nháp để thử lại, không tự công bố. Dòng nhiều từ mặc định chỉ gợi ý (không tự bật auto_replace).

Trang quản trị dùng bảng có độ cao cuộn riêng, gom cụm chỉ với những từ có nhiều mục trên trang và khung sửa bên cạnh. Có chọn trang/chọn cụm, xem trước danh sách trước Accept/Reject, chỉnh nhóm theo lô, tắt tự bung theo lô, phím J/K và báo cáo kết quả tải JSON. Thay đổi nghĩa chưa gửi được giữ khi chuyển mục trong cùng trang; đổi bộ lọc hoặc tải lại sẽ bỏ chỉnh sửa tạm đó. Chọn nhiều chỉ áp dụng trong trang hiện tại, không chọn ngầm các trang khác.

Xem `supabase/README.md` ở repo gốc để chạy SQL nâng cấp và phân biệt dữ liệu giả kiểm tra với dữ liệu thật.

## Tra cứu ngay khi nhập từ mới

Bảng từ điển có cột và bộ lọc **Tự động điền**. Bấm **Bật/Tắt · Sửa** để đề xuất đổi riêng cài đặt, giữ nguyên nghĩa; trạng thái hiện tại và đề xuất được hiển thị trong biểu mẫu. Cài đặt vẫn cần chủ trang duyệt. Kết quả tìm nhanh cũng hiển thị Bật/Tắt. Mục tham khảo lấy mặc định từ bộ máy bàn phím; mục đã duyệt lấy cài đặt trong database. Bật là cho phép tự động điền, còn việc điền thực tế phụ thuộc chế độ bàn phím và lựa chọn nghĩa.

Ô viết tắt tìm ngay trong toàn bộ danh sách công khai đã tải (bộ mẫu và nghĩa đã duyệt), không cần nhập xong hoặc điền nghĩa. Kết quả không phân biệt hoa/thường; ưu tiên khớp toàn bộ, rồi bắt đầu bằng ký tự đã nhập, rồi chứa ký tự đó. Số nghĩa khớp toàn bộ được đếm riêng với các mục gần khớp; mỗi cặp chỉ đếm một lần. Hiện tối đa 6 mục để đối chiếu, có nút mở bảng tra cứu và nút góp ý từng mục. Không có kết quả thì ẩn khung; kiểm tra trùng cả cặp và hàng chờ vẫn hoạt động như trước. Không công khai nội dung hàng chờ.
