---
title: Phí 0 %, kiểm chứng được
description: Một khoản phí developer tốn gì trên RandomX, những gì đã xoá trong cây mã này, và các lệnh chứng minh binary không có pool thứ hai và không có ví.
image: https://nggkhaiz.github.io/ZMRIG/img/og-vi.png
---

# Phí 0 %, kiểm chứng được

Bản này đào **100 % cho pool và ví bạn cấu hình**. Không phí developer, không chia
thời gian, không phiên stratum thứ hai, không ví ẩn.

Lời tuyên bố không đáng gì nếu không có cách kiểm tra, nên phần kiểm tra đứng
trước.

```bash
./scripts/verify-fee-free.sh                 # kiểm tra mã nguồn + binary
./scripts/verify-fee-free.sh --source-only   # không cần binary
```

Script khẳng định sáu điều:

1. Hai hằng số donate đều là `0`.
2. `DonateStrategy` không còn trong cây mã và trong `CMakeLists.txt`.
3. Không có địa chỉ ví và hostname donate nào dưới `src/`.
4. `Network` không còn phần donate.
5. Binary đã build không chứa ví developer hay endpoint donate.
6. Binary in `DONATE 0%` kể cả khi bị truyền `--donate-level=9`.

Cách kiểm tra tay:

```bash
strings build/xmrig | grep -Ei 'donate\.|moneroocean\.stream|^[48][1-9A-HJ-NP-Za-km-z]{95}$'
# -> không có gì

./build/xmrig --dry-run --url pool.example.com:3333 --user TEST --donate-level=9 | grep DONATE
# -> DONATE       0% (fee-free build)

curl -s http://127.0.0.1:18080/2/summary | jq .miner.donate_level
# -> 0
```

Trong lúc chạy, log không bao giờ in `dev donate started`, và API HTTP báo
`"donate_level": 0`.

## Bản gốc làm gì

XMRig gốc giữ phí trong `src/net/strategies/DonateStrategy.cpp`:
`Pools::donateLevel()` trả `donate-level` (mặc định 1, tối thiểu 1), và `Network`
chạy một chiến lược thứ hai: khoảng mỗi 100 phút, nó tạm dừng pool của bạn một
phút và kết nối tới pool của developer
(`m_idleTime = (100 - level) * 60 s`, `m_donateTime = level * 60 s`). Pool donate
nhận hash.

Ở nhánh MoneroOcean mà bản này bắt nguồn, endpoint đó là
`xmrig.moneroocean.stream:10001/20001` với ví hardcode, và phí chỉ được tắt im
lặng khi host pool đầu tiên chứa `moneroocean.stream` — nghĩa là ai đào ở nơi
khác đều trả nó.

## Những gì đã xoá ở đây

| File | Thay đổi |
| --- | --- |
| `src/donate.h` | `kDefaultDonateLevel = 0`, `kMinimumDonateLevel = 0`; không địa chỉ nào trong cây |
| `src/net/strategies/DonateStrategy.{h,cpp}` | đã xoá |
| `CMakeLists.txt` | nguồn donate bỏ khỏi target |
| `src/net/Network.{h,cpp}` | bỏ `m_donate`; không chiến lược thứ hai, không đường submit donate, không tick |
| `src/core/Miner.{h,cpp}` | `setJob(job, donate)` → `setJob(job)`; chỉ số job luôn là 0 |
| `src/base/net/stratum/Pools.{h,cpp}` | `donateLevel()` là `constexpr` trả 0; bỏ mẹo "tắt phí nếu pool khớp" |
| `src/base/kernel/config/BaseTransform.cpp` | `--donate-level` / `--donate-over-proxy` vẫn phân tích và cố ý bỏ qua |
| `src/core/config/Config_default.h` | `"donate-level": 0` |
| `src/Summary.cpp` | in `DONATE 0% (fee-free build)` |

`--donate-level` và `--donate-over-proxy` vẫn **được nhận** để script, config và
dashboard cũ chạy tiếp. Giá trị của chúng không làm gì, và miner ghi log rằng nó
đang bỏ qua thay vì lặng lẽ tôn trọng một con số nó không thể trả.

## Vì sao đây cũng là thay đổi tốc độ

Một vòng donate trên RandomX không phải 1 % thời gian:

- pool của developer có seed khác → dựng lại dataset 2 GiB;
- mọi thread bị dừng và khởi động lại → VM và JIT dựng lại, scratchpad 2 MiB bị
  fault lại;
- cửa sổ nonce đặt lại và các hash đang bay bị mất;
- thêm hai phiên pool mỗi vòng (connect, login, job).

Bỏ phí vì thế trả về hơn 1 % — thường 2–4 % hashrate thật trên RandomX, cộng
toàn bộ phần thời gian đó.

## Địa chỉ công bố không phải phí

Địa chỉ donate của dự án này là tài liệu: người có thể chép, không code path nào
đọc. Nó nằm ở
[`doc/DONATE.md`](https://github.com/NggKhaiz/ZMRIG/blob/master/doc/DONATE.md)
và không có trong `src/`, `zmrig/`, `pool/` hay `oneclick.sh` — đúng như thứ mà
phần kiểm tra kiểm tra. Gửi hay không là một lời mời, không phải một khoản charge.

## Giấy phép

XMRig là GPL-3.0. Xoá mã donate là thay đổi được phép trên mã nguồn bạn đã nhận;
header bản quyền và giấy phép giữ nguyên. Bản gốc sống bằng 1 % đó; bản này không
lấy gì và công bố một địa chỉ tuỳ chọn cho người cứ muốn gửi.
