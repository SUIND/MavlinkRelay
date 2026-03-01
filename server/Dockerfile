FROM python:3.12-slim

WORKDIR /app

# Copy pyproject.toml, README and source for layer caching
COPY pyproject.toml .
COPY README.md .
COPY mavlink_relay_server/ ./mavlink_relay_server/

# Install package without cache
RUN pip install --no-cache-dir .

# Expose UDP port for QUIC
EXPOSE 14550/udp

# Default command with config file
CMD ["mavlink-relay-server", "--config", "/config/config.yaml"]
