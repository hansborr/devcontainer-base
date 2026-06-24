FROM node:24

ARG TZ=America/Chicago
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
  gawk \
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
  rsync \
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

# Install Claude Code
RUN curl -fsSL https://claude.ai/install.sh | bash

# Install the TypeScript language server (and tsc) for editor/agent LSP support
RUN npm install -g typescript typescript-language-server

# Install OpenAI Codex via the native standalone installer.
#
# The installer puts a launcher symlink in CODEX_INSTALL_DIR and the actual binary
# (plus bundled ripgrep/bubblewrap) under $CODEX_HOME/packages/standalone. We split
# those two locations on purpose:
#   - build-time CODEX_HOME=/home/node/.codex-dist  -> binary lives in the image
#     layer: it survives rebuilds, is refreshed when the image is rebuilt, and is
#     never shadowed by the runtime volume mount.
#   - runtime  CODEX_HOME=/home/node/.codex         -> a persistent volume holding
#     only auth.json/config.toml, so `codex login` survives container rebuilds.
# The launcher in ~/.local/bin is an absolute symlink into /home/node/.codex-dist,
# so it keeps working even though /home/node/.codex is a volume mount at runtime.
ENV PATH=$PATH:/home/node/.local/bin
RUN CODEX_HOME=/home/node/.codex-dist \
    CODEX_INSTALL_DIR=/home/node/.local/bin \
    CODEX_NON_INTERACTIVE=1 \
    curl -fsSL https://chatgpt.com/codex/install.sh | sh
# Runtime state dir: codex reads config.toml + credentials from $CODEX_HOME (the
# codex-config volume), so logins persist. Per codex-rs core/src/config, CODEX_HOME
# overrides the ~/.codex default. The binary + bundled rg/bwrap stay in the image at
# /home/node/.codex-dist/packages/standalone/current/{bin/codex,codex-path/rg,codex-resources/bwrap}.
ENV CODEX_HOME=/home/node/.codex

# Make ~/.ssh resolve to the shared 'persist' volume (seed it once on the host with
# seed-ssh-key.sh). Keeps the encrypted key out of the image and avoids relabeling
# the host's ~/.ssh under SELinux.
RUN ln -sfn /home/node/persist/.ssh /home/node/.ssh

# Install bun
RUN curl -fsSL https://bun.com/install | bash

ARG INSTALL_RUST=true
RUN if [ "$INSTALL_RUST" = "true" ]; then \
      curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y && \
      . "$HOME/.cargo/env" && \
      rustup component add rust-analyzer rust-src; \
    fi

# Install Rust cargo tools via cargo-binstall (fast pre-built binary installs)
RUN if [ "$INSTALL_RUST" = "true" ]; then \
      . "$HOME/.cargo/env" && \
      curl -L --proto '=https' --tlsv1.2 -sSf https://raw.githubusercontent.com/cargo-bins/cargo-binstall/main/install-from-binstall-release.sh | bash && \
      cargo binstall -y --no-symlinks sccache just cargo-nextest; \
    fi
ENV RUSTC_WRAPPER=sccache
ENV SCCACHE_DIR=/home/node/persist/cache/sccache
ENV BUN_INSTALL_CACHE_DIR=/home/node/persist/cache/bun
# The bun installer only appends its bin dir to ~/.bashrc/~/.zshrc, which
# non-interactive shells never source (devcontainer postCreate/postStart hooks,
# Claude Code's Bash tool). Bake it onto the image PATH so `bun`/`bunx` resolve
# everywhere, mirroring how codex's ~/.local/bin is handled above. Placed after
# the Rust/cargo layers to keep their (expensive, network-bound) cache intact.
ENV PATH=$PATH:/home/node/.bun/bin

# Route per-toolchain caches onto the shared 'persist' volume so they survive
# rebuilds AND dedupe across projects. Everything is one btrfs filesystem, so
# node_modules/target reflink (COW) cheaply against these stores regardless of
# where a worktree lives. pnpm: store on persist + reflink imports. cargo:
# symlink only the registry/git caches (NOT all of ~/.cargo — its bin/ holds the
# image-baked sccache/just/nextest). The persist dirs are created at shell start
# via ~/.zshenv (persist is a runtime volume, absent at build time). A project's
# own .npmrc/pnpm config still wins over these user-global defaults.
RUN printf '%s\n%s\n' \
      'store-dir=/home/node/persist/cache/pnpm' \
      'package-import-method=clone-or-copy' \
      >> /home/node/.npmrc
