# GitHub Secrets Setup Template

## Overview

This file serves as a checklist for all secrets that need to be configured in GitHub for the CI/CD pipeline to function.

**⚠️ IMPORTANT:** Never commit actual secret values to this repository. This file serves as a TEMPLATE only.

---

## Repository-Level Secrets

Create these under: **Settings → Secrets and variables → Actions** (Repository secrets)

### Container Registry

```
Name: IMAGE_REGISTRY
Value: yourusername/comserv
Description: GitHub Container Registry image name (without ghcr.io prefix)
Example: john-dev/comserv
```

### Optional: Slack Integration

```
Name: SLACK_WEBHOOK_URL
Value: https://hooks.slack.com/services/TXXXXXXXXX/BXXXXXXXXX/XXXXXXXXXXXXXXXX
Description: Slack incoming webhook for deployment notifications
Optional: Only needed if Slack notifications are desired
```

---

## Development Environment Secrets

Create these under: **Settings → Environments → development → Environment secrets**

### SSH Access to Development Server

```
Name: DEV_SERVER_HOST
Value: dev-workstation.example.com
Description: Hostname or IP of development server
Type: Development server hostname
```

```
Name: DEV_SERVER_USER
Value: deploy
Description: Linux user on development server (should be part of docker group)
Type: System user
```

```
Name: DEV_SERVER_SSH_KEY
Value: -----BEGIN OPENSSH PRIVATE KEY-----
       [entire private key content here]
       -----END OPENSSH PRIVATE KEY-----
Description: Ed25519 private SSH key for deploying to development
Type: SSH private key file (WITHOUT passphrase)
Generated: ssh-keygen -t ed25519 -f ~/.ssh/comserv-dev-deploy -C "comserv-dev-deploy"
```

### Database Configuration (Development)

```
Name: DB_HOST
Value: db.example.com
Description: Database server hostname
Type: Database hostname
```

```
Name: DB_PASS
Value: dev_password_min_16_chars_recommended
Description: Development database password
Type: Secure password (minimum 16 characters)
```

---

## Staging Environment Secrets

Create these under: **Settings → Environments → staging → Environment secrets**

### SSH Access to Staging Server

```
Name: STAGING_SERVER_HOST
Value: staging-server.example.com
Description: Hostname or IP of staging server
Type: Staging server hostname
```

```
Name: STAGING_SERVER_USER
Value: deploy
Description: Linux user on staging server
Type: System user
```

```
Name: STAGING_SERVER_SSH_KEY
Value: -----BEGIN OPENSSH PRIVATE KEY-----
       [entire private key content here]
       -----END OPENSSH PRIVATE KEY-----
Description: Ed25519 private SSH key for deploying to staging
Type: SSH private key file (WITHOUT passphrase)
Generated: ssh-keygen -t ed25519 -f ~/.ssh/comserv-staging-deploy -C "comserv-staging-deploy"
```

### Database Configuration (Staging)

```
Name: DB_HOST_STAGING
Value: db-staging.example.com
Description: Staging database server hostname
Type: Database hostname
```

```
Name: DB_PASS_STAGING
Value: staging_password_min_20_chars_recommended
Description: Staging database password (should be MORE secure than dev)
Type: Secure password (minimum 20 characters)
```

### Monitoring (Staging)

```
Name: ALERT_EMAIL
Value: devops@example.com
Description: Email address for deployment alerts
Type: Email address
```

### Notifications (Staging)

```
Name: SLACK_WEBHOOK_URL
Value: https://hooks.slack.com/services/TXXXXXXXXX/BXXXXXXXXX/XXXXXXXXXXXXXXXX
Description: Slack webhook for staging deployment notifications
Type: Slack webhook URL
Optional: Only needed if Slack notifications are desired
```

---

## Production Environment Secrets

Create these under: **Settings → Environments → production → Environment secrets**

### SSH Access to Production Server (⚠️ CRITICAL)

```
Name: PROD_SERVER_HOST
Value: prod-server.example.com
Description: Hostname or IP of production server
Type: Production server hostname
Security: Use only internally accessible hostname
```

```
Name: PROD_SERVER_USER
Value: deploy
Description: Linux user on production server
Type: System user
```

```
Name: PROD_SERVER_SSH_KEY
Value: -----BEGIN OPENSSH PRIVATE KEY-----
       [entire private key content here]
       -----END OPENSSH PRIVATE KEY-----
Description: Ed25519 private SSH key for deploying to production
Type: SSH private key file (WITHOUT passphrase)
Generated: ssh-keygen -t ed25519 -f ~/.ssh/comserv-prod-deploy -C "comserv-prod-deploy"
Security: ⚠️ CRITICAL - Store only in GitHub Secrets, never in files
```

### Database Configuration (Production - ⚠️ CRITICAL)

```
Name: DB_HOST_PROD
Value: db-prod.example.com
Description: Production database server hostname
Type: Database hostname
Security: Should be on private network, not internet-accessible
```

