FROM ubuntu:24.04

ARG SUI_VERSION=testnet-v1.69.1
ARG NODE_MAJOR=22

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl ca-certificates git build-essential bash \
    && rm -rf /var/lib/apt/lists/*

# Install Node.js
RUN curl -fsSL https://deb.nodesource.com/setup_${NODE_MAJOR}.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*

# Install Sui CLI
RUN curl -fsSL https://github.com/MystenLabs/sui/releases/download/${SUI_VERSION}/sui-${SUI_VERSION}-ubuntu-x86_64.tgz \
    | tar -xz -C /usr/local/bin

COPY docker/predict-sim/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Repo is cloned by the k8s init container into /workspace/repo.
WORKDIR /workspace/repo

ENTRYPOINT ["/entrypoint.sh"]
