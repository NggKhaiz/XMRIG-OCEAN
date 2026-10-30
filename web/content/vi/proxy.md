# Proxy: một địa chỉ cho mọi rig

Mười rig ở hai toà nhà, một ví, một kết nối tới pool. `proxy/` làm được điều đó: Node 18+, không dependency, không cần biên dịch.

```bash
sudo ./proxy/install.sh --user=ĐỊA_CHỈ_VÍ --pool=gulf.moneroocean.stream:10001
```

hoặc không cài gì cả:

```bash
node proxy/src/main.js start --user=ĐỊA_CHỈ_VÍ --pool=gulf.moneroocean.stream:10001
```

Đó là toàn bộ phần cài. `install.sh --dry-run` in ra unit systemd trước khi ghi bất cứ thứ gì. Banner in ra đúng dòng lệnh cần gõ trên rig.

## Vì sao có proxy thì tiền nhiều hơn

Ba kiểu mất tiền không liên quan gì tới miner, và cả ba đều cùng một gốc:

1. **Trùng việc.** Nonce Monero chỉ 32 bit. Hai rig tìm cùng một dải thì share tìm được cũng chỉ được trả một lần. Proxy chia byte trên của nonce cho từng rig, giữ 24 bit dưới cho rig — giống `xmrig-proxy`. Cái bẫy: **prefix 0 không phải là prefix**, blob có nonce 0 chính là tín hiệu tắt chế độ extranonce trong miner (`zmrig/src/job.zig:130`). Đưa 0 cho rig là nó quay lại dùng chung dải, im lặng, và doanh thu giảm.
2. **Một độ khó không vừa mọi rig.** Máy 500 H/s và máy 20 kH/s trên cùng một target cho ra một share mỗi giờ và một share mỗi phút. Rig nhỏ chết đói share trong khi vẫn ăn đủ điện. Proxy cấp độ khó riêng cho từng rig, mục tiêu ~15 giây một share.
3. **Bão login.** Pool thấy mỗi rig một login, và pool sau Cloudflare (hoặc gói free của bất cứ dịch vụ nào) giới hạn login rồi ban IP. Một kết nối từ proxy thay cho tất cả, mà mỗi rig vẫn hiện trên dashboard pool như một worker riêng (`--user=ví.rig3`).

Proxy **không** băm. Nó kiểm tra target của từng share (so sánh BigInt, vài micro-giây) rồi chuyển tiếp; pool mới là nơi băm lại. Proxy không thể làm giả công việc, và bản này không thử.

## Kiểm tra trước khi trỏ rig

```bash
node proxy/src/main.js doctor --user=ĐỊA_CHỈ_VÍ --pool=gulf.moneroocean.stream:10001
```

```
ok   pool gulf.moneroocean.stream:10001 answered -- 168 ms
ok   job difficulty -- 60011.2
ok   a 5 kH/s rig would find -- 0.30 shares/hour at this difficulty
```

Dòng cuối là phép tính hay bị bỏ qua: share/giờ = `hashrate × 3600 / difficulty`. 0.30 share/giờ nghĩa là ba tiếng mới có một share — ổn với PPLNS cửa sổ dài, chết với pool có ngưỡng trả cao.

## Đường ra cho rig ở toà nhà khác: một cờ

| Cờ | Đường truyền | Địa chỉ cố định | Bên thứ ba | Kết luận |
|---|---|---|---|---|
| `--tunnel=wireguard` | WireGuard UDP, kernel | `10.66.66.1` | không | **nên dùng** |
| `--tunnel=tailscale` | WireGuard qua coordination server | `*.ts.net` | Tailscale | tốt khi không mở được port |
| `--tunnel=cf` | Cloudflare tunnel có tên, WebSocket | hostname của bạn | Cloudflare | chạy được, thêm một chặng edge |
| `--tunnel=cf-quick` | `*.trycloudflare.com`, WebSocket | ngẫu nhiên, đổi mỗi lần chạy | Cloudflare | **chỉ để demo** |

### WireGuard: mặc định nên chọn

```bash
# một lần, trên máy chạy proxy
node proxy/src/main.js tunnel wireguard --rigs=10 --dir=wg
sudo cp wg/ocean-proxy.conf /etc/wireguard/ocean-proxy.conf
sudo systemctl enable --now wg-quick@ocean-proxy

# chạy bình thường
node proxy/src/main.js start --user=ĐỊA_CHỈ_VÍ --pool=... --tunnel=wireguard
```