```
Name: DB_NAME_PROD
Value: comserv_production
Description: Production database name
Type: Database name
```

```
Name: DB_USER_PROD
Value: comserv
Description: Production database user
Type: Database username
```

```
Name: DB_PASS_PROD
Value: production_password_min_32_chars_VERY_SECURE
Description: Production database password
Type: Very secure password (minimum 32 characters, mixed case, numbers, symbols)
Security: ⚠️ CRITICAL - Must be extremely strong
Examples: "P@ssw0rd!2024#Comserv#Production@Secure"
```

### Monitoring & Alerting (Production)

```
Name: ALERT_EMAIL
Value: ops-team@example.com
Description: Email address for production alerts
Type: Email address
```

### PagerDuty Integration (Production - Optional)

```
Name: PAGERDUTY_INTEGRATION_KEY
Value: xxxxxxxxxxxxxxxxxxxxxxxx
Description: PagerDuty integration key for critical alerts
Type: PagerDuty API key
Optional: Only needed if PagerDuty integration is desired
```

### Slack Notifications (Production - Optional)

```
Name: SLACK_WEBHOOK_URL
Value: https://hooks.slack.com/services/TXXXXXXXXX/BXXXXXXXXX/XXXXXXXXXXXXXXXX
Description: Slack webhook for production deployment notifications
Type: Slack webhook URL
Optional: Only needed if Slack notifications are desired
Security: Use #production-deployments channel (private)
```

---

## SSH Key Generation Guide

### Generate Development SSH Key

```bash
ssh-keygen -t ed25519 -f ~/.ssh/comserv-dev-deploy -C "comserv-dev-deploy"
# Leave passphrase empty when prompted
# Public key: ~/.ssh/comserv-dev-deploy.pub
# Private key: ~/.ssh/comserv-dev-deploy
```

### Generate Staging SSH Key

```bash
ssh-keygen -t ed25519 -f ~/.ssh/comserv-staging-deploy -C "comserv-staging-deploy"
# Leave passphrase empty when prompted
```

### Generate Production SSH Key

```bash
ssh-keygen -t ed25519 -f ~/.ssh/comserv-prod-deploy -C "comserv-prod-deploy"
# Leave passphrase empty when prompted
# ⚠️ CRITICAL: Store ONLY in GitHub Secrets
# ⚠️ CRITICAL: Never add to ~/.ssh/config
# ⚠️ CRITICAL: Never backup in plaintext
```

---

## Copy Private Key to GitHub

### View Private Key Content

```bash
cat ~/.ssh/comserv-prod-deploy
```

### Store in GitHub Secret

1. Go to Settings → Secrets and variables → Actions
2. Click "New repository secret" (or environment secret)
3. Name: `PROD_SERVER_SSH_KEY`
4. Value: Paste entire content from above command
5. Click "Add secret"

---

## Deploy SSH Key to Server

### Add Public Key to Server

**On the server as `deploy` user:**

```bash
mkdir -p ~/.ssh
chmod 700 ~/.ssh
```

**Get public key from your local machine:**

```bash
cat ~/.ssh/comserv-prod-deploy.pub
```

**Add to server's authorized_keys:**

```bash
echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIxxxxxxxxxxxxxxxx comserv-prod-deploy" >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
```

### Verify SSH Access

```bash
ssh -i ~/.ssh/comserv-prod-deploy deploy@your-prod-server.com "echo 'SSH works!'"
```

---

## Password Generation Guidelines

### Development Password

- Minimum: 16 characters
- Pattern: `dev_password_change_me`
- Complexity: Simple (this is just for dev testing)

### Staging Password

- Minimum: 20 characters
- Pattern: Mix of upper, lower, numbers, symbols
- Example: `Stg@Pass2024!Comserv`
- Complexity: Medium (mirrors production environment)

### Production Password ⚠️ CRITICAL

- Minimum: 32 characters
- Pattern: Mix of upper, lower, numbers, symbols, special chars
- Example: `P@ss#2024!Comserv$Prod_Secure_DB01`
- Complexity: Very High
- Generator: Use `openssl rand -base64 32` to generate
- Rules:
  - ✅ Must include: Upper, lower, numbers, symbols
  - ✅ No sequential characters
  - ✅ No dictionary words
  - ✅ No repeated characters (more than 2 consecutive)
  - ❌ No username patterns
  - ❌ No environment names in password

### Generate Secure Password

```bash
# Generate 32-character random password
openssl rand -base64 32

# Alternative: Use password manager
# Example tools: 1Password, LastPass, Bitwarden, KeePass
```

---

## Slack Webhook Setup (Optional)

### Create Slack App

1. Go to https://api.slack.com/apps
2. Click "Create New App"
3. Select "From scratch"
4. Name: "GitHub Deployments"
5. Workspace: Select your workspace
6. Click "Create App"

### Enable Incoming Webhooks

