# Mạng kén chọn: Cloudflare, proxy, egress hẹp

VPS "kén chọn" thường rơi vào một trong bốn trường hợp:

1. Chỉ mở 443 ra ngoài (443/tcp), chặn 3333, 10001, 5555…
2. Bắt buộc TLS, chặn stratum trần hoặc DPI cắt gói tin lạ.
3. Bắt buộc đi qua proxy của tổ chức.
4. Cho phép một dải IP nhất định (anycast của CDN, IP của relay nội bộ).

Engine Zig xử lý cả bốn. Engine C++ không có WebSocket nên không xử lý được (1) và phần lớn (2).

## Một cờ cho trường hợp phổ biến nhất

```bash
sudo ./oneclick.sh install --wallet YOUR_WALLET \
  --pool my-relay.example.com \
  --cloudflare=my-relay.example.com --ws-path /pool
```

`--cloudflare` nghĩa là: `wss://<host>:443<path>`, TLS bật, engine `zmrig`. Installer từ chối cấu hình nếu bạn ép `--engine xmrig` cùng với nó, thay vì ghi ra một config mà engine đó không đọc được.

Dạng tương đương khi chạy tay:

```bash
./zmrig/out/zmrig -o wss://my-relay.example.com:443/pool -u YOUR_WALLET -p x
```

## Cần một relay? Worker 40 dòng

Cloudflare Workers mở được TCP thô và nói WebSocket — đúng cây cầu cần thiết. Miner nói `wss://<worker>/relay/<token>`, Worker nối tới pool `host:3333`.

```js
import { connect } from "cloudflare:sockets";

export default {
  async fetch(request, env) {
    const token = new URL(request.url).pathname.split("/").pop();
    if (!env.TOKEN || token !== env.TOKEN) return new Response("forbidden", { status: 403 });
    if (request.headers.get("Upgrade") !== "websocket") return new Response("websocket only", { status: 426 });

    const [host, port] = (env.POOL || "pool.example.com:3333").split(":");
    const socket = connect({ hostname: host, port: Number(port) });

    const pair = new WebSocketPair();
    const client = pair[0];
    const server = pair[1];
    server.accept();

    const writer = socket.writable.getWriter();
    const reader = socket.readable.getReader();
    const encoder = new TextEncoder();
    const decoder = new TextDecoder();

    server.addEventListener("message", (event) => {
      writer.write(encoder.encode(String(event.data).replace(/\r?\n$/, "") + "\n"));
    });
    server.addEventListener("close", () => { try { socket.close(); } catch (e) {} });

    (async () => {
      let buffer = "";
      for (;;) {
        const { value, done } = await reader.read();
        if (done) break;
        buffer += decoder.decode(value, { stream: true });
        let index;
        while ((index = buffer.indexOf("\n")) >= 0) {
          const line = buffer.slice(0, index).replace(/\r$/, "");
          buffer = buffer.slice(index + 1);
          if (line) server.send(line);
        }
      }
      try { server.close(1000, "pool closed"); } catch (e) {}
    })().catch(() => {});

    return new Response(null, { status: 101, webSocket: client });
  },
};
```

Đặt `POOL` và một `TOKEN` dài trong biến môi trường của Worker, deploy, rồi:

```bash
sudo ./oneclick.sh install --wallet YOUR_WALLET \
  --pool your-worker.workers.dev --cloudflare \
  --ws-path /relay/YOUR_TOKEN --yes
```

Ba lưu ý thật:

- Worker là relay byte thuần: nó không thấy ví của bạn, pool thấy IP của Worker chứ không phải IP VPS. Nhưng Worker cũng thấy toàn bộ lưu lượng stratum, nên hãy tự host nếu bạn không muốn điều đó.
- Worker có giới hạn CPU-time/connection, gói free có thể ngủ. Với rig chạy 24/7, gói trả phí hoặc relay riêng ổn định hơn.
- Đọc điều khoản của CDN trước khi đẩy traffic mining qua đó. Đây là quyết định của bạn, không phải của tool.

## Proxy

```bash
# HTTP CONNECT, có basic auth
sudo ./oneclick.sh install ... --proxy 'http://user:pass@10.0.0.5:3128'

# SOCKS5, có user/pass và DNS từ xa (proxy phân giải tên pool)
sudo ./oneclick.sh install ... --proxy 'socks5://user:pass@10.0.0.5:1080'
```

Proxy kết hợp được với `--cloudflare`: tunnel mở qua proxy trước, TLS và WebSocket upgrade chạy bên trong.

## Chọn IP ra: `--connect-to`

Giữ tên pool cho SNI/`Host`, nhưng nối tới một IP cụ thể:

```bash
sudo ./oneclick.sh install ... --pool pool.example.com:443 \
  --cloudflare --connect-to 203.0.113.10:443
```

Dùng khi DNS trả về IP ngoài dải được phép, hoặc khi bạn muốn đi qua một anycast node cụ thể. Log sẽ in `Pool … connect 203.0.113.10:443, Host: pool.example.com` khi chạy `--check`, để bạn xác nhận trước khi start.

## Tin CA riêng / pin chứng chỉ

```bash
sudo ./oneclick.sh install ... --tls-ca /path/to/ca.pem
```

Installer copy file vào `/etc/zmrig/tls-ca.pem` và trỏ pool tới đó. Lý do phải copy: unit chạy với `PrivateTmp=true`, nên file trong `/tmp` có thể biến mất sau khi restart.

`--tls-insecure` được nhận để tương thích dòng lệnh cũ nhưng **không bật**: TLS client của Zig 0.13 không có tuỳ chọn bỏ kiểm tra. Với relay tự ký, hãy dùng `--tls-ca`.

## Giữ kết nối sống

CDN thường cắt WebSocket im lặng sau ~100 giây. Miner mặc định gửi `keepalived` mỗi 60 giây khi không có traffic khác, và tự ngắt nếu pool im lặng 300 giây:

```bash
--keepalive-interval 60   # 0 = tắt keepalive
--idle-timeout 300        # 0 = không bao giờ tự ngắt
```

Nếu pool của bạn im lặng dài (ví dụ pool chờ job mới), đặt `--idle-timeout 0`. Nếu mạng chập chờn, giảm xuống 120 để phát hiện đứt sớm hơn.

## Reconnect

Sau một phiên đã login thành công mà socket đứt, miner nối lại **ngay** (200 ms) và vẫn giữ worker tính hash trên job cũ, nên một cú rớt 1 giây không mất một phút hashing. Các lần thất bại liên tiếp giãn dần: 200 ms, 500 ms, 1 giây, rồi `--retry-pause` (mặc định 5 giây). Bộ đếm không reset khi xoay pool, nên pool chết không bị đập mỗi 5 giây.

## Kiểm tra

```bash
sudo ./oneclick.sh status        # transport, hashrate, shares
sudo ./oneclick.sh logs 40       # "login ok", "share accepted", lỗi TLS nếu có
sudo ss -tnp | grep zmrig        # socket thật đang mở, IP đích thật
```

Muốn thử toàn bộ đường đi mà không cần pool thật: bộ test mạng trong repo dựng pool giả, TLS shim, proxy HTTP/SOCKS5 và WebSocket trên máy bạn — xem [Kiểm thử](#kiem-thu).

Tiếp: [Giám sát](#giam-sat).
