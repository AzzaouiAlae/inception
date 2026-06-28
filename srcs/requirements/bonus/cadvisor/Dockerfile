FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y wget ca-certificates && rm -rf /var/lib/apt/lists/*

RUN wget -q -O /usr/local/bin/cadvisor \
    https://github.com/google/cadvisor/releases/download/v0.57.0/cadvisor-v0.57.0-linux-amd64 && \
    chmod +x /usr/local/bin/cadvisor

EXPOSE 8080

CMD ["sh", "-c", "exec /usr/local/bin/cadvisor --port=$CADVISOR_PORT --housekeeping_interval=1s --docker_only=true"]