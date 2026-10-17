# IntelKB

Bản thử bàn phím trên web: xem `web/README.md`. Giao diện có phím ảo, gợi ý, tự bung khi gõ/dán/chọn câu mẫu, hoàn tác/làm lại và từ điển cộng đồng có kiểm duyệt.

Bàn phím thông minh mang tính hài hước: gõ ngắn, nói đầy đủ. Nhận diện từ viết tắt, teencode, tiếng lóng và từ tục để gợi ý bung chữ hoặc tự thay khi người dùng chọn chế độ đó.

## Giai đoạn hiện tại: dữ liệu

Chạy `python scripts/collect_data.py` để tải nguồn công khai và tạo dữ liệu ứng viên. Python 3, không cần thư viện ngoài. Đã có giao diện web thử nghiệm; chưa có bàn phím mobile cài vào hệ thống.

- `data/raw/`: bản gốc, README và giấy phép nếu nguồn có cung cấp.
- `data/sources.json`: URL, commit, SHA-256 và thời điểm thu thập.
- `data/processed/expansion_candidates.jsonl`: cặp viết tắt → cách bung, giữ nhiều nghĩa và nguồn.
- `data/processed/offensive_variants.jsonl`: từ tục và biến thể; danh sách nhận diện không đồng nghĩa với từ điển giải nghĩa.
- `data/processed/sentence_pairs.jsonl`: câu gốc và câu chuẩn hóa, giữ nhãn train/dev/test của nguồn.
- `data/summary.json`: số lượng thực tế sau thu thập.

Mọi cặp nhập từ từ điển đều là ứng viên chưa được IntelKB duyệt, `auto_replace=false`. Cần rà nghĩa, mức tục, ngữ cảnh, từ đa nghĩa (vc/xl/dm), tên riêng và ranh giới từ trước khi bật tự thay. Không suy diễn cách bung chỉ từ nhãn từ tục. Unicode được chuẩn hóa NFC; không xóa dấu khi hợp nhất khóa.

## Nguồn và quyền sử dụng

Giữ giấy phép gốc của từng nguồn. MIT của blue-eyes-vn và GPL-3.0 của VMDS được lưu kèm; UNVERIFIED chỉ có nghĩa chưa xác minh được giấy phép, không phải được quyền phân phối thương mại. Các bản dữ liệu chưa rõ quyền sử dụng phục vụ khảo sát cục bộ và cần kiểm tra trước khi đóng gói phát hành. Không tự đặt giấy phép chung cho toàn bộ dữ liệu.

Từ điển ViSoLex được sinh từ ViLexNorm nên không coi hai nguồn là hai bằng chứng độc lập, và không dùng từ điển gộp này để đánh giá trên dev/test ViLexNorm vì có nguy cơ rò rỉ dữ liệu.

## Bước tiếp theo

Duyệt bộ từ phổ biến trước; thêm cách bung chính xác cho các biến thể tục; bổ sung ví dụ ngữ cảnh và nhiều nghĩa; xây bộ kiểm tra gợi ý trên câu chưa xuất hiện trong dữ liệu. Giao diện web đã hỗ trợ chọn gợi ý, hoàn tác/làm lại và bật/tắt tự thay. Thiết lập database và tài khoản duyệt theo `supabase/README.md`.

Các thư mục `data/raw/`, `data/processed/`, `data/compiled/` được giữ cục bộ và không đưa vào Git. Repo chứa script thu thập/build, thông tin nguồn và các đề xuất biên tập; chạy lại script để tạo dữ liệu khảo sát. Khi đưa lên Cloudflare Pages từ repo gốc, dùng output directory `web/dist` (không cần build framework).

## Tra thử offline

Sau khi đã có dữ liệu gốc, các lệnh sau không cần mạng:

```powershell
python scripts/build_dictionary.py
python scripts/lookup.py "đcmm sao hnay lag vcl, xl nha"
python scripts/lookup.py "xl" --json
python -m unittest discover -s tests -v
```

`data/compiled/dictionary.jsonl` hợp nhất ứng viên với đề xuất biên tập của IntelKB, giữ nguồn của mỗi nghĩa và có ID ổn định. `data/compiled/review_queue.jsonl` ưu tiên các nghĩa tục và từ đa nghĩa để duyệt. Sửa đề xuất tại `data/editorial/expansions.jsonl`, sau đó build lại; không sửa trực tiếp file compiled vì sẽ bị ghi đè. Bộ compiled được build riêng, cần chạy lại sau mỗi lần thu thập dữ liệu.

419 cặp trong bộ biên tập hiện tại là đề xuất do agent soạn, chưa có xác nhận của người dùng. Một số mục là dịch tiếng Anh hoặc diễn giải tương đương, không phải khai triển chữ viết tắt theo nghĩa đen. Nhãn `editorial_proposal` chỉ dùng để ưu tiên hiển thị khi tra thử, không phải điểm tin cậy. Các mục từ nguồn ngoài chưa được phân loại vẫn có `categories=[]`; không được coi chúng là từ không tục. Nhiều nghĩa còn thiếu, kể cả khi `ambiguous=false`.

Công cụ tra hiện nhận diện từ/cụm đã gõ hoàn chỉnh, ưu tiên cụm dài và trả nhiều gợi ý; chưa dự đoán phần từ đang gõ hoặc xếp hạng theo ngữ cảnh. Giữ nguyên câu, chưa tự thay. `start/end` tính theo Unicode code point của chuỗi NFC trả về, không phải UTF-16 của JavaScript; giao diện cần đổi đơn vị offset trước khi đặt con trỏ.

Danh sách `behitek/vietnam-sensitive-words` có cả tên cơ quan và từ bình thường trong dữ liệu sinh tự động. Vì vậy hiện giữ nguyên để khảo sát, không tự đưa toàn bộ thành nhãn từ tục trong từ điển.