Nó sinh mỗi rig một file riêng (`wg/rig-1.conf` …), mỗi file một key và một địa chỉ `10.66.66.2 … 10.66.66.11`. **Một file cho một máy** — dùng chung file là phiên bản WireGuard của lỗi trùng nonce.

Vì sao nên chọn: địa chỉ cố định (đổi IP nhà mạng không phải sửa gì trên rig), UDP trong kernel nên không thêm độ trễ, không phụ thuộc bên thứ ba, và chỉ cần mở **một cổng UDP 51820** trên router — cổng stratum vẫn nằm ở localhost.

### Tailscale: khi không mở được cổng nào

```bash
node proxy/src/main.js start --user=ĐỊA_CHỈ_VÍ --pool=... \
  --tunnel=tailscale --tunnel-token=tskey-auth-...
```

Ba điều cần biết trước khi chọn: Funnel chỉ phục vụ **443/8443/10000**, chỉ TLS, và băng thông bị giới hạn ở mức Tailscale không công bố (đủ cho luồng stratum vài kB/s, không đủ để poll dashboard mỗi giây). Gói free Personal chỉ được dùng **phi thương mại**. Nếu rig nằm trong cùng tailnet thì không cần Funnel: rig trỏ thẳng `<host>.<tailnet>.ts.net:3333`, không lộ gì ra internet.

## Cloudflare: kết luận thẳng

**Quick tunnel không tốt cho farm.** Nó tốt cho đúng một việc: chứng minh trong hai phút rằng đường mạng thông.

| Đặc điểm | Hệ quả khi đào |
|---|---|
| Hostname `*.trycloudflare.com` **đổi mỗi lần restart** | mỗi lần restart phải sửa dòng pool trên từng rig |
| Tunnel **chết theo process** | không sống qua reboot, không có systemd |
| **200 request đồng thời**, quá thì 429 | 10 rig thì được, dashboard refresh mỗi giây thì không |
| **Không có xác thực mặc định** | endpoint trả tiền về ví *của bạn*, ai tìm thấy cũng đào được bằng điện của bạn |
| Tunnel từng xuất hiện trong kết quả tìm kiếm | người lạ tìm ra endpoint |
| Cloudflare nói rõ **không dành cho production** | không có SLA để ai chịu trách nhiệm |
| Chỉ WebSocket | stratum TCP trần không đi được, buộc phải `--ws` |

Vì dòng cuối, `--tunnel=cf-quick` **từ chối chạy nếu thiếu `--ws`**, chứ không im lặng phục vụ rỗng. Và log khởi động in đúng danh sách cảnh báo trên thay vì một URL trông vui vẻ.

Muốn Cloudflare thật thì dùng tunnel có tên:

```bash
node proxy/src/main.js start --user=ĐỊA_CHỈ_VÍ --pool=... \
  --ws --tunnel=cf --tunnel-token=<tunnel-token> --tunnel-host=proxy.example.com
```

Rig kết nối `wss://proxy.example.com/stratum`. Share đi qua WebSocket vẫn được kiểm tra y như qua TCP — cùng một đoạn code protocol, chỉ khác lớp truyền tải (`proxy/src/conn.js`).

## Cờ

Mỗi tính năng là một cờ. Bảng đầy đủ ở `doc/PROXY.md`; những cờ hay dùng:

| Cờ | Mặc định | Việc |
|---|---|---|
| `--user=<ví[.worker]>` | lấy từ rig đầu tiên | ví được trả |
| `--pool=<h:p[,h:p]>` | bắt buộc | pool, nhiều địa chỉ là failover, `tls://` cho stratum+ssl |
| `--bind=<ip>` | `127.0.0.1` | nơi rig kết nối |
| `--ws` / `--tls` | tắt | thêm listener WebSocket / TLS |
| `--allow=<cidr,...>` | loopback + RFC1918 | ai được kết nối |
| `--token=<secret>` | không | mật khẩu stratum mọi rig phải gửi |
| `--target-share=<giây>` | 15 | nhịp share của mỗi rig |
| `--tunnel=<...>` | `none` | đường ra công khai |

## Bảo mật

Proxy trả tiền về ví của bạn; mở nó ra internet là tặng cho người đầu tiên quét thấy cổng. Ba lớp, lớp đầu đã là mặc định:

1. Bind `127.0.0.1`. `--bind=0.0.0.0` bị từ chối nếu không có `--token` hoặc `--allow`.
2. `--allow=<cidr,...>`: kết nối ngoài danh sách bị đóng trước khi đọc một byte stratum.
3. `--token`: chính là mật khẩu stratum — mọi miner đều có ô password, không cần sửa client.

