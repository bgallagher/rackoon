# syntax=docker/dockerfile:1.7
# Rackoon for the web: the Python backend, the built React UI, spec/ and the themes, in one non-root image.
# Build from the repository root:  docker build -f web/Dockerfile -t rackoon-web .
# Run it on your tailnet, never on the open internet (docs/web.md).

# --- the UI ---------------------------------------------------------------------------------------------------------
FROM node:22.11.0-bookworm-slim AS ui
WORKDIR /ui
COPY web/frontend/package.json web/frontend/package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY web/frontend/ ./
RUN npm run build

# --- the backend's dependencies -------------------------------------------------------------------------------------
FROM python:3.12.8-slim-bookworm AS deps
COPY --from=ghcr.io/astral-sh/uv:0.5.11 /uv /usr/local/bin/uv
ENV UV_COMPILE_BYTECODE=1 UV_LINK_MODE=copy UV_PROJECT_ENVIRONMENT=/app/.venv UV_PYTHON_DOWNLOADS=never
WORKDIR /src
COPY web/backend/pyproject.toml web/backend/uv.lock ./
RUN uv sync --frozen --no-dev --no-install-project
COPY web/backend/rackoon ./rackoon
RUN uv sync --frozen --no-dev --no-editable \
    && find /app/.venv -name '*.dist-info' -path '*pip*' -prune -exec rm -rf {} + \
    && rm -rf /app/.venv/bin/pip* /app/.venv/lib/python3.12/site-packages/pip

# --- the image ------------------------------------------------------------------------------------------------------
FROM python:3.12.8-slim-bookworm
ARG VERSION=dev
LABEL org.opencontainers.image.title="Rackoon" \
      org.opencontainers.image.description="Agentless SSH server manager for self-hosters, in the browser" \
      org.opencontainers.image.source="https://github.com/bgallagher/rackoon" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.licenses="NOASSERTION"
# No pip, no setuid helpers; one unprivileged user that owns only /data.
RUN python -m pip uninstall -y pip setuptools wheel >/dev/null 2>&1 || true; \
    rm -rf /usr/local/lib/python3.12/ensurepip /root/.cache; \
    find / -xdev -perm /6000 -type f -exec chmod a-s {} + 2>/dev/null || true; \
    groupadd --system --gid 10001 rackoon \
    && useradd --system --uid 10001 --gid rackoon --home-dir /data --no-create-home --shell /usr/sbin/nologin rackoon \
    && mkdir -p /data && chown rackoon:rackoon /data && chmod 700 /data
COPY --from=deps /app/.venv /app/.venv
COPY --from=ui /ui/dist /app/static
COPY spec/commands.json spec/command-library.json /app/spec/
COPY apple/Apps/RackoonMac/Resources/themes.json /app/spec/themes.json
# Demo mode answers the Services screen with two of the spec's sanitized captures.
COPY spec/fixtures/services/synthetic-root-failed.out.txt spec/fixtures/services/ubuntu-user-units-and-processes.out.txt \
     /app/spec/fixtures/services/
ENV PATH="/app/.venv/bin:$PATH" PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 \
    RACKOON_DATA=/data RACKOON_STATIC=/app/static RACKOON_SPEC=/app/spec RACKOON_HOST=0.0.0.0 RACKOON_PORT=8080 \
    RACKOON_VERSION=${VERSION}
USER 10001:10001
WORKDIR /data
VOLUME ["/data"]
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD ["python", "-c", "import sys, urllib.request; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8080/api/health', timeout=4).status == 200 else 1)"]
STOPSIGNAL SIGTERM
ENTRYPOINT ["python", "-m", "rackoon.app"]