1. In app settings, click "Incoming Webhooks"
2. Toggle "Activate Incoming Webhooks" → ON
3. Click "Add New Webhook to Workspace"
4. Select channel: "#deployments" (or create it)
5. Click "Authorize"
6. Copy webhook URL

### Add to GitHub

1. Settings → Secrets and variables → Actions
2. New repository secret
3. Name: `SLACK_WEBHOOK_URL`
4. Value: Paste webhook URL
5. Click "Add secret"

---

## Verification Checklist

After adding all secrets, verify:

### Development Environment

- [ ] `DEV_SERVER_HOST` set
- [ ] `DEV_SERVER_USER` set to "deploy"
- [ ] `DEV_SERVER_SSH_KEY` is valid private key
- [ ] `DB_HOST` set
- [ ] `DB_PASS` set (minimum 16 chars)
- [ ] SSH key tested: `ssh -i key deploy@host "echo ok"`

### Staging Environment

- [ ] All development secrets set
- [ ] `STAGING_SERVER_HOST` set
- [ ] `STAGING_SERVER_SSH_KEY` is DIFFERENT from dev key
- [ ] `DB_HOST_STAGING` set
- [ ] `DB_PASS_STAGING` set (minimum 20 chars, more secure than dev)
- [ ] `ALERT_EMAIL` set
- [ ] SSH key tested

### Production Environment

- [ ] All staging secrets set
- [ ] `PROD_SERVER_HOST` set
- [ ] `PROD_SERVER_SSH_KEY` is DIFFERENT from dev/staging keys
- [ ] `DB_HOST_PROD` set
- [ ] `DB_NAME_PROD` set
- [ ] `DB_USER_PROD` set
- [ ] `DB_PASS_PROD` set (minimum 32 chars, VERY secure)
- [ ] `ALERT_EMAIL` set to production ops team
- [ ] SSH key tested
- [ ] Approved reviewers configured
- [ ] Approval rules enabled

---

## Security Best Practices

### DO ✅

- ✅ Generate unique SSH key per environment
- ✅ Use Ed25519 keys (stronger than RSA)
- ✅ Store keys ONLY in GitHub Secrets
- ✅ Use very strong passwords (32+ chars for production)
- ✅ Include numbers, symbols, mixed case
- ✅ Rotate keys/passwords quarterly
- ✅ Use different passwords per environment
- ✅ Audit secret access regularly
- ✅ Test SSH access before deploying
- ✅ Document which secrets are in which environment

### DON'T ❌

- ❌ Never commit secrets to git repository
- ❌ Never use same SSH key for multiple environments
- ❌ Never use passphrase on deployment SSH keys
- ❌ Never store secrets in .env files (except `.env` template)
- ❌ Never share secrets via email or chat
- ❌ Never use simple passwords like "password123"
- ❌ Never use dictionary words or usernames
- ❌ Never reuse passwords across environments
- ❌ Never store SSH keys unencrypted locally
- ❌ Never set SSH keys without passphrase protection on personal machine

---

## Troubleshooting Secrets

### "Secrets not found" error

**Problem:** Workflow can't access secrets

**Check:**
1. Verify secret name matches exactly (case-sensitive)
2. Verify secret is in correct environment
3. Verify workflow uses `environment: production` (if environment-specific)
4. Check that secret is visible to current user

**Solution:**
```yaml
# Workflow must specify environment to access environment secrets
jobs:
  deploy:
    environment: production  # ← This allows access to prod secrets
    runs-on: ubuntu-latest
    steps:
      - run: echo ${{ secrets.PROD_SERVER_HOST }}
```

### SSH key authentication fails

**Problem:** Permission denied (publickey)

**Check:**
1. SSH key is valid Ed25519 format
2. Public key added to server's `~/.ssh/authorized_keys`
3. Key permissions: `chmod 600 ~/.ssh/authorized_keys`
4. Server allows SSH access from CI/CD IP

**Test locally:**
```bash
ssh -i ~/.ssh/comserv-prod-deploy deploy@your-prod-server.com "echo test"
```

### Database connection fails

**Problem:** Can't connect to production database

**Check:**
1. Database host is correct
2. Database user/pass is correct
3. Database exists
4. Network allows connection from deployment server
5. Database credentials not expired

**Test:**
```bash
mysql -h db-prod.example.com -u comserv -p"PASSWORD" -e "SELECT 1"
```

---

## Secret Rotation Schedule

### Quarterly Rotation (Every 3 months)

- [ ] Production SSH key
- [ ] Production database password
- [ ] PagerDuty integration key (if used)

### Semi-Annual Rotation (Every 6 months)

- [ ] Staging SSH key
- [ ] Staging database password
- [ ] Slack webhook URL (re-test)

### Annual Review

- [ ] All development secrets
- [ ] All staging secrets
- [ ] All production secrets
- [ ] Review access logs

---

## Questions?

See: [PIPELINE_SETUP_GUIDE.md](PIPELINE_SETUP_GUIDE.md) or [GITHUB_ENVIRONMENTS_SETUP.md](GITHUB_ENVIRONMENTS_SETUP.md)