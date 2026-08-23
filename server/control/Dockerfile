FROM rust:1.93-bookworm AS build
WORKDIR /src
COPY server ./server
RUN cargo build --manifest-path server/Cargo.toml --release --locked -p ptt-control

FROM debian:bookworm-slim
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*
RUN useradd --system --uid 10001 --home-dir /nonexistent --shell /usr/sbin/nologin ptt
COPY --from=build /src/server/target/release/ptt-control /usr/local/bin/ptt-control
USER 10001:10001
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/ptt-control"]
