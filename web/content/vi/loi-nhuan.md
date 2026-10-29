# Lợi nhuận và điện năng

Mục tiêu của trang này không phải làm bạn phấn khích, mà để bạn ra quyết định: giữ máy nào, tắt máy nào, giá điện nào thì hoà vốn.

## Công thức bảng tính dùng

Với mỗi máy:

```
hashrate     H/s        lấy từ cửa sổ bạn chọn (10 s / 60 s / 15 phút / cao nhất)
công suất    W wall     = W_cpu / hiệu_suất_PSU + điện_nền
điện/ngày    kWh        = W wall × 24 / 1000
tiền điện    $/ngày     = kWh/ngày × giá điện
doanh thu    XMR/ngày   (hai chế độ, xem dưới)
lợi nhuận    $/ngày     = doanh thu × giá XMR − tiền điện
hiệu suất    H/W        = hashrate / W wall
```

Hai chế độ doanh thu:

**Theo pool.** Bạn nhập `XMR trên mỗi kH/s mỗi ngày`, con số pool hiển thị trên dashboard của họ.

```
XMR/ngày = (hashrate / 1000) × xmr_per_khs_day
```

Đây là con số sát thực tế nhất với pool có algo-switching (MoneroOcean), vì nó đã gộp phần đổi thuật toán.

**Theo mạng Monero.**

```
block/ngày của bạn = (hashrate / hashrate_mạng) × 720
XMR/ngày           = block/ngày × thưởng_mỗi_block × (1 − phí_pool)
```

Với tail emission hiện tại, thưởng mỗi block là 0.6 XMR, 720 block/ngày, hashrate mạng thường được công bố theo GH/s. Cách này bỏ qua việc pool đổi thuật toán, nên chỉ dùng để đối chiếu.

## Vì sao phải đo công suất, không đoán

Bảng tính mặc định cộng thêm điện nền (25 W) và chia cho hiệu suất PSU (87%) vì công suất trong mã báo cáo là công suất **package CPU** — nó không gồm mainboard, ổ cứng, quạt, mất mát của PSU.

Ba mức độ chính xác:

1. **Ổ đo điện ở ổ cắm** — đúng nhất. Cắm, đọc W, nhập vào cột điện (hoặc truyền `--power W`; giá trị `user` được dùng nguyên, không quy đổi PSU).
2. **RAPL/hwmon** — `zmrig --report` tự đọc nếu kernel cung cấp; đó là package CPU. Cộng thêm 15–30 W cho phần còn lại (chỉnh bằng hai ô trong bảng tính).
3. **Đoán theo TDP** — chỉ để ước lượng thô. Sai số 30–50% là bình thường.

Trường `pwsrc` trong mã nói con số đến từ đâu. Nếu là `none`, hãy nhập tay.

## Đọc kết quả

Ví dụ một máy 2 vCPU, 814 H/s, package 45 W, PSU 87%, điện nền 25 W, giá điện 0.10 $/kWh:

```
W wall   = 45 / 0.87 + 25 = 76.7 W
điện/ngày= 76.7 × 24 / 1000 = 1.84 kWh
tiền điện= 1.84 × 0.10 = $0.184
doanh thu (0.000096 XMR/kH/s/ngày, XMR $300)
         = 0.814 × 0.000096 × 300 = $0.0234
lợi nhuận= 0.0234 − 0.184 = −$0.16/ngày
```

Kết quả âm là **bình thường** với CPU mining Monero ở phần lớn nơi trên thế giới. Điều đó không có nghĩa tool hỏng; nó có nghĩa là:

- Nếu bạn đã có VPS trả tiền cho việc khác và CPU đang rảnh, chi phí biên là ~0 → khai thác được.
- Nếu bạn trả tiền điện đúng giá đó để mua máy mới, bài toán là lỗ — trừ khi giá XMR tăng hoặc bạn có điện rẻ.

Bảng tính hiển thị thêm **giá điện hoà vốn**: mức $/kWh mà tại đó máy này hoà. Nếu giá hoà vốn thấp hơn giá bạn đang trả, đừng chạy máy đó.

## Quyết định với nhiều máy

Sắp xếp bảng theo cột `Lợi nhuận $/ngày` và `H/W`:

- **Giữ**: lợi nhuận dương, hoặc âm nhẹ nhưng máy đã trả tiền và không dùng cho việc khác.
- **Tắt**: âm rõ rệt và H/W thấp hơn trung bình đội.
- **Thay cấu hình**: cùng một máy, `--mode light` làm hashrate còn 9% nhưng điện gần như không đổi → hầu như luôn là lựa chọn tồi nếu có đủ RAM. Ngược lại, tắt bớt thread có thể tăng H/W nếu VPS bị giới hạn CPU.

Một phép so sánh hay dùng: **chi phí để có 1 kH/s mỗi ngày**.

```
$/ngày trên 1 kH/s = tiền điện/ngày ÷ (hashrate / 1000)
```

Con số này độc lập với giá coin, nên so sánh được giữa các máy và các nhà cung cấp.

## Sai số và những gì bảng tính không biết

- **Độ khó mạng thay đổi** → doanh thu thực tế lệch so với ước lượng.
- **Tỉ lệ share**: ước lượng giả định mọi share được chấp nhận. Share rejected/stale làm giảm doanh thu; xem cột shares trong API.
- **Phí pool**: chế độ "theo pool" giả định con số bạn nhập đã trừ phí pool.
- **Giá coin**: bạn nhập tay hoặc bấm "Lấy giá" (CoinGecko). Giá biến động hàng giờ.
- **Stale/dev fee**: không có phí dev (0%), nên không cần trừ.
- **Tiền máy**: bảng tính không khấu hao. Muốn tính hoà vốn thiết bị: `giá máy ÷ lợi nhuận/ngày`.

## Cách lấy số pool nhanh

```bash
# hashrate 60 giây và share của máy này
curl -s 127.0.0.1:18080/1/summary | python3 -c '
import json,sys; d=json.load(sys.stdin)
print("H/s", d["hashrate"]["total"][1], "shares", d["results"]["shares_good"])'
```

Còn `XMR/kH/s/ngày` thì lấy từ trang dashboard của pool — đó là con số họ dùng để trả cho bạn, đừng suy ra từ độ khó mạng rồi tự làm khó mình.

Tiếp: [Kiểm thử](#kiem-thu).
