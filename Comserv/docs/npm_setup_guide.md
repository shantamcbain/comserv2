# Nginx Proxy Manager Setup Guide

This guide explains how to set up the Nginx Proxy Manager (NPM) for use with the Comserv ProxyManager controller.

## Automated Setup

The Comserv application now includes an automated infrastructure setup feature that can install:
- Docker
- Kubernetes (optional)
- Nginx Proxy Manager

To use the automated setup:

1. Log in to Comserv with an admin account
2. Navigate to `/proxymanager/setup_infrastructure`
3. Follow the on-screen instructions to install the required components

## Manual Setup Prerequisites

If you prefer to set up the components manually, you'll need:

- Docker installed on your server
- Docker Compose installed on your server
- Basic understanding of networking concepts

## Installation Steps

### 1. Install Docker (if not already installed)

```bash
# Update package index
sudo apt update

# Install required packages
sudo apt install -y apt-transport-https ca-certificates curl software-properties-common

# Add Docker's official GPG key
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -

# Add Docker repository
sudo add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"

# Update package index again
sudo apt update

# Install Docker CE
sudo apt install -y docker-ce

# Add your user to the docker group (to run Docker without sudo)
sudo usermod -aG docker $USER

# Apply the new group membership (or log out and back in)
newgrp docker
```

### 2. Install Docker Compose (if not already installed)

```bash
# Download Docker Compose
sudo curl -L "https://github.com/docker/compose/releases/download/v2.18.1/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose

# Apply executable permissions
sudo chmod +x /usr/local/bin/docker-compose

# Verify installation
docker-compose --version
```

### 3. Create Docker Compose File for Nginx Proxy Manager

Create a file named `docker-compose.yml` in a directory of your choice (e.g., `/home/shanta/npm`):

```yaml
version: '3'
services:
  app:
    image: 'jc21/nginx-proxy-manager:latest'
    restart: unless-stopped
    ports:
      # Public HTTP Port:
      - '80:80'
      # Public HTTPS Port:
      - '443:443'
      # Admin Web Port:
      - '81:81'
    environment:
      # These are the default environment variables
      DB_MYSQL_HOST: "db"
      DB_MYSQL_PORT: 3306
      DB_MYSQL_USER: "npm"
      DB_MYSQL_PASSWORD: "npm"
      DB_MYSQL_NAME: "npm"
    volumes:
      - ./data:/data
      - ./letsencrypt:/etc/letsencrypt
    depends_on:
      - db

  db:
    image: 'jc21/mariadb-aria:latest'
    restart: unless-stopped
    environment:
      MYSQL_ROOT_PASSWORD: 'npm'
      MYSQL_DATABASE: 'npm'
      MYSQL_USER: 'npm'
      MYSQL_PASSWORD: 'npm'
    volumes:
      - ./data/mysql:/var/lib/mysql
```

### 4. Start Nginx Proxy Manager

```bash
# Navigate to the directory containing your docker-compose.yml file
cd /home/shanta/npm

# Start the containers in detached mode
docker-compose up -d
```

### 5. Access the Admin Interface

1. Open a web browser and navigate to `http://localhost:81`
2. Log in with the default credentials:
   - Email: `admin@example.com`
   - Password: `changeme`
3. You will be prompted to change the default credentials on first login.

### 6. Generate an API Key

1. Log in to the NPM admin interface
2. Navigate to the user profile settings
3. Generate a new API key
4. Copy the API key for use in the Comserv configuration

### 7. Configure Comserv to Use NPM

Create a configuration file for your environment (e.g., `npm-development.conf`) in the Comserv config directory:

```
<NPM>
    endpoint = http://localhost:81/api
    api_key = your_generated_api_key
    environment = development
    access_scope = full-access
</NPM>
```

## Troubleshooting

### Connection Refused

If you see a "Connection refused" error, check that:
- Docker is running (`docker ps`)
- The NPM container is running (`docker ps | grep nginx-proxy-manager`)
- The container is exposing port 81 correctly

### API Key Issues

If you see authentication errors:
- Verify the API key is correct
- Ensure the API key has not expired
- Check that the user associated with the API key has appropriate permissions

### Docker Not Installed

If Docker is not installed on your development server, you will see mock data in the ProxyManager interface. This is expected behavior to allow development without requiring Docker.

## Production Deployment

For production environments:
- Use strong, unique passwords for the database
- Configure proper SSL certificates
- Set up regular backups of the NPM data directory
- Consider using a reverse proxy for additional security

## Additional Resources

- [Nginx Proxy Manager Official Documentation](https://nginxproxymanager.com/guide/)
- [Docker Documentation](https://docs.docker.com/)
- [Docker Compose Documentation](https://docs.docker.com/compose/)