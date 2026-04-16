FROM node:22-slim

RUN corepack enable && corepack prepare pnpm@latest --activate

WORKDIR /app

COPY scripts/package.json scripts/pnpm-lock.yaml ./
RUN pnpm install --frozen-lockfile

COPY scripts/services/ ./services/
COPY scripts/config/ ./config/
COPY scripts/utils/ ./utils/
COPY scripts/tsconfig.json ./

ARG BUILD_DATE
ARG GIT_REVISION
LABEL build-date=$BUILD_DATE
LABEL git-revision=$GIT_REVISION

CMD ["pnpm", "tsx", "services/oracle-feed.ts"]
