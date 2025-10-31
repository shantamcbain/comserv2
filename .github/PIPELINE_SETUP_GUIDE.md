# GitHub Actions CI/CD Pipeline Setup Guide

## Overview

This guide walks you through setting up the complete Kubernetes-ready CI/CD pipeline for Comserv with automated testing, building, and deployment to three environments (Development, Staging, Production).

**Pipeline Architecture:**
```
┌─────────────┐
│  Push Code  │
└──────┬──────┘
       │
       ├──▶ 1️⃣  BUILD & TEST (Every push/PR)
       │     ├─ Perl Syntax Check
       │     ├─ Unit Tests
       │     ├─ Integration Tests
       │     ├─ Pod Coverage
       │     └─ YAML/Dockerfile Linting
       │
       ├──▶ 2️⃣  BUILD DOCKER IMAGE
       │     ├─ Multi-stage build
       │     ├─ Layer caching
       │     └─ Artifact optimization
       │
       ├──▶ 3️⃣  PUSH TO REGISTRY
       │     ├─ GitHub Container Registry
       │     ├─ Image scanning
       │     └─ Tag management
       │
       └──▶ 4️⃣  DEPLOY TO ENVIRONMENTS
             ├─ Development (on develop branch)
             ├─ Staging (on main branch)
             └─ Production (on version tags)
```

---

## Prerequisites

### Local Setup (On Each Server)

1. **Install Docker & Docker Compose**
```bash
curl -fsSL https://get.docker.com -o get-docker.sh
sudo sh get-docker.sh
sudo curl -L "https://github.com/docker/compose/releases/download/v2.20.0/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
sudo chmod +x /usr/local/bin/docker-compose
```

2. **Create deployment user**
```bash
sudo useradd -m -s /bin/bash deploy
sudo usermod -aG docker deploy
sudo mkdir -p /home/deploy/.ssh
sudo chmod 700 /home/deploy/.ssh
```

3. **Create directory structure**
```bash
sudo mkdir -p /opt/comserv2
sudo chown deploy:deploy /opt/comserv2
cd /opt/comserv2
git clone https://github.com/YOUR-ORG/comserv2.git .
```

4. **Create backup directory**
```bash
mkdir -p ~/backups
chmod 700 ~/backups
```

---

## GitHub Repository Configuration

### Step 1: Enable GitHub Container Registry

1. Go to your GitHub repository
2. Settings → Developer Settings → Personal Access Tokens
3. Generate new token with:
   - ✅ `write:packages`
   - ✅ `read:packages`
   - ✅ `delete:packages`
4. Copy the token (use it as `GITHUB_TOKEN` in workflows)

### Step 2: Create Repository Secrets

**Navigate to:** Settings → Secrets and variables → Actions

Create the following secrets:

#### Development Server
```
DEV_SERVER_HOST: your-dev-server.com
DEV_SERVER_USER: deploy
DEV_SERVER_SSH_KEY: <paste private key>
DEV_DATABASE_PASS: <secure password>
```

#### Staging Server
```
STAGING_SERVER_HOST: your-staging-server.com
STAGING_SERVER_USER: deploy
STAGING_SERVER_SSH_KEY: <paste private key>
STAGING_DATABASE_PASS: <secure password>
STAGING_ALERT_EMAIL: devops@example.com
```

#### Production Server
```
PROD_SERVER_HOST: your-prod-server.com
PROD_SERVER_USER: deploy
PROD_SERVER_SSH_KEY: <paste private key>
PROD_DATABASE_PASS: <secure password>
PROD_ALERT_EMAIL: ops-team@example.com
SLACK_WEBHOOK_URL: https://hooks.slack.com/services/... (optional)
```

#### Image Registry
```
IMAGE_REGISTRY: yourusername/comserv
```

### Step 3: Configure Environment Branch Protection

**Navigate to:** Settings → Branches → Branch Protection Rules

#### Main Branch (Production Ready)
```
✅ Require pull request reviews before merging (1+ reviews)
✅ Dismiss stale pull request approvals
✅ Require status checks to pass:
   - build-and-test
   - build (docker build)
   - lint
   - security-scan
✅ Require branches to be up to date before merging
✅ Restrict who can push to matching branches
```

