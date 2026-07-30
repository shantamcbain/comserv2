# comserv2-openscad — headless OpenSCAD render service
#
# Self-contained, host-agnostic render service. No volume mounts required;
# files travel over the HTTP API (request in -> STL out). Runs on any docker
# host: build here or `docker save comserv2-openscad | ssh host docker load`.
#
# Port: 8083 (8081=phpmyadmin, 8082 reserved for comserv2-whisper, 11434=ollama)

FROM debian:bookworm-slim

RUN apt-get update -o Acquire::Retries=3 && \
    apt-get install -y --no-install-recommends \
      openscad \
      fonts-dejavu-core \
      python3 python3-pip python3-venv \
      curl ca-certificates && \
    apt-get clean && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# Isolated venv for the API wrapper (PEP 668)
RUN python3 -m venv /opt/venv && \
    /opt/venv/bin/pip install --no-cache-dir fastapi uvicorn python-multipart "qrcode[pil]" reportlab

# Non-root user
RUN useradd -m -s /usr/sbin/nologin renderer

COPY templates/ /opt/openscad-service/templates/
COPY app/main.py /opt/openscad-service/app/main.py

RUN chown -R renderer:renderer /opt/openscad-service

USER renderer
WORKDIR /opt/openscad-service

ENV TEMPLATE_DIR=/opt/openscad-service/templates \
    RENDER_TIMEOUT=120 \
    MAX_CONCURRENT_RENDERS=2

EXPOSE 8083

HEALTHCHECK --interval=30s --timeout=10s --retries=3 --start-period=15s \
  CMD curl -fsS http://localhost:8083/healthz || exit 1

CMD ["/opt/venv/bin/uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8083"]
