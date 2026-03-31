FROM node:24

ARG TZ=America/Los_Angeles
ENV TZ="$TZ"

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
  libssl-dev \
  libpq-dev \
  man-db \
  mold \
  nano \
  openssh-client \
  pkg-config \
  poppler-utils \
  procps \
  protobuf-compiler \
  libprotobuf-dev \
  pkg-config \
  python3 \
  python3-pip \
  python3-venv \
  ripgrep \
  sudo \
  tmux \
  tree \
  unzip \
  vim \
  zip \
  zsh \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

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
RUN mkdir -p /workspace /home/node/.claude && \
  chown -R node:node /workspace /home/node/.claude

WORKDIR /workspace

ARG GIT_DELTA_VERSION=0.18.2
RUN ARCH=$(dpkg --print-architecture) && \
  wget "https://github.com/dandavison/delta/releases/download/${GIT_DELTA_VERSION}/git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb" && \
  sudo dpkg -i "git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb" && \
  rm "git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb"

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

# Install Rust (required for native npm add-ons)
ARG INSTALL_RUST=true
RUN if [ "$INSTALL_RUST" = "true" ]; then \
      curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y; \
    fi

# Copy and set up firewall scripts
COPY init-firewall.sh fw-install.sh /usr/local/bin/
USER root
RUN chmod +x /usr/local/bin/init-firewall.sh /usr/local/bin/fw-install.sh && \
  echo "node ALL=(root) NOPASSWD: /usr/local/bin/init-firewall.sh, /usr/local/bin/fw-install.sh" > /etc/sudoers.d/node-firewall && \
  chmod 0440 /etc/sudoers.d/node-firewall
# Force IPv4 for apt (IPv6 is unreliable in rootless Podman containers)
RUN echo 'Acquire::ForceIPv4 "true";' > /etc/apt/apt.conf.d/99force-ipv4

# Install Playwright system dependencies and browser binaries
RUN npx -y playwright install-deps && npx -y playwright install

USER node
