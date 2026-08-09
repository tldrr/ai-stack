# Adapted from AgentMemory's Coolify all-in-one deployment at
# d60652a7058773fa9428fa720eda38942f12f014 (Apache-2.0).
ARG III_VERSION=0.11.2
FROM iiidev/iii:${III_VERSION} AS iii-image

FROM node:22.18.0-slim

ARG AGENTMEMORY_VERSION=0.9.28
ARG III_VERSION=0.11.2
ARG III_SDK_VERSION=0.11.2

RUN apt-get update \
 && apt-get install -y --no-install-recommends openssl ca-certificates tini gosu curl \
 && rm -rf /var/lib/apt/lists/*

COPY --from=iii-image /app/iii /usr/local/bin/iii

WORKDIR /opt/agentmemory
COPY patch-import-index.mjs /tmp/patch-import-index.mjs
RUN printf '{"name":"agentmemory-deploy","version":"1.0.0","private":true,"overrides":{"iii-sdk":"%s"}}\n' "${III_SDK_VERSION}" > package.json \
 && npm install "@agentmemory/agentmemory@${AGENTMEMORY_VERSION}" --no-fund --no-audit \
 && node /tmp/patch-import-index.mjs /opt/agentmemory/node_modules/@agentmemory/agentmemory/dist \
 && rm /tmp/patch-import-index.mjs \
 && rm -rf /opt/agentmemory/node_modules/@xenova/transformers/.cache \
 && ln -s /data/transformers-cache /opt/agentmemory/node_modules/@xenova/transformers/.cache \
 && ln -s /opt/agentmemory/node_modules/.bin/agentmemory /usr/local/bin/agentmemory

ENV AGENTMEMORY_III_VERSION=${III_VERSION} \
    TINI_SUBREAPER=1

COPY --chmod=0644 graph-backfill.mjs /opt/agentmemory/graph-backfill.mjs
COPY --chmod=0755 entrypoint.sh /usr/local/bin/agentmemory-entrypoint.sh
RUN sed -i 's/\r$//' /usr/local/bin/agentmemory-entrypoint.sh

EXPOSE 3111 3113

HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
  CMD curl -fsS http://127.0.0.1:3111/agentmemory/livez || exit 1

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/agentmemory-entrypoint.sh"]
