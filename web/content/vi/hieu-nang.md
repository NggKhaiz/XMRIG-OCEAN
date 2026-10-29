# Benchmark và tinh chỉnh

## Cách đo

```bash
# một lần chạy, 20 000 hash, có dựng dataset
./zmrig/out/zmrig --bench=20000

# đo nhanh sau khi đã đổi cấu hình
./zmrig/out/zmrig --bench=15000

# số liệu cho dashboard (10 giây warm-up + 15 giây đo)
./zmrig/out/zmrig --report --power 45
```

`--bench` dùng seed cố định `00112233…`, blob 76 byte, target thấp nhất — mọi lần chạy đều hash cùng một dữ liệu, nên kết quả so sánh được. Thời gian dựng dataset (15–25 giây) nằm ngoài phần đo.

Quy tắc để số đo có nghĩa:

- **Tắt miner trước khi bench.** Miner đang chạy đã giữ huge pages; bench sẽ dựng dataset trong bộ nhớ thường và cho số thấp hơn thực tế. `oneclick.sh bench` tự dừng/khởi động lại service để tránh chuyện này.
- **Đo trên chính máy đó.** Hashrate tuyệt đối phụ thuộc host; đừng so với bảng dưới.
- **Mỗi cấu hình chạy 2 lần.** Chênh lệch dưới 2% là nhiễu.

## Kết quả đo trên VM 2 vCPU (Xeon 2.6 GHz, 1234 huge page 2 MiB)

| Cấu hình | Hashrate | So với mặc định | Nhận xét |
|---|---:|---:|---|
| Mặc định: 2 thread, huge pages, prefetch 1 | 814 H/s | 100% | điểm chuẩn |
| `--no-huge-pages` | 634 H/s | 78% | mất 22% ở lần đo này, 36% ở lần khác |
| `--mode light` | 76 H/s | 9% | chỉ dùng khi thiếu RAM |
| `-t 1` | 408 H/s | 50% | scale tuyến tính |
| `--scratchpad-prefetch=0` | 823 H/s | 101% | trong nhiễu |
| `--scratchpad-prefetch=2` | 823 H/s | 101% | trong nhiễu |
| `--no-affinity` | 814 H/s | 100% | 2 vCPU, không khác biệt |

Cùng máy, cùng binary, ở phiên đo khác (host ít tải hơn): **1008–1103 H/s**. Đây là lý do phải so sánh tương đối.

Đối chứng engine C++ trên cùng máy: **1075.7 H/s** — chênh lệch với engine Zig nằm trong biên độ giữa các lần chạy.

## Ba thứ thực sự tạo ra khác biệt

### 1. Huge pages

Lớn nhất, rõ ràng nhất. RandomX truy cập dataset 2 GiB theo kiểu ngẫu nhiên; trang 4 KiB làm TLB miss liên tục.

```bash
# đặt trước 1234 trang 2 MiB (≈2.4 GiB)
echo 1234 | sudo tee /proc/sys/vm/nr_hugepages
grep HugePages_ /proc/meminfo
```

Installer đã làm việc này và ghi vào systemd unit (`LimitMEMLOCK=infinity`). Kiểm tra miner có lấy được không: log khởi động in `huge pages 2336 MB`, API trả `"hugepages": [1168, 1168]` (đã cấp / cần).

Cảnh báo thực tế: khi đã đặt 1234 trang, RAM thường còn ~1.2 GB. Chạy `--no-huge-pages` lúc này sẽ bị OOM-kill (exit 137) vì dataset 2 GiB không còn chỗ. Muốn đo cấu hình không huge pages thì hạ `nr_hugepages` về 0 trước.

### 2. Chế độ fast hay light

`fast` dựng dataset 2 GiB dùng chung cho mọi thread → 814 H/s trên máy 2 vCPU.
`light` chỉ giữ cache 256 MiB, mỗi hash tính lại dataset → 76 H/s.

Chênh gần 11 lần. `light` chỉ hợp lý khi VPS không đủ RAM, hoặc khi bạn cần thử nhanh cấu hình (khởi động 0.6 giây thay vì 20 giây).

### 3. Số thread

Trên máy này scale tuyến tính: 2 thread = 814 H/s, 1 thread = 408 H/s. Không có "điểm ngọt" bí ẩn. Nếu VPS bị throttle CPU (shared vCPU), thêm thread có thể *giảm* hashrate mỗi thread nhưng tổng vẫn tăng; đo lại là cách duy nhất để biết.

## Những thứ không tạo ra khác biệt (đã đo)

- `--scratchpad-prefetch` 0/1/2/3: chênh dưới 1.5%, tức là nhiễu. Để mặc định.
- `--no-affinity` trên 2 vCPU: không đổi.
- `--no-optimized-init`: chỉ ảnh hưởng thời gian dựng dataset, không ảnh hưởng hashrate.

Đừng tin các "mẹo" kiểu đổi `priority` để tăng hashrate: `priority` chỉ đổi cách hệ điều hành chia CPU, không làm phép tính nhanh hơn. Nó hữu ích khi máy chạy nhiều việc.

## Quy trình tinh chỉnh 10 phút

```bash
# 1. trạng thái nền
sudo ./oneclick.sh stop
grep -E "HugePages_Total|HugePages_Free" /proc/meminfo

# 2. đo mặc định
./zmrig/out/zmrig --bench=15000

# 3. thử các biến thể, mỗi biến thể 2 lần
./zmrig/out/zmrig --bench=15000 -t 1
./zmrig/out/zmrig --bench=15000 --no-huge-pages   # chỉ khi đã hạ nr_hugepages
./zmrig/out/zmrig --bench=15000 --mode light

# 4. giữ cấu hình tốt nhất trong config, rồi bật lại
sudo ./oneclick.sh start
```

Ghi lại số đo vào một file (`doc/BENCHMARKS.md` trong repo là nơi tốt) kèm ngày và tên host. Sáu tháng sau bạn sẽ cần chúng.

## Nhiệt và điện

Hashrate không phải tất cả. Một máy chạy 814 H/s ở 95 W hiệu quả hơn máy 900 H/s ở 130 W. Đo bằng ổ điện, hoặc lấy công suất package qua RAPL:

```bash
cat /sys/class/powercap/intel-rapl:0/energy_uj   # hai lần, cách nhau 1 giây
```

`zmrig --report` đọc giúp bạn và ghi nguồn đo vào mã báo cáo (`pwsrc`: `rapl`, `hwmon`, `user` hoặc `none`). Bảng tính ở trang chủ quy đổi tiếp sang điện năng và tiền.

Tiếp: [Mạng kén chọn](#mang).
