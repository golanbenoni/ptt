FROM rust:1.93-bookworm AS build
WORKDIR /src
RUN apt-get update \
    && apt-get install -y --no-install-recommends protobuf-compiler \
    && rm -rf /var/lib/apt/lists/*
COPY server ./server
RUN cargo build --manifest-path server/Cargo.toml --release --locked -p ptt-relay

FROM debian:bookworm-slim
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*
RUN useradd --system --uid 10001 --home-dir /nonexistent --shell /usr/sbin/nologin ptt
COPY --from=build /src/server/target/release/ptt-relay /usr/local/bin/ptt-relay
USER 10001:10001
EXPOSE 47000/udp
ENTRYPOINT ["/usr/local/bin/ptt-relay"]
