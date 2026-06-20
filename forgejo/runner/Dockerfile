# Runner image: the forgejo-runner binary on top of our dev base (which already has
# the Node/Rust/Python/git toolchains CI jobs need, since the host executor runs jobs
# directly in this container's filesystem — no docker-in-docker).
#
# Stage 1 just carries the binary out of the official runner image. :12 is the current
# runner major (tracks latest 12.x); data.forgejo.org is the documented pull path.
# Pin a full version (e.g. :12.11.1) for reproducible builds. The binary is a static
# Go build from Alpine/musl; the RUN below smoke-tests that it executes on our
# Debian/glibc base and fails the build early if it can't.
FROM data.forgejo.org/forgejo/runner:12 AS runnerbin

FROM localhost/claude-devcontainer:latest
# Base image ends as USER node; switch to root to write /usr/local/bin, then back.
USER root
COPY --from=runnerbin /bin/forgejo-runner /usr/local/bin/forgejo-runner
RUN forgejo-runner --version
USER node
