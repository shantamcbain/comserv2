# comserv2-search — self-hosted metasearch for the Comserv AI stack
#
# WHY THIS EXISTS
#   OpenRouter's `search_domain_filter` is silently ignored (verified 2026-09-09:
#   a strict en.wikipedia.org filter returned zero Wikipedia results and 16
#   off-filter hosts). To actually control the *extent* of a search — e.g. ENCY
#   searching herbal/EU/traditional sources rather than the North American
#   medical industry — the scope must be enforced by a service we run.
#
# WHAT IT IS
#   SearXNG: a metasearch aggregator. It is NOT a web index — it fans a query
#   out to upstream engines we enable and merges results. Enabling/disabling
#   engines and setting per-query site filters is config, which is the whole
#   point.
#
# Port: 8084 (8081=phpmyadmin, 8082=whisper, 8083=openscad, 11434=ollama)
#
# Files travel over HTTP; no host volume mounts needed for the app to use it.

FROM searxng/searxng:latest

# Non-root by default in the upstream image.
#
# Scope control lives in settings.yml: the engines we allow, and whether
# per-query `site:` / banned-domain filtering is honoured. Keep the engine
# list SHORT and deliberate — every enabled upstream is one more place a
# query can leak to.
USER root
COPY settings.yml /etc/searxng/settings.yml
RUN chown searxng:searxng /etc/searxng/settings.yml || true
USER searxng

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD curl -fsS http://localhost:8080/healthz || exit 1
