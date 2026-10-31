---
title: Hiệu năng
description: Cái gì thật sự làm hashrate đổi trên CPU, cái gì không, và cách đo mà không tự lừa mình.
image: https://nggkhaiz.github.io/ZMRIG/img/og-vi.png
---

# Hiệu năng

RandomX là proof-of-work phụ thuộc bộ nhớ: vòng hash đọc dataset 2 GiB theo thứ
tự ngẫu nhiên. Gần như mọi thứ quan trọng suy ra từ đúng một câu đó.

## Ba đòn bẩy thật sự

**Huge pages.** Mức lợi lớn nhất và rõ nhất. Trang 4 KiB làm mỗi vài lần truy cập
dataset lại thành một TLB miss.

```bash
echo 1234 | sudo tee /proc/sys/vm/nr_hugepages    # ~2.4 GiB trang 2 MiB
grep HugePages_ /proc/meminfo
```

Installer làm việc này và đặt `LimitMEMLOCK=infinity` trong unit. Kiểm tra miner
có lấy được: log khởi động in `huge pages 2336 MB`, API trả
`"hugepages": [1168, 1168]` (được cấp / cần).

:::warning Đo khi không có huge pages
Khi đã đặt 1234 trang, RAM thường chỉ còn khoảng 1.2 GB. Chạy `--no-huge-pages`
lúc đó sẽ bị OOM-kill (exit 137), vì dataset 2 GiB thứ hai không có chỗ. Đặt
`nr_hugepages` về 0 trước khi đo trường hợp đó, và nhớ đặt lại.
:::

**Chế độ fast hay light.** `fast` dựng một dataset 2 GiB dùng chung cho mọi
thread. `light` giữ cache 256 MiB và dựng lại dataset cho mỗi hash: 76 H/s so với
814 H/s trên cùng máy. Light mode tồn tại cho VPS không cho nổi 2 GiB, không
phải để tiết kiệm điện.

**Số thread.** Một thread mỗi core vật lý, hai mỗi core chỉ khi SMT giúp: trên
máy test, hai thread trên hai vCPU cho 814 H/s và một thread cho 408 H/s, tức là
tuyến tính. SMT thường thêm 5–15 % hashrate với 30–40 % điện hơn, nên profile
`watt` bỏ nó.

## Hai thứ không có tác dụng

- **Chế độ scratchpad prefetch** (0/1/2/3): 823, 814, 823, 814 H/s — trong nhiễu.
  Mặc định (1) được giữ nguyên.
- **Affinity** trên máy 2 vCPU: không khác gì. Nó có ý nghĩa trên máy nhiều core
  với L3 không đều, đó là một phép đo khác.

Bất cứ thứ gì được quảng cáo là tăng tốc lớn mà không phải huge pages, chế độ
dataset hay số thread thì nên được đo trước khi tin.

## Số đo

2 vCPU Xeon 2.60 GHz, 3.9 GiB RAM, 1234 × 2 MiB huge pages, thuật toán `rx/0`,
mỗi cấu hình một lần chạy.

| Cấu hình | Hashrate | Tỉ lệ |
| --- | ---: | ---: |
| mặc định: 2 thread, huge pages, prefetch 1 | 814 H/s | 100 % |
| `--no-huge-pages` | 634 H/s | 78 % |
| `--mode light` | 76 H/s | 9 % |
| `-t 1` | 408 H/s | 50 % |
| `--scratchpad-prefetch=0` | 823 H/s | 101 % (nhiễu) |
| `--scratchpad-prefetch=2` | 823 H/s | 101 % (nhiễu) |
| `--no-affinity` | 814 H/s | 100 % (nhiễu) |

Cùng binary, cùng host, ở một phiên ít tải hơn: **1008–1103 H/s**. Độ tản 20–25 %
đó là lý do con số tuyệt đối trong tài liệu gần như vô dụng, và tỉ lệ ở trên mới
là phần dùng được.

Engine C++ trên cùng host, để tham chiếu: **1075.7 H/s**. Khoảng cách tới engine
Zig còn nhỏ hơn khoảng cách giữa hai lần chạy.

## Tự đo

```bash
zmrig --bench=20000      # seed cố định, blob cố định, không tính thời gian dựng dataset
zmrig --report --power 45   # 10 s warm-up + 15 s đo, in một mã
sudo ./oneclick.sh bench    # dừng service trước, rồi đo
```

Quy tắc để phép đo có nghĩa:

1. **Dừng miner trước.** Miner đang chạy giữ huge pages; benchmark sẽ cấp phát
   trong bộ nhớ thường và báo thấp khoảng 20 %.
2. **Đo đúng máy bạn quan tâm.** Hashrate tuyệt đối là thuộc tính của host, không
   phải của binary.
3. **Mỗi cấu hình chạy hai lần.** Dưới 2 % là nhiễu.

Bảng đầy đủ, kèm ngày và các lưu ý, ở [Hiệu năng đo được](/docs/reference/benchmarks).
