FROM ghcr.io/astral-sh/uv:0.11.6-python3.13-trixie

ARG HERMES_REF=main
ARG HERMES_WEBUI_REF=v0.50.278

ENV PYTHONUNBUFFERED=1 \
    PLAYWRIGHT_BROWSERS_PATH=/opt/hermes/.playwright \
    HERMES_HOME=/data \
    PATH="/opt/hermes/.venv/bin:/data/.local/bin:/home/hermes/.nvm/versions/node/v22/bin:/home/hermes/.railway/bin:/usr/local/bin:${PATH}" \
    PYTHONPATH="/opt/hermes-railway:/opt/hermes:/opt/hermes-webui" \
    NVM_DIR="/home/hermes/.nvm"

# ──────────────────────────────────────────────
# Base system dependencies
# ──────────────────────────────────────────────
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      build-essential \
      ca-certificates \
      curl \
      docker-cli \
      ffmpeg \
      gcc \
      git \
      gnupg \
      gosu \
      libffi-dev \
      lsb-release \
      openssh-client \
      procps \
      python3 \
      python3-dev \
      ripgrep \
      tini \
      wget && \
    rm -rf /var/lib/apt/lists/*

# ──────────────────────────────────────────────
# GitHub CLI (gh) — https://github.com/cli/cli/blob/trunk/docs/install_linux.md
# ──────────────────────────────────────────────
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      | gpg --dearmor -o /usr/share/keyrings/githubcli-archive-keyring.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) \
      signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] \
      https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends gh && \
    rm -rf /var/lib/apt/lists/*

# ──────────────────────────────────────────────
# PHP 8.4 + Composer (ondrej/php)
# ──────────────────────────────────────────────
RUN curl -fsSL https://packages.sury.org/php/apt.gpg \
      | gpg --dearmor -o /usr/share/keyrings/sury-php.gpg && \
    echo "deb [signed-by=/usr/share/keyrings/sury-php.gpg] \
      https://packages.sury.org/php/ $(lsb_release -sc) main" \
      > /etc/apt/sources.list.d/sury-php.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
      php8.4 \
      php8.4-cli \
      php8.4-common \
      php8.4-curl \
      php8.4-mbstring \
      php8.4-xml \
      php8.4-zip \
      php8.4-bcmath \
      php8.4-intl \
      php8.4-readline \
      composer && \
    rm -rf /var/lib/apt/lists/*

# ──────────────────────────────────────────────
# nvm + Node 22 + pnpm  (installed as hermes user)
# ──────────────────────────────────────────────
RUN useradd --system --uid 10000 --create-home \
      --home-dir /home/hermes --shell /bin/bash hermes

COPY <<'NVM_INSTALL_EOF' /tmp/install-nvm.sh
#!/bin/bash
set -e
NVM_DIR="/home/hermes/.nvm"
mkdir -p "$NVM_DIR"
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh \
  | PROFILE="/dev/null" bash
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
nvm install 22
nvm alias default 22
nvm use 22
npm install -g pnpm
npm cache clean --force
NVM_INSTALL_EOF
RUN chmod +x /tmp/install-nvm.sh && \
    chown hermes:hermes /tmp/install-nvm.sh && \
    su - hermes -c "bash /tmp/install-nvm.sh" && \
    rm /tmp/install-nvm.sh

# Persist nvm activation for every hermes shell
RUN echo '[ -s "$HOME/.nvm/nvm.sh" ] && . "$HOME/.nvm/nvm.sh"' >> /home/hermes/.bashrc && \
    echo '[ -s "$HOME/.nvm/nvm.sh" ] && . "$HOME/.nvm/nvm.sh"' >> /home/hermes/.profile

# ──────────────────────────────────────────────
# Railway CLI — https://docs.railway.app/guides/cli
# ──────────────────────────────────────────────
RUN curl -fsSL https://railway.app/install.sh | bash

# ──────────────────────────────────────────────
# Hermes Agent
# ──────────────────────────────────────────────
WORKDIR /opt/hermes

RUN git init . && \
    git remote add origin https://github.com/NousResearch/hermes-agent.git && \
    (git fetch --depth 1 origin "${HERMES_REF}" || \
     git fetch --depth 1 origin "refs/tags/${HERMES_REF}:refs/tags/${HERMES_REF}") && \
    git checkout --detach FETCH_HEAD

ENV npm_config_install_links=false

RUN export PATH="/home/hermes/.nvm/versions/node/v22/bin:$PATH" && \
    npm install --prefer-offline --no-audit && \
    npx playwright install --with-deps chromium --only-shell && \
    npm cache clean --force

RUN uv venv && \
    uv pip install --no-cache-dir -e ".[all,messaging]"

RUN chmod -R a+rX /opt/hermes

# ──────────────────────────────────────────────
# Hermes WebUI
# ──────────────────────────────────────────────
WORKDIR /opt/hermes-webui

RUN git init . && \
    git remote add origin https://github.com/nesquena/hermes-webui.git && \
    (git fetch --depth 1 origin "refs/tags/${HERMES_WEBUI_REF}:refs/tags/${HERMES_WEBUI_REF}" || \
     git fetch --depth 1 origin "${HERMES_WEBUI_REF}") && \
    git checkout --detach FETCH_HEAD && \
    uv pip install --python /opt/hermes/.venv/bin/python --no-cache-dir -r requirements.txt && \
    chmod -R a+rX /opt/hermes-webui

RUN uv pip install --python /opt/hermes/.venv/bin/python --no-cache-dir \
    ptyprocess httpx websockets starlette uvicorn

# ──────────────────────────────────────────────
# Railway overlay files
# ──────────────────────────────────────────────
WORKDIR /opt/hermes-railway

COPY admin ./admin
COPY skills ./skills
COPY entrypoint.sh ./entrypoint.sh

RUN chmod +x /opt/hermes-railway/entrypoint.sh && \
    mkdir -p /data && \
    chown -R hermes:hermes \
      /opt/hermes \
      /opt/hermes-webui \
      /data \
      /opt/hermes-railway && \
    git config --system --add safe.directory /opt/hermes && \
    git config --system --add safe.directory /opt/hermes-webui

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=10s --start-period=90s --retries=3 \
    CMD curl -f "http://localhost:${PORT:-8080}/health" || exit 1

ENTRYPOINT ["/usr/bin/tini", "-g", "--", "/opt/hermes-railway/entrypoint.sh"]
