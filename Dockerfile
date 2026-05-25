FROM node:24

ARG TZ=America/Los_Angeles
ENV TZ="$TZ"

ENV LANG=en_US.UTF-8 \
    LANGUAGE=en_US:en \
    LC_ALL=en_US.UTF-8

# Install basic development tools and iptables/ipset
RUN apt-get update && apt-get install -y --no-install-recommends \
  aggregate \
  bc \
  build-essential \
  cmake \
  dnsutils \
  fd-find \
  file \
  fzf \
  gh \
  git \
  gnupg2 \
  htop \
  iproute2 \
  ipset \
  iptables \
  jq \
  less \
  locales \
  libssl-dev \
  libpq-dev \
  lsof \
  man-db \
  mold \
  nano \
  openssh-client \
  pkg-config \
  poppler-utils \
  postgresql-client \
  procps \
  protobuf-compiler \
  libprotobuf-dev \
  python3 \
  python3-pip \
  python3-venv \
  redis-tools \
  ripgrep \
  shellcheck \
  socat \
  sudo \
  tmux \
  tree \
  unzip \
  vim \
  zip \
  zsh \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

# Generate en_US.UTF-8 locale
RUN sed -i -e 's/# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen && \
    locale-gen

# Ensure default node user has access to /usr/local/share
RUN mkdir -p /usr/local/share/npm-global && \
  chown -R node:node /usr/local/share

ARG USERNAME=node

# Persist zsh history across container rebuilds.
RUN mkdir /commandhistory \
  && touch /commandhistory/.zsh_history \
  && chown -R $USERNAME /commandhistory

# Set `DEVCONTAINER` environment variable to help with orientation
ENV DEVCONTAINER=true

# Create workspace and config directories and set permissions
RUN mkdir -p /workspace /home/node/.claude /home/node/.codex && \
  chown -R node:node /workspace /home/node/.claude /home/node/.codex

WORKDIR /workspace

ARG GIT_DELTA_VERSION=0.18.2
RUN ARCH=$(dpkg --print-architecture) && \
  wget "https://github.com/dandavison/delta/releases/download/${GIT_DELTA_VERSION}/git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb" && \
  sudo dpkg -i "git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb" && \
  rm "git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb"

# Install hadolint (Dockerfile linter)
ARG HADOLINT_VERSION=2.12.0
RUN ARCH=$(dpkg --print-architecture) && \
  if [ "$ARCH" = "amd64" ]; then HADOLINT_ARCH="x86_64"; else HADOLINT_ARCH="arm64"; fi && \
  wget -O /usr/local/bin/hadolint "https://github.com/hadolint/hadolint/releases/download/v${HADOLINT_VERSION}/hadolint-Linux-${HADOLINT_ARCH}" && \
  chmod +x /usr/local/bin/hadolint

# Install Python CLI tools
RUN pip install --break-system-packages codespell yamllint

# Enable pnpm via corepack (needs root for /usr/local/bin symlinks)
RUN corepack enable && corepack install -g pnpm@latest

# Set up non-root user
USER node

# Install global packages
ENV NPM_CONFIG_PREFIX=/usr/local/share/npm-global
ENV PATH=$PATH:/usr/local/share/npm-global/bin

# Set the default shell to zsh rather than sh
ENV SHELL=/bin/zsh

# Set the default editor and visual
ENV EDITOR=vim
ENV VISUAL=vim

# Default powerline10k theme
ARG ZSH_IN_DOCKER_VERSION=1.2.0
RUN sh -c "$(wget -O- https://github.com/deluan/zsh-in-docker/releases/download/v${ZSH_IN_DOCKER_VERSION}/zsh-in-docker.sh)" -- \
  -p git \
  -p fzf \
  -a "source /usr/share/doc/fzf/examples/key-bindings.zsh" \
  -a "source /usr/share/doc/fzf/examples/completion.zsh" \
  -a "source /home/node/.profile" \
  -a "export HISTFILE=/commandhistory/.zsh_history && export HISTSIZE=10000 && export SAVEHIST=10000 && setopt INC_APPEND_HISTORY HIST_IGNORE_DUPS HIST_IGNORE_SPACE" \
  -x

# Install Claude Code and OpenAI Codex
RUN curl -fsSL https://claude.ai/install.sh | bash
RUN npm install -g @openai/codex
# Install bun
RUN curl -fsSL https://bun.com/install | bash

ARG INSTALL_RUST=true
RUN if [ "$INSTALL_RUST" = "true" ]; then \
      curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y; \
    fi

# Install Rust cargo tools via cargo-binstall (fast pre-built binary installs)
RUN if [ "$INSTALL_RUST" = "true" ]; then \
      . "$HOME/.cargo/env" && \
      curl -L --proto '=https' --tlsv1.2 -sSf https://raw.githubusercontent.com/cargo-bins/cargo-binstall/main/install-from-binstall-release.sh | bash && \
      cargo binstall -y --no-symlinks sccache just cargo-nextest; \
    fi
ENV RUSTC_WRAPPER=sccache

# Copy and set up firewall scripts
COPY init-firewall.sh fw-install.sh /usr/local/bin/
USER root
RUN chmod +x /usr/local/bin/init-firewall.sh /usr/local/bin/fw-install.sh && \
  echo "node ALL=(root) NOPASSWD: /usr/local/bin/init-firewall.sh, /usr/local/bin/fw-install.sh" > /etc/sudoers.d/node-firewall && \
  chmod 0440 /etc/sudoers.d/node-firewall
# Force IPv4 for apt (IPv6 is unreliable in rootless Podman containers)
RUN echo 'Acquire::ForceIPv4 "true";' > /etc/apt/apt.conf.d/99force-ipv4

# Install Playwright system dependencies and browser binaries
RUN npx -y playwright install-deps && npx -y playwright install chromium && npm install -g @playwright/cli@latest

USER node