RUN if [ "$INSTALL_RUST" = "true" ]; then \
      rm -rf /home/node/.cargo/registry /home/node/.cargo/git && \
      ln -sfn /home/node/persist/cache/cargo/registry /home/node/.cargo/registry && \
      ln -sfn /home/node/persist/cache/cargo/git /home/node/.cargo/git; \
    fi

# User-global rust-analyzer config (memory/CPU caps). Lives in the image layer,
# so it applies to every Rust project and survives rebuilds.
COPY --chown=node:node rust-analyzer.toml /home/node/.config/rust-analyzer/rust-analyzer.toml

# Copy and set up firewall scripts + the shared ssh-agent bootstrap + shared
# persist runtime dirs + the worktree / cross-project clone helpers.
COPY init-firewall.sh fw-install.sh ssh-agent-init.sh init-persist-dirs.sh /usr/local/bin/
COPY wt.sh /usr/local/bin/wt
COPY refclone.sh /usr/local/bin/refclone
COPY ssh_config_github.conf /etc/ssh/ssh_config.d/10-devcontainer.conf
USER root
RUN chmod +x /usr/local/bin/init-firewall.sh /usr/local/bin/fw-install.sh /usr/local/bin/ssh-agent-init.sh /usr/local/bin/init-persist-dirs.sh /usr/local/bin/wt /usr/local/bin/refclone && \
  chmod 0644 /etc/ssh/ssh_config.d/10-devcontainer.conf && \
  echo "node ALL=(root) NOPASSWD: /usr/local/bin/init-firewall.sh, /usr/local/bin/fw-install.sh" > /etc/sudoers.d/node-firewall && \
  chmod 0440 /etc/sudoers.d/node-firewall
# Force IPv4 for apt (IPv6 is unreliable in rootless Podman containers)
RUN echo 'Acquire::ForceIPv4 "true";' > /etc/apt/apt.conf.d/99force-ipv4

# Prefer IPv4 over IPv6 in glibc name resolution.
# This container black-holes IPv6 loopback: `::1` is assigned to `lo` but
# packets to it are silently dropped (not refused), and `localhost` otherwise
# sorts to `::1` first (RFC 6724 default precedence) while dev services bind
# IPv4-only. Without this, curl / Node / Rust / psql hang on `::1` until the
# connect timeout instead of failing fast on 127.0.0.1, breaking readiness
# loops and stalling `playwright install` downloads. Bumping the IPv4-mapped
# prefix above ::/0 makes getaddrinfo return 127.0.0.1 ahead of ::1.
RUN echo 'precedence ::ffff:0:0/96  100' >> /etc/gai.conf

# Install Playwright system dependencies and browser binaries.
# Browsers land in the default ~/.cache/ms-playwright and live in the IMAGE LAYER
# on purpose (same anti-shadowing logic as Codex's .codex-dist above): do NOT mount
# a volume over ~/.cache/ms-playwright. A volume there would shadow this baked
# Chromium and pin a stale build across base rebuilds — and the image layer is
# already shared across every project FROM this base (better dedup than a
# per-project volume). Refreshed whenever the base image is rebuilt.
RUN npx -y playwright install-deps && npx -y playwright install chromium && npm install -g @playwright/cli@latest

USER node

# Bake the shared ssh-agent hook into ~/.zshenv (sourced by every zsh, including
# Claude Code's non-interactive Bash tool) and the agent aliases into ~/.zshrc
# (interactive shells). Both files are image layers, so these survive container
# rebuilds and never need to be recreated in a running container.
RUN printf '\n%s\n%s\n' \
      '# Shared ssh-agent (fixed socket) for all shells, incl. Claude Code Bash tool' \
      '[ -f /usr/local/bin/ssh-agent-init.sh ] && source /usr/local/bin/ssh-agent-init.sh' \
      >> /home/node/.zshenv && \
    printf '\n%s\n%s\n' \
      '# Ensure shared persist cache/worktree dirs exist for shell-launched tools' \
      '[ -x /usr/local/bin/init-persist-dirs.sh ] && /usr/local/bin/init-persist-dirs.sh 2>/dev/null || true' \
      >> /home/node/.zshenv && \
    printf '\n%s\n%s\n%s\n' \
      '# Sandbox devcontainer: default the agents to skip-prompt modes' \
      "alias claude='claude --dangerously-skip-permissions'" \
      "alias codex='codex --yolo'" \
      >> /home/node/.zshrc && \
    printf '\n%s\n%s\n%s\n' \
      '# Worktree / cross-project clone helpers (cd into the created path)' \
      'wt() { local d; d="$(command wt "$@")" || return; cd "$d"; }' \
      'refclone() { local d; d="$(command refclone "$@")" || return; cd "$d"; }' \
      >> /home/node/.zshrc
