# NPM API Configuration Guide

This document explains how to configure and manage NPM (Nginx Proxy Manager) API keys across different Catalyst environments (production, staging, development).

## Environment-Specific Configuration

The application now uses environment-specific configuration files for NPM API keys and settings. These files are located in the `Comserv/config/` directory:

- `npm-production.conf` - Production environment configuration
- `npm-staging.conf` - Staging environment configuration
- `npm-development.conf` - Development environment configuration

### Configuration File Format

Each configuration file follows this format:

```
<NPM>
  api_key = "npm_yourgeneratedkey123_1234567890"
  endpoint = "http://npm-host:81"
  environment = "production"  # or "staging"/"development"
  access_scope = "full"       # or "read-only"/"localhost-only"
</NPM>
```

### Configuration Parameters

- `api_key`: The NPM API key for authentication
- `endpoint`: The base URL of the NPM API
- `environment`: The name of the environment (production, staging, development)
- `access_scope`: The access scope for this environment:
  - `full`: Full access to all API operations
  - `read-only`: Only read operations are allowed
  - `localhost-only`: Only accessible from localhost

## Deployment Strategies

### Docker-Based Deployments

For Docker-based deployments, you can use build arguments to specify the environment:

```dockerfile
# Dockerfile
ARG ENVIRONMENT=production
COPY configs/npm-${ENVIRONMENT}.conf /app/Comserv/config/npm-${ENVIRONMENT}.conf
```

Build with:

```bash
docker build --build-arg ENVIRONMENT=production -t catalyst-app .
```

### Traditional Server Deployments

For traditional server deployments, copy the appropriate configuration file:

```bash
# Deploy script
ENVIRONMENT=production
cp /etc/catalyst/npm-${ENVIRONMENT}.conf /opt/catalyst/Comserv/config/npm-${ENVIRONMENT}.conf
chmod 600 /opt/catalyst/Comserv/config/npm-${ENVIRONMENT}.conf
```

## Security Best Practices

### Key Rotation

Rotate your NPM API keys regularly:

```bash
# Monthly rotation script
curl -X POST $NPM_ENDPOINT/api/tokens/rotate -H "Authorization: Bearer $OLD_KEY"
```

After rotating the key, update the appropriate configuration file.

### Network Isolation

Configure your NPM server to only accept connections from authorized servers:

```nginx
# NPM server configuration
location /api {
   allow 10.0.1.0/24;  # Catalyst servers
   deny all;
}
```

### Audit Logging

The application logs all NPM API access with environment information:

```
[2023-08-15 12:34:56] [INFO] Using NPM environment: production with access scope: full
```

## Environment Matrix

| Environment | Config Path | Key Prefix | Access Scope |
|-------------|-------------|------------|--------------|
| Production | npm-production.conf | npm_prod_ | full |
| Staging | npm-staging.conf | npm_stage_ | read-only |
| Development | npm-development.conf | npm_dev_ | localhost-only |

## Validation Checklist

To verify that your NPM API configuration is working correctly:

```bash
# Set the environment
export CATALYST_ENV=production

# Start the application
cd /opt/catalyst
./script/comserv_server.pl

# Check the logs for NPM API configuration messages
tail -f logs/application.log | grep "NPM environment"
```

## Troubleshooting

### Common Issues

1. **"NPM API key not configured"**: This warning appears when the application cannot find a valid API key. Check that the configuration file exists and has the correct permissions.

2. **"Failed to load NPM config"**: This error occurs when the configuration file exists but cannot be parsed. Check the syntax of the configuration file.

3. **"This environment is read-only"**: This message appears when trying to perform write operations in a read-only environment. Check the `access_scope` setting in your configuration file.

### Debugging

To enable debug logging for NPM API calls:

```bash
export CATALYST_DEBUG=1
./script/comserv_server.pl
```

This will show detailed information about NPM API calls in the application log.