FROM python:3.12-slim

ARG UID=1000
ARG GID=1000

WORKDIR /app

COPY pyproject.toml .
COPY README.md .
COPY mavlink_relay_server/ ./mavlink_relay_server/
COPY schema.sql .
COPY manage.py .
COPY docker-entrypoint.sh /entrypoint.sh

RUN pip install --no-cache-dir . && chmod +x /entrypoint.sh

RUN groupadd -r -g "${GID}" relay \
    && useradd -r -u "${UID}" -g relay relay \
    && mkdir -p /data && chown relay:relay /data

USER relay

EXPOSE 14550/udp

ENTRYPOINT ["/entrypoint.sh"]
