FROM rust:1.90.0 AS builder

ARG PROFILE=release
ARG GIT_REVISION
ENV GIT_REVISION=$GIT_REVISION

WORKDIR /work

COPY Cargo.lock Cargo.toml ./
COPY crates/ ./crates/

RUN apt-get update && apt-get install -y build-essential libssl-dev pkg-config curl cmake clang ca-certificates

RUN cargo build --profile $PROFILE --bin predict-bench --config net.git-fetch-with-cli=true

FROM debian:trixie-slim AS runtime

RUN apt-get update && apt-get -y --no-install-recommends install \
    curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /work/target/release/predict-bench /opt/mysten/bin/
RUN chmod +x /opt/mysten/bin/predict-bench

ARG BUILD_DATE
ARG GIT_REVISION
LABEL build-date=$BUILD_DATE
LABEL git-revision=$GIT_REVISION

ENTRYPOINT ["/opt/mysten/bin/predict-bench"]