#### Develop Branch (Testing)
```
✅ Require pull request reviews before merging (optional)
✅ Require status checks to pass:
   - build-and-test
   - build
```

---

## Server Setup

### Development Server Setup

1. **Create deployment key pair** (on your local machine):
```bash
ssh-keygen -t ed25519 -f ~/.ssh/comserv-dev-deploy -C "comserv-dev-deploy"
# Don't set passphrase for CI/CD
```

2. **Add public key to server** (as deploy user):
```bash
mkdir -p ~/.ssh
echo "$(cat ~/.ssh/comserv-dev-deploy.pub)" >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
```

3. **Clone repository to server**:
```bash
cd ~/
git clone https://github.com/YOUR-ORG/comserv2.git
cd comserv2
```

4. **Create .env file**:
```bash
cd Comserv
cp .env.development .env
# Edit .env with actual database credentials
nano .env
```

5. **Verify Docker setup**:
```bash
docker run hello-world
docker-compose --version
```

### Staging Server Setup

Repeat development setup but with `.env.staging`:
```bash
cd Comserv
cp .env.staging .env
nano .env  # Update credentials
```

### Production Server Setup

Repeat development setup but with `.env.production`:
```bash
cd Comserv
cp .env.production .env
# IMPORTANT: Don't store secrets in .env
# Use GitHub Secrets → exported as environment variables during deployment
```

---

## Database Migration Setup

### Create Database Initialization Script

Create `/opt/comserv2/Comserv/script/deploy_schema.pl` if not present:

```perl
#!/usr/bin/env perl
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Comserv;
use Comserv::Model::DBSchemaManager;

my $app = Comserv->new();
my $schema_mgr = Comserv::Model::DBSchemaManager->new(app => $app);

# Run migrations
print "Running database migrations...\n";
$schema_mgr->deploy_schema();
print "✅ Database schema deployed successfully\n";
```

---

## Workflow Triggers & Behavior

### Build & Test Workflow (`build-and-test.yml`)

**Triggers on:**
- Any push to `main` or `develop` branches
- Any pull request to `main` or `develop`

**Steps:**
1. Run Perl syntax checks
2. Run unit tests
3. Run integration tests (with MariaDB)
4. Check Pod coverage
5. Build Docker image (without push)
6. Lint YAML files
7. Security scan with Trivy

**Duration:** ~8-12 minutes

### Build & Push Registry (`build-push-registry.yml`)

**Triggers on:**
- Successful build-and-test on `main` or `develop`
- Pushed version tags (e.g., `v1.0.0`)
- Manual workflow_dispatch

**Tags pushed to registry:**
- `latest` (for main branch)
- `main`, `develop` (branch names)
- `v1.0.0` (version tags)
- `main-a1b2c3d` (commit SHA)

**Duration:** ~5-8 minutes

### Deploy Workflows (`deploy-to-servers.yml`)

#### Development Deployment
- **Trigger:** Push to `develop` branch
- **Environment:** Development server
- **Behavior:** Auto-deploy to dev
- **Database:** Auto-migrate
- **Approval:** ⚠️ Manual environment approval in GitHub

#### Staging Deployment
- **Trigger:** Push to `main` branch
- **Environment:** Staging server
- **Behavior:** Auto-deploy to staging after tests pass
- **Approval:** ✅ Requires manual environment approval
- **Tests:** Smoke tests after deployment

#### Production Deployment
- **Trigger:** Push version tag (e.g., `v1.0.0`)
- **Environment:** Production server
- **Behavior:** Requires manual environment approval
- **Backup:** Auto-backs up before deployment
- **Tests:** Smoke tests verify deployment
- **Notifications:** Slack alert on completion

---

## First-Time Setup Checklist

- [ ] Create GitHub personal access token
- [ ] Add all secrets to GitHub repository
- [ ] Set up branch protection rules
- [ ] Generate SSH deploy keys
- [ ] Add deploy keys to all servers
- [ ] Clone repository to all servers
- [ ] Create .env files on all servers
- [ ] Test SSH access from GitHub Actions
- [ ] Verify Docker login in workflows
- [ ] Test build workflow manually
- [ ] Test deployment to dev/staging
- [ ] Configure Slack webhooks (optional)

---

## Manual Workflow Triggers

### Trigger Deploy from GitHub UI

