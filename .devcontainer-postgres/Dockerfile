FROM localhost/claude-devcontainer:latest

COPY container-entrypoint.sh start-servers.sh /usr/local/bin/
USER root
RUN chmod +x /usr/local/bin/container-entrypoint.sh /usr/local/bin/start-servers.sh
USER node
