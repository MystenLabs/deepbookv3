FROM rust:1.90.0 AS builder

ARG PROFILE=release
ARG GIT_REVISION
ENV GIT_REVISION=$GIT_REVISION

WORKDIR work

COPY Cargo.lock Cargo.toml ./
COPY crates/ ./crates/
COPY docker/predict-server/entry.sh ./

RUN apt-get update && apt-get install -y build-essential libssl-dev pkg-config curl cmake clang ca-certificates
ENV PATH="/root/.cargo/bin:${PATH}"

RUN cargo build --profile $PROFILE --bin deepbook-predict-server --config net.git-fetch-with-cli=true

FROM debian:trixie-slim AS runtime

RUN apt-get update
RUN apt-get -y --no-install-recommends install wget \
        iputils-ping procps bind9-host bind9-dnsutils \
        curl iproute2 git ca-certificates libpq-dev \
        postgresql

COPY --from=builder /work/target/release/deepbook-predict-server /opt/mysten/bin/
COPY --from=builder /work/entry.sh .
RUN ["chmod", "+x", "/opt/mysten/bin/deepbook-predict-server"]
RUN ["chmod", "+x", "entry.sh"]

CMD ["./entry.sh"]