1. Go to **Actions** tab
2. Select **Deploy to Servers** workflow
3. Click **Run workflow**
4. Select environment: `development`, `staging`, or `production`
5. Click **Run workflow**

---

## Monitoring & Debugging

### Check Workflow Logs

1. Go to **Actions** tab
2. Click on workflow run
3. Click on failed job
4. Expand any failed step

### Common Issues

#### Docker Build Fails
- Check Dockerfile syntax: `docker run --rm -i hadolint/hadolint < Comserv/Dockerfile`
- Test local build: `cd Comserv && docker build -t comserv:test .`

#### Deployment SSH Fails
- Verify SSH key added to server: `ssh-keyscan <server>`
- Test SSH manually: `ssh -i ~/.ssh/comserv-prod-deploy deploy@<server>`

#### Database Migration Fails
- Check database credentials in `.env`
- Verify database is accessible: `mysql -h<host> -u<user> -p<pass> <database>`
- Check migration logs: `docker-compose logs web-dev`

### View Deployment Logs on Server

```bash
# Recent deployments
cd ~/comserv2
docker-compose logs -f web-dev

# Check container status
docker ps

# Check Docker build cache
docker images

# Test application
curl http://localhost:3000/
```

---

## Kubernetes Migration Path

This pipeline is designed to support future Kubernetes deployment:

1. **Current:** Docker containers on individual servers
2. **Phase 2:** Container registry ready (✅ done)
3. **Phase 3:** Helm charts for Kubernetes
4. **Phase 4:** ArgoCD for GitOps deployment

For Kubernetes migration, you'll need:
- Helm charts (replace docker-compose)
- ArgoCD integration
- Persistent volumes for data
- Ingress configuration
- ConfigMaps for environment variables
- Secrets management (HashiCorp Vault or sealed-secrets)

---

## Security Best Practices

1. **Secrets Management**
   - ✅ Never commit secrets to git
   - ✅ Use GitHub Secrets for sensitive data
   - ✅ Rotate secrets quarterly
   - ✅ Use environment-specific secrets

2. **SSH Key Management**
   - ✅ Use Ed25519 keys (stronger than RSA)
   - ✅ Separate keys per environment
   - ✅ Store keys only in GitHub Secrets
   - ✅ Never commit private keys

3. **Docker Image Security**
   - ✅ Regular dependency updates
   - ✅ Vulnerability scanning with Trivy
   - ✅ Minimal base images
   - ✅ Non-root container user

4. **Database Security**
   - ✅ Environment-specific databases (when possible)
   - ✅ Strong passwords (32+ chars)
   - ✅ Network isolation
   - ✅ Automated backups

---

## Performance Optimization

### Build Speed

1. **Layer Caching** (in Dockerfile)
   - Base image layers cached
   - System dependencies cached
   - CPAN modules cached (largest layer)
   - App code last (invalidates when changed)

2. **GitHub Actions Cache**
   - Perl modules cached across runs
   - Docker layer caching via buildx
   - Estimated build time: 5-8 minutes

### Deployment Speed

1. **Rolling updates** (future with Kubernetes)
2. **Zero-downtime deployments** (health checks)
3. **Automated rollback** capability

---

## Maintenance Schedule

### Weekly
- Monitor workflow execution times
- Check log file sizes

### Monthly
- Review branch protection rules
- Update Perl modules in cpanfile
- Audit GitHub Secrets access

### Quarterly
- Rotate SSH deployment keys
- Update base Docker image
- Review security scan results
- Plan Kubernetes migration tasks

---

## Support & Troubleshooting

For detailed logs and debugging:
```bash
# SSH into server
ssh deploy@<server>

# Check services
docker-compose ps

# View logs
docker-compose logs -f web-dev --tail=100

# Test database
docker-compose exec web-dev mysql -h<host> -u<user> -p<pass> <database>

# Restart services
docker-compose restart
```

---

## Next Steps

1. ✅ Complete the server setup checklist
2. ✅ Push a test commit to develop branch
3. ✅ Monitor the build workflow
4. ✅ Verify deployment to development
5. ✅ Test staging deployment
6. ✅ Create version tag for production test

For Kubernetes migration: See `KUBERNETES_MIGRATION_PLAN.md` (to be created in Phase 3)