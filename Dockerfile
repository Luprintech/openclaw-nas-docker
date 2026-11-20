# Extends the official OpenClaw image to fix npm global install permissions
# and add runtime dependencies for skills, OAuth flows, and device code pairing.
#
# Why this exists:
#   The base image runs as user 'node' (UID 1000), but npm's global prefix
#   (/usr/local/lib/node_modules) is owned by root. Any 'npm install -g'
#   call — including skill installation — fails with EACCES.
#
# Fix:
#   1. Install runtime tools needed for OpenClaw features and skills:
#      - curl, jq, git, openssl → OAuth flows, device code pairing, session-logs skill
#      - procps, lsof, hostname → process management, networking
#      - uv (Python) → nano-pdf skill and other Python-based skills
#      - ffmpeg → video-frames skill (extract frames/clips from videos)
#      - tmux → tmux skill (remote-control tmux sessions)
#      - gh → github skill (GitHub CLI for issues, PRs, releases)
#   2. Redirect npm's global prefix to /home/node/.npm-global (user-writable)
#   3. Add bin/ directories to PATH so installed binaries are found.

ARG OPENCLAW_VERSION=latest

# uv comes from Astral's official image, pinned by version and digest, instead
# of piping an unpinned install script into a shell. Dependabot updates it.
FROM ghcr.io/astral-sh/uv:0.13.8@sha256:5cc1805e2426484abca4ad46ea783bab281fdb225fd82d8ce6d66a81254bac85 AS uv

FROM ghcr.io/openclaw/openclaw:${OPENCLAW_VERSION}

USER root

# Install runtime dependencies for OpenClaw features and skills
# Base tools: OAuth, networking, process management
# Skill tools: ffmpeg (video-frames), tmux (tmux), jq (session-logs)
# `apt-get upgrade` applies the Debian security fixes published since the
# upstream base image was built.
RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get upgrade -y --no-install-recommends && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      git \
      hostname \
      jq \
      lsof \
      openssl \
      procps \
      ffmpeg \
      tmux \
      wget \
      python3 \
      python3-pip \
      python3-venv && \
    rm -rf /var/lib/apt/lists/*

# Install GitHub CLI (gh) for github skill
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg && \
    chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | tee /etc/apt/sources.list.d/github-cli.list > /dev/null && \
    apt-get update && \
    apt-get install -y gh && \
    rm -rf /var/lib/apt/lists/*

# Install uv (Python package manager) — needed for nano-pdf and other Python skills
COPY --from=uv /uv /uvx /usr/local/bin/
RUN uv --version && uvx --version

# Fix npm global install permissions
RUN mkdir -p /home/node/.npm-global && \
    chown -R node:node /home/node/.npm-global /home/node

ENV NPM_CONFIG_PREFIX=/home/node/.npm-global
ENV PATH="/home/node/.npm-global/bin:${PATH}"

ENV VIRTUAL_ENV=/home/node/.openclaw/python-venv
ENV PATH="${VIRTUAL_ENV}/bin:${PATH}"

COPY --chown=node:node entrypoint.sh /home/node/entrypoint.sh
RUN chmod +x /home/node/entrypoint.sh

USER node

# Install Claude Code CLI for users who prefer Anthropic's terminal workflow.
# The package ships a placeholder bin/claude.exe that its postinstall script
# replaces with the native binary. npm 12 blocks install scripts unless they
# are allowed explicitly, which left the placeholder in place and made
# `claude` fail with "exec format error". The final check fails the build
# instead of publishing an image with a broken CLI.
RUN npm install -g --allow-scripts=@anthropic-ai/claude-code @anthropic-ai/claude-code && \
    claude --version
