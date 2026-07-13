FROM rust:1.88-bookworm AS rust-builder
RUN apt-get update && apt-get install -y --no-install-recommends clang cmake pkg-config libssl-dev && rm -rf /var/lib/apt/lists/*
WORKDIR /src
COPY core ./core
RUN cargo build --manifest-path core/Cargo.toml --release -p sonar-bridge-daemon

FROM golang:1.25-bookworm AS go-builder
WORKDIR /src/bridges/sonar
COPY bridges/sonar/go.mod bridges/sonar/go.sum ./
RUN go mod download
COPY bridges/sonar ./
RUN go build -tags goolm -trimpath -o /out/matrix-sonar ./cmd/matrix-sonar

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates && rm -rf /var/lib/apt/lists/*
COPY --from=rust-builder /src/core/target/release/sonar-bridge-daemon /usr/local/bin/sonar-bridge-daemon
COPY --from=go-builder /out/matrix-sonar /usr/local/bin/matrix-sonar
USER 65532:65532
ENTRYPOINT ["/usr/local/bin/matrix-sonar"]
