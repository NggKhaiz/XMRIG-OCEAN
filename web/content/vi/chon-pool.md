# Chọn pool, và đừng để bị chặn IP

Có hai khoản chi phí không bao giờ xuất hiện trên biểu đồ hashrate: pool trả ít hơn quảng cáo, và cái IP không kết nối được nữa. Khoản đầu là vài phần trăm, khoản sau là 100 % thu nhập.

Số liệu dưới đây lấy từ chính trang của các pool, bảng port họ công bố, FAQ của `xmrpool.eu`, và thống kê công khai (`cryptunit`, `xmr.pub`), kiểm tra tháng 10/2026. Phí và mức trả tối thiểu thay đổi; port và chính sách ban thì ít đổi hơn. `./oneclick.sh plan --pool=<tên>` in ra đúng thứ repo này sẽ dùng.

## Bảng ngắn

| | Pool | Phí | Trả tối thiểu | Endpoint |
|---|---|---:|---:|---|
| **1** | MoneroOcean | 0 % | 0.003 XMR | `gulf.moneroocean.stream:10001` |
| **2** | SupportXMR | 0.6 % | 0.1 XMR | `pool.supportxmr.com:3333` |
| 3 | C3Pool | 0 % | 0.003 XMR | `c3pool.com:3333` |
| — | P2Pool (qua `xmr.pub`) | 0 % | ~0.0004 XMR | `pool.xmr.pub:3333` mini · `:3334` nano |
| — | HeroMiners | 0.9 % | 0.01 XMR | `monero.herominers.com:10191` |
| — | xmrpool.eu | 0.9 % | 0.07 XMR | `xmrpool.eu:3333`, `:443` cho mạng chỉ mở 443 |

Tên ngắn dùng trực tiếp: `--pool=moneroocean`, `supportxmr`, `c3pool`, `xmrpool`, `herominers`, `p2pool`, `p2pool-nano`.

Vì sao thứ tự này:

1. **MoneroOcean trả nhiều nhất trên mỗi hash với CPU**, vì nó chuyển rig sang coin họ RandomX đang đắt nhất rồi trả bằng XMR. Các bài đánh giá độc lập ghi mức chênh 10–30 % so với pool một thuật toán — lớn hơn mọi khác biệt phí trong bảng. Cần `--algo=auto` (mặc định ở đây) để pool biết được phép chuyển.
2. **SupportXMR là lựa chọn ít dao động.** Pool lớn nhất, tìm block thường xuyên, phí 0.6 %. Chọn khi con số mỗi ngày đều đặn quan trọng hơn mức tối đa, hoặc làm pool dự phòng sau MoneroOcean.
3. **C3Pool** 0 %, tối thiểu 0.003 XMR — cùng hình dạng với MoneroOcean nhưng không đổi thuật toán. Dự phòng thứ hai tốt.

## Chống ban: những gì phần mềm giờ tự làm

Pool ban IP vì ba lý do, và cả ba trước đây đều vô hình:

| Nguyên nhân | Miner ngây thơ | Repo này |
|---|---|---|
| Sai ví, sai port, TLS nhầm chỗ | thử lại mỗi 5 s, mãi mãi, từ đúng cái IP đó | nhận diện đúng loại từ chối, **thôi thử pool đó 30 phút**, in cách sửa (`zmrig/src/stratum.zig`, `proxy/src/upstream.js`) |
| `your IP is banned` | kết nối lại ngay, ban kéo dài thêm | nghỉ pool đó 15 phút rồi sang pool kế |
| Rig ép xung sinh share sai | gửi tiếp, ăn ban 10 phút → 1 giờ (`xmrpool.eu`) | sau 3 share bị gọi là invalid, **dừng gửi 10 phút** và nói rõ lý do (`miner.zig`) |
| Hai mươi rig reboot cùng lúc | trùng thời điểm = login flood | mỗi lần thử lại lệch ±20 % |

Cooldown tính theo từng pool: pool từ chối ví không chặn pool dự phòng. `--ban-cooldown=<giây>` chỉnh (mặc định 900); riêng trường hợp sai ví/bị từ chối tài khoản bị kẹp tối thiểu 30 phút, vì chờ vài giây không sửa được lỗi đó.

## Bị chặn: phần không ai kiểm thử

Thực tế rig mất kết nối vì **DNS bị lọc** nhiều hơn vì pool ban. Trường hợp đã ghi nhận: Quad9 (`9.9.9.9`) trả NXDOMAIN cho `gulf.moneroocean.stream`, resolver lọc mã độc của Cloudflare (`1.1.1.2`) làm điều tương tự với `pool.supportxmr.com`. Một số ISP chặn cả nhóm domain đào coin, và nhiều mạng VPS/công ty chỉ mở 80 và 443.

Bốn cách sống qua, xếp theo thứ tự nên dùng:

1. **Pool dự phòng khác domain.** `--failover=moneroocean,c3pool` ghi thêm pool vào `config.json`; miner chỉ dùng khi pool đầu không tới được hoặc từ chối IP này.
2. **Hostname theo khu vực** (cùng pool, khác tên DNS — dùng khi chỉ alias mặc định bị lọc). MoneroOcean có tiền tố `us-or`, `us-va`, `us-oh`, `de`, `fi`, `fr`, `jp`, `sg`; SupportXMR có endpoint `eu`/`us`/`asia` trên trang của họ.
3. **Port 443 kèm TLS**, trông như HTTPS bình thường:
   - MoneroOcean `gulf.moneroocean.stream:443` (và `20128`, `20032`)
   - SupportXMR `pool.supportxmr.com:443` (và `9000`)
   - xmrpool.eu `xmrpool.eu:443` ("for firewall bypass", theo bảng port của họ)

   Dùng `--pool=tls://host:443` (hoặc `tls://` trong danh sách failover) để miner biết port đó cần TLS.
4. **`--connect-to`** với IP đã phân giải ở nơi khác. Cách này giữ nguyên SNI và Host cho TLS, chỉ đổi địa chỉ dial:

   ```bash
   dig +short gulf.moneroocean.stream   # từ một mạng phân giải được
   zmrig -o gulf.moneroocean.stream:10001 --connect-to 1.2.3.4:10001 -u <ví>
   ```

Cách 4 là chữa cháy, không phải giải pháp: IP đổi là mất kết nối. Ưu tiên 1–3.

## Những gì vẫn chưa xử lý được

- **Pool chặn theo quốc gia**: client không thể biết, nó chỉ nhận một câu từ chối. Cooldown giúp không thành ban, nhưng không làm pool đó chạy được.
- **Mạng chỉ có IPv6**: miner dial đúng thứ DNS trả về; nếu bản ghi AAAA bị lọc thì dùng cách 4.
- **Giới hạn tần suất share** (không phải login) ở một số pool: phần mềm thấy nó dưới dạng reject và quarantine sẽ dừng stream, nhưng cách đúng là giảm `--target-share` để có ít share hơn, mỗi share lớn hơn.

## MoneroOcean hay SupportXMR, cụ thể

Chạy mỗi bên một tuần rồi so `xmrPerDay` ở cùng `hashrate` trên `/status` của proxy (`doc/PROXY.md` §7b):

```bash
# tuần 1
./oneclick.sh install --pool=moneroocean --wallet=<ví>
# tuần 2
./oneclick.sh install --pool=supportxmr --wallet=<ví> --failover=moneroocean
```

MoneroOcean thắng khi phần chênh đổi thuật toán là thật với CPU này (nó thay đổi theo coin đang hot); SupportXMR thắng khi không, và luôn thắng về độ ổn định. Đo rồi quyết — con số đổi theo tháng.