Thêm giới hạn 60 kết nối/phút mỗi IP để một rig kẹt vòng lặp reconnect không thành bão login ở phía pool.

## Khi pool chết

Rig không biết. Socket của rig vẫn mở (không mất 16-30 giây khởi tạo dataset), rig login giữa lúc mất mạng vẫn nhận **job cuối** (vẫn là việc hợp lệ tới khi đổi block), share vẫn được trả lời và đếm vào `absorbed`. Danh sách pool tự xoay: login bị từ chối thì đổi pool ngay, mất kết nối thì backoff 5 giây nhân đôi tới 60 giây.

## Chọn pool nào

Phí là phần nhỏ nhất của quyết định này. Ở 3 kH/s (~62 USD/năm), phí 1 % là **0.62 USD/năm**; một pool làm phương sai tăng gấp đôi tốn hơn thế trong một tháng.

| Pool | Phí | Trả cho cái gì | Khi nào nên chọn |
|---|---|---|---|
| **MoneroOcean** `gulf.moneroocean.stream:10001` | 0 % | tự đổi thuật toán sang coin trả cao nhất | phần cứng đa thuật toán, rig hỗn hợp |
| **SupportXMR** `pool.supportxmr.com:3333` | 0.6 % | phương sai thấp nhất, PPLNS cửa sổ dài | farm nhỏ chỉ RandomX, muốn share đều |
| **C3Pool** `c3pool.com:3333` | 0 % | chịu hashrate thấp, trả số dư nhỏ | một hai rig, hoặc để thử |
| **P2Pool** + `monerod` riêng | 0 % | node 100+ GB đã sync, ~6.7 % hashrate mạng | đã có node, chấp nhận phương sai |

Mặc định của repo: MoneroOcean cho farm CPU muốn lợi nhuận kỳ vọng cao nhất, SupportXMR khi nhịp share đều quan trọng hơn. Đổi pool là đổi một cờ, và danh sách nhiều pool cũng chính là failover:

```bash
node proxy/src/main.js start --user=ĐỊA_CHỈ_VÍ \
  --pool=pool.supportxmr.com:3333,gulf.moneroocean.stream:10001
```

Đừng đọc riêng cột phí: miner ở đây phí developer **0 %**, còn `xmrig` + `xmrig-proxy` là 1 % + 2 % (trừ khi tự biên dịch lại với `-DDUST_XMRIG_PROXY_DONATE=0`).

## Đã đo, và chưa đo

`node --test proxy/tests/` — **43 test, pass 43**: 14 test cho nonce/extranonce/vardiff, 8 test dựng socket thật (hai rig một kết nối pool, share chuyển tiếp đúng job id của pool, pool chết giữa phiên, failover), 14 test cho cờ, danh sách IP và CIDR IPv6, 3 test cho layout cài đặt, 4 test chạy đúng binary (TCP, WebSocket, token, `/status`, `doctor`, SIGTERM không để lại listener). Trên VM 2 vCPU: khởi động → rig TCP có job → rig WebSocket có job → đọc status = **213 ms**; `doctor` tới pool nội bộ = **83 ms**.

**Chưa đo**: thông lượng 10.000 share/giây. Mỗi share là một phép so sánh BigInt và một lần ghi chuỗi, round-trip tới pool lớn hơn hai bậc, nhưng chưa load-test. Một tiến trình phục vụ 255 rig (255 prefix dùng được); hơn nữa thì chạy thêm một tiến trình, đó là câu trả lời tốt hơn một bảng cấp phát dài hơn.

## Lỗi thường gặp

| Hiện tượng | Nguyên nhân | Cách sửa |
|---|---|---|
| `no job yet` trên rig | proxy chưa kết nối được pool | chạy `doctor` trước; proxy giữ login 3 giây rồi mới báo |
| `wrong token` | có `--token` nhưng rig không gửi đúng mật khẩu | rig thêm `-p <token>` |
| `--bind=0.0.0.0 exposes the proxy` | chốt an toàn | thêm `--token` hoặc `--allow` |
| `--tunnel=cf needs --ws` | Cloudflare chỉ đi WebSocket | thêm `--ws` |
| Rig kết nối được mà thu nhập giảm | trùng việc | tìm `overwrote its extranonce` trong log; rig đó cần extranonce (zmrig bật sẵn) |
| `/status` trả 401 | đã đặt token | `curl -H 'Authorization: Bearer <token>' 127.0.0.1:3334/status` |
