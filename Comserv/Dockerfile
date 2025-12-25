# Multi-stage build for optimized Comserv Docker image
# Stage 1: Build environment with all dependencies
ARG PERL_VERSION=5.40.0
ARG BASE_IMAGE=perl:5.40.0

FROM ${BASE_IMAGE} as builder

# Install system dependencies for building Comserv (Debian 12 compatible)
RUN apt-get update -o Acquire::Retries=3 -o Acquire::http::Timeout=60 || \
    (sleep 10 && apt-get update -o Acquire::Retries=3 -o Acquire::http::Timeout=60) && \
    apt-get install -y --no-install-recommends \
      build-essential curl git wget pkg-config default-mysql-client libmariadb-dev \
      libssl-dev libexpat-dev zlib1g-dev libxml2-dev locales ca-certificates \
      libc6-dev libgdbm-dev libbz2-dev libdb-dev && \
    echo "en_US.UTF-8 UTF-8" > /etc/locale.gen && locale-gen en_US.UTF-8 && \
    apt-get clean && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# Set locale
ENV LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

# Install cpanm
RUN curl -L https://cpanmin.us | perl - App::cpanminus
# Create application directory
WORKDIR /opt/comserv
ENV PERL_LOCAL_LIB_ROOT=/opt/comserv/local
ENV PERL5LIB=/opt/comserv/local/lib/perl5:$PERL5LIB
ENV PATH=/opt/comserv/local/bin:$PATH

# Copy application files
COPY . .

# Create local lib directory
RUN mkdir -p /opt/comserv/local/lib/perl5

# Install CPAN dependencies
# Note: Do NOT force-rebuild YAML::XS as it causes binary incompatibility with Perl 5.40.0
# Application uses YAML::Tiny for all YAML operations
# Use multiple mirrors for better dependency resolution
RUN cpanm --local-lib=/opt/comserv/local --notest \
    --mirror https://cpan.metacpan.org \
    --mirror https://www.cpan.org \
    --installdeps .

# Verify critical modules
RUN perl -e 'use Catalyst; use DBIx::Class; use Template; use Starman; print "Core modules loaded\n"'

# ===================================================================
# Stage 2: Runtime image
FROM ${BASE_IMAGE}

RUN apt-get update -o Acquire::Retries=3 -o Acquire::http::Timeout=60 || \
    (sleep 10 && apt-get update -o Acquire::Retries=3 -o Acquire::http::Timeout=60) && \
    apt-get install -y --no-install-recommends \
      bash default-mysql-client libmariadb3 libssl3 libxml2 curl locales \
      ca-certificates supervisor && \
    apt-get clean && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

RUN echo "en_US.UTF-8 UTF-8" > /etc/locale.gen && locale-gen en_US.UTF-8
ENV LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

# Create application user
RUN useradd -m -s /bin/bash comserv && mkdir -p /opt/comserv && \
    chown -R comserv:comserv /opt/comserv

WORKDIR /opt/comserv

# Copy from builder
COPY --from=builder --chown=comserv:comserv /opt/comserv /opt/comserv

# Set environment
ENV PERL_LOCAL_LIB_ROOT=/opt/comserv/local
ENV PERL5LIB=/opt/comserv/local/lib/perl5:$PERL5LIB
ENV PATH=/opt/comserv/local/bin:/opt/comserv/script:$PATH
ENV CATALYST_ENV=production CATALYST_DEBUG=0
ENV CPANM_HOME=/opt/comserv/.cpanm

# Create directories
RUN mkdir -p /opt/comserv/root/log /opt/comserv/root/session \
    /opt/comserv/backups /opt/comserv/.cpanm && \
    chown -R comserv:comserv /opt/comserv

# Create marker file to prevent runtime module re-installation
# (all modules are pre-installed in build stage)
RUN touch /opt/comserv/local/.modules_installed && \
    chmod 666 /opt/comserv/local/.modules_installed

# Create supervisor base configuration
RUN mkdir -p /etc/supervisor/conf.d

# Copy supervisor base config (heredoc doesn't work reliably in Docker)
COPY supervisord.conf /etc/supervisor/supervisord.conf
RUN chmod 644 /etc/supervisor/supervisord.conf

# Copy startup script that generates supervisor config with dynamic port
COPY create-supervisor-config.sh /opt/comserv/create-supervisor-config.sh
RUN chmod +x /opt/comserv/create-supervisor-config.sh && \
    chown comserv:comserv /opt/comserv/create-supervisor-config.sh

# Health check - will check dynamic port using /health endpoint
# /health endpoint bypasses database queries and returns immediately
HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 \
    CMD curl -f http://localhost:${WEB_PORT:-3000}/health || exit 1

EXPOSE 3000 5000

# Copy entrypoint script from host (with proper permissions)
COPY docker-entrypoint.sh /opt/comserv/docker-entrypoint.sh
RUN chmod +x /opt/comserv/docker-entrypoint.sh && chown comserv:comserv /opt/comserv/docker-entrypoint.sh

# Don't switch to comserv user - entrypoint runs as root to configure supervisor,
# then supervisord handles dropping privileges for app processes
ENTRYPOINT ["/opt/comserv/docker-entrypoint.sh"]
CMD []

LABEL maintainer="Comserv Development Team"
LABEL description="Comserv Catalyst Web Application - Production Container"
LABEL version="1.0"
