FROM debian:bookworm-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends nginx libnginx-mod-stream ca-certificates \
    && rm -rf /var/lib/apt/lists/*

STOPSIGNAL SIGQUIT
CMD ["nginx", "-g", "daemon off;"]
