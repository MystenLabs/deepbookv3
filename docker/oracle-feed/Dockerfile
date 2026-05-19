FROM node:20-slim

WORKDIR /app

COPY scripts/package.json ./
RUN npm install

COPY scripts/ ./scripts/
COPY packages/predict/sources/ ./packages/predict/sources/

# We need the Move binary and Sui CLI for some scripts, 
# but for the service itself, node is enough if we use pre-deployed IDs.

CMD ["node", "--loader", "tsx", "scripts/services/oracle-feed.ts"]
