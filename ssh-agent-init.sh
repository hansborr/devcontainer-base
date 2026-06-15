# ssh-agent-init.sh — baked into the base devcontainer image at
# /usr/local/bin/. Sourced from ~/.zshenv so EVERY entry point into the
# container shares ONE ssh-agent on a FIXED socket: interactive `podman exec`
# shells AND Claude Code's non-interactive Bash tool (which sources only
# ~/.zshenv). ssh-agent normally prints a random socket path known only to the
# spawning shell, so separate shells would each start their own agent and never
# find each other; pinning the socket here lets them all rendezvous.
#
# The socket lives under ~/.ssh (the shared 'persist' volume, mode 0700), so it
# is reused across rebuilds of a project. A socket left over from a dead agent
# is detected (ssh-add -l exit 2) and replaced.

export SSH_AUTH_SOCK="$HOME/.ssh/agent.sock"

# ssh-add -l exit codes: 0 = agent has keys, 1 = running but empty,
# 2 = cannot connect. (Re)start an agent only when nothing is listening.
ssh-add -l >/dev/null 2>&1
if [ $? -eq 2 ]; then
    rm -f "$SSH_AUTH_SOCK"
    ssh-agent -a "$SSH_AUTH_SOCK" >/dev/null 2>&1
fi

# Interactive shells only: if the agent is empty and the key is present, prompt
# once to unlock it. Claude Code's non-interactive Bash tool skips this and
# never blocks on a passphrase; the key stays decrypted for the container's life.
if [[ -o interactive ]] 2>/dev/null && [ -t 0 ] && [ -f "$HOME/.ssh/id_ed25519" ]; then
    ssh-add -l >/dev/null 2>&1
    if [ $? -eq 1 ]; then
        echo "ssh-agent: unlocking ~/.ssh/id_ed25519 (once per container)…"
        ssh-add "$HOME/.ssh/id_ed25519"
    fi
fi
