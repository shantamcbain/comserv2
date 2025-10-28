# Multi-stage build for optimized Comserv Docker image
# Stage 1: Build environment with all dependencies
ARG PERL_VERSION=5.40.0
ARG BASE_IMAGE=perl:5.40.0

FROM ${BASE_IMAGE} as builder

# Install system dependencies for building and running Comserv
RUN apt-get update && apt-get install -y --no-install-recommends \
    # Build tools
    build-essential \
    curl \
    git \
    wget \
    # Database and network tools
    mysql-client \
    libmysqlclient-dev \
    libssl-dev \
    libmariadb-dev \
    # Required libraries
    libexpat-dev \
    zlib1g-dev \
    libjson-c-dev \
    libxml2-dev \
    # Utilities
    locales \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Set locale
RUN echo "en_US.UTF-8 UTF-8" > /etc/locale.gen && \
    locale-gen en_US.UTF-8
ENV LANG=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8

# Install cpanm (CPAN client)
RUN curl -L https://cpanmin.us | perl - App::cpanminus

# Create application directory structure
WORKDIR /opt/comserv
ENV PERL_LOCAL_LIB_ROOT=/opt/comserv/local
ENV PERL5LIB=/opt/comserv/local/lib/perl5:$PERL5LIB
ENV PATH=/opt/comserv/local/bin:$PATH

# Copy application files
COPY . .

# Create local lib directory for local installations
RUN mkdir -p /opt/comserv/local/lib/perl5

# Install all CPAN dependencies from cpanfile
RUN cpanm --local-lib=/opt/comserv/local --installdeps . && \
    cpanm --local-lib=/opt/comserv/local --reinstall --force YAML::XS JSON::XS

# Verify critical modules are installed
RUN perl -e 'use Catalyst; use DBIx::Class; use Template; use Starman; print "Core modules loaded successfully\n"'

# ===================================================================
# Stage 2: Runtime image (minimal size)
FROM ${BASE_IMAGE}

# Install only runtime dependencies (minimal)
RUN apt-get update && apt-get install -y --no-install-recommends \
    # Runtime essentials
    mysql-client \
    libmysqlclient21 \
    libssl3 \
    libxml2 \
    # Utilities
    curl \
    locales \
    ca-certificates \
    # Process management
    supervisor \
    && rm -rf /var/lib/apt/lists/*

# Set locale
RUN echo "en_US.UTF-8 UTF-8" > /etc/locale.gen && \
    locale-gen en_US.UTF-8
ENV LANG=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8

# Create application user (security best practice)
RUN useradd -m -s /bin/bash comserv && \
    mkdir -p /opt/comserv && \
    chown -R comserv:comserv /opt/comserv

# Set working directory
WORKDIR /opt/comserv

# Copy pre-built application and local lib from builder stage
COPY --from=builder --chown=comserv:comserv /opt/comserv /opt/comserv

# Set environment variables
ENV PERL_LOCAL_LIB_ROOT=/opt/comserv/local
ENV PERL5LIB=/opt/comserv/local/lib/perl5:$PERL5LIB
ENV PATH=/opt/comserv/local/bin:/opt/comserv/script:$PATH
ENV CATALYST_ENV=production
ENV CATALYST_DEBUG=0

# Create necessary directories with proper permissions
RUN mkdir -p /opt/comserv/root/log && \
    mkdir -p /opt/comserv/root/session && \
    mkdir -p /opt/comserv/backups && \
    chown -R comserv:comserv /opt/comserv

# Create supervisor configuration directory
RUN mkdir -p /etc/supervisor/conf.d

# Add supervisor configuration for Starman
COPY <<'EOF' /etc/supervisor/conf.d/comserv.conf
[program:comserv-starman]
command=/opt/comserv/local/bin/starman --workers=4 --port=3000 --app /opt/comserv/script/comserv_server.pl
directory=/opt/comserv
user=comserv
environment=CATALYST_ENV=production,PERL5LIB=/opt/comserv/local/lib/perl5
autostart=true
autorestart=true
startsecs=10
stopasgroup=true
stdout_logfile=/opt/comserv/root/log/starman.log
stderr_logfile=/opt/comserv/root/log/starman_error.log
EOF

# Health check script
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD curl -f http://localhost:3000/ || exit 1

# Expose port
EXPOSE 3000

# Create startup script
RUN cat > /opt/comserv/docker-entrypoint.sh << 'EOF'
#!/bin/bash
set -e

# Verify database connection
if [ -n "$DB_HOST" ]; then
    echo "Waiting for database at $DB_HOST:${DB_PORT:-3306}..."
    until nc -z "$DB_HOST" "${DB_PORT:-3306}"; do
        echo "Database is unavailable - sleeping..."
        sleep 1
    done
    echo "Database is available!"
fi

# Initialize database if needed
if [ ! -f "/opt/comserv/.db_initialized" ]; then
    echo "Initializing database..."
    cd /opt/comserv
    perl script/initialize_db.pl 2>&1 || echo "Database may already be initialized"
    touch /opt/comserv/.db_initialized
fi

# Start supervisor
exec /usr/bin/supervisord -c /etc/supervisor/supervisord.conf
EOF

RUN chmod +x /opt/comserv/docker-entrypoint.sh && \
    chown comserv:comserv /opt/comserv/docker-entrypoint.sh

# Switch to non-root user
USER comserv

# Use entrypoint script
ENTRYPOINT ["/opt/comserv/docker-entrypoint.sh"]
CMD []

# Labels for metadata
LABEL maintainer="Comserv Development Team"
LABEL description="Comserv Catalyst Web Application - Production Container"
LABEL version="1.0"