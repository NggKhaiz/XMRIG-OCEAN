# Ocean Pool image: the pool plus the zmrig verifier it needs to check shares.
#
#   docker build -f deploy/Dockerfile -t ocean-pool .
#   docker run --rm -p 3333:3333 -p 8080:8080 \
#     -e DAEMON=http://node.example:18081 \
#     -v pool-data:/app/pool/data ocean-pool
#
# Stage 1 builds zmrig from the sources in this repository, so the verifier and
# the miner are always the same code. Stage 2 has no compiler in it.

FROM node:20-bookworm AS zmrig

ARG ZIG_VERSION=0.13.0

RUN apt-get update \
 && apt-get install -y --no-install-recommends g++ make ca-certificates curl xz-utils \
 && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-linux-x86_64-${ZIG_VERSION}.tar.xz" -o /tmp/zig.tar.xz \
 && mkdir -p /opt/zig \
 && tar -xJf /tmp/zig.tar.xz -C /opt/zig --strip-components=1 \
 && ln -s /opt/zig/zig /usr/local/bin/zig \
 && zig version

WORKDIR /src

# build.sh compiles the C++ RandomX engine from src/ and links it with the Zig
# miner from zmrig/. `--portable` keeps the binary runnable on any x86-64 host,
# not just the machine that built the image.
COPY src ./src
COPY zmrig ./zmrig

RUN ZIG=/usr/local/bin/zig ./zmrig/build.sh --jobs 2 --portable --output /out \
 && /out/zmrig --version


FROM node:20-bookworm-slim AS runtime

RUN apt-get update \
 && apt-get install -y --no-install-recommends libstdc++6 tini ca-certificates \
 && rm -rf /var/lib/apt/lists/*

COPY --from=zmrig /out/zmrig /usr/local/bin/zmrig

WORKDIR /app

COPY pool ./pool

RUN mkdir -p /app/pool/data \
 && chown -R node:node /app/pool/data \
 && chmod 0755 /usr/local/bin/zmrig

USER node

ENV NODE_ENV=production \
    PORT=3333 \
    HTTP_PORT=8080 \
    BIND=0.0.0.0 \
    STATE_FILE=/app/pool/data/state.json \
    AUDIT_FILE=/app/pool/data/audit.jsonl \
    VERIFIER_BINARY=/usr/local/bin/zmrig

EXPOSE 3333 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s \
  CMD node -e "fetch('http://127.0.0.1:'+(process.env.HTTP_PORT||8080)+'/healthz').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"

ENTRYPOINT ["/usr/bin/tini", "--", "node", "pool/src/index.js", "--config", "pool/config.json"]
