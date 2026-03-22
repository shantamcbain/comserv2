# GitHub Environments Configuration Guide

## Overview

GitHub Environments provide:
- ✅ Environment-specific secrets
- ✅ Manual approval gates before deployment
- ✅ Deployment history tracking
- ✅ Audit logs of who deployed what
- ✅ Environment-specific branch rules

---

## Creating GitHub Environments

### Step 1: Navigate to Environment Settings

1. Go to repository **Settings**
2. Click **Environments** (left sidebar)
3. Click **New environment**

---

## Development Environment

### Configuration

**Name:** `development`

**Deployment branches:** `develop` (any branch)
- Select: **Any branch can deploy to this environment**

### Secrets (Development)

Add these secrets specifically for development:

```
Name: DEV_SERVER_HOST
Value: your-dev-workstation.com

Name: DEV_SERVER_USER
Value: deploy

Name: DEV_SERVER_SSH_KEY
Value: <paste private key from ~/.ssh/comserv-dev-deploy>

Name: DB_PASS
Value: dev_password_change_me

Name: DB_HOST
Value: db.example.com

Name: DB_NAME
Value: comserv_dev
```

### Approval Rules

- **Required reviewers:** (Optional - skip for dev)
- **Timeout (minutes):** 1440 (24 hours)

### Deployment branches protection

- ✅ **Require branches to be deployed before releasing to other environments**

---

## Staging Environment

### Configuration

**Name:** `staging`

**Deployment branches:**
- Select: **Selected branches**
- Add branch: `main`

### Secrets (Staging)

```
Name: STAGING_SERVER_HOST
Value: your-staging-server.com

Name: STAGING_SERVER_USER
Value: deploy

Name: STAGING_SERVER_SSH_KEY
Value: <paste private key from ~/.ssh/comserv-staging-deploy>

Name: DB_PASS_STAGING
Value: staging_secure_password

Name: DB_HOST_STAGING
Value: db-staging.example.com

Name: DB_NAME_STAGING
Value: comserv_staging

Name: ALERT_EMAIL
Value: devops@example.com

Name: SLACK_WEBHOOK_URL
Value: https://hooks.slack.com/services/YOUR/SLACK/WEBHOOK
```

### Approval Rules

- **Required reviewers:** 1 (yourself or team member)
- **Timeout (minutes):** 360 (6 hours)
- **Bypass list:** (Leave empty - requires approval)

### Deployment branches protection

- ✅ **Require branches to be deployed before releasing to other environments**

---

## Production Environment

### Configuration

**Name:** `production`

**Deployment branches:**
- Select: **Selected branches**
- Add branch: `main` (for version tags)

### Secrets (Production)

```
Name: PROD_SERVER_HOST
Value: your-production-server.com

Name: PROD_SERVER_USER
Value: deploy

Name: PROD_SERVER_SSH_KEY
Value: <paste private key from ~/.ssh/comserv-prod-deploy>

Name: DB_PASS_PROD
Value: production_very_secure_password

Name: DB_HOST_PROD
Value: db-prod.example.com

Name: DB_NAME_PROD
Value: comserv_production

Name: ALERT_EMAIL
Value: ops-team@example.com

Name: PAGERDUTY_INTEGRATION_KEY
Value: <your pagerduty key>

Name: SLACK_WEBHOOK_URL
Value: https://hooks.slack.com/services/YOUR/SLACK/WEBHOOK
```

### Approval Rules ⚠️ CRITICAL

- **Required reviewers:** 1+ (highly recommended: 2+)
- **Require approval only for the specified action:** (checked)
- **Dismiss stale deployment approvals:** ✅ (checked)
- **Request custom deployment reviews:** ⚠️ (optional but recommended)
- **Timeout (minutes):** 1440 (24 hours - requires approval within 24h)

### Deployment branches protection

- ✅ **Require branches to be deployed before releasing to other environments**

---

## Environment Variables vs Secrets

### When to Use Variables

Create **Variables** (not Secrets) for:
- Non-sensitive configuration values
- URLs that are environment-specific
- Feature flags
- API endpoints

**Example:**

```
Name: APP_URL
Value: https://staging.example.com (for staging)
Value: https://app.example.com (for production)

Name: LOG_LEVEL
Value: DEBUG (for staging)
Value: WARN (for production)
```

### When to Use Secrets

Create **Secrets** for:
- Passwords and API keys
- SSH keys
- OAuth tokens
- Database credentials
- Webhook URLs
- Any sensitive configuration

---

## Setting Environment Variables

### Step 1: Add Variable to Environment

1. Go to **Settings → Environments**
2. Click on environment name (e.g., "production")
3. Scroll to **Environment variables**
4. Click **Add variable**
5. Enter **Name** and **Value**
6. Click **Add variable**

### Step 2: Reference in Workflows

```yaml
# Access variable
env:
  APP_URL: ${{ vars.APP_URL }}

# Or in steps
- name: Deploy
  env:
    LOG_LEVEL: ${{ vars.LOG_LEVEL }}
  run: echo "Log level: $LOG_LEVEL"
```

---

## SSH Key Setup for Environments

### Generate Keys (Local Machine)

```bash
# Development
ssh-keygen -t ed25519 -f ~/.ssh/comserv-dev-deploy -C "comserv-dev-deploy"

# Staging
ssh-keygen -t ed25519 -f ~/.ssh/comserv-staging-deploy -C "comserv-staging-deploy"

# Production
ssh-keygen -t ed25519 -f ~/.ssh/comserv-prod-deploy -C "comserv-prod-deploy"
```

### Add Public Keys to Servers

**On each server as `deploy` user:**

```bash
# Copy public key from your local machine
mkdir -p ~/.ssh
cat >> ~/.ssh/authorized_keys << 'EOF'
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIxxxxxxxxxxxxxxxx comserv-dev-deploy
EOF
chmod 600 ~/.ssh/authorized_keys
```

### Store Private Keys in GitHub Secrets

**For each environment:**

```bash
# Copy entire private key content
cat ~/.ssh/comserv-dev-deploy

# Paste into GitHub Secret (Settings → Secrets and variables → Actions)
# Name: DEV_SERVER_SSH_KEY
```

---

## Deployment History & Auditing

### View Deployment History

1. Go to **Settings → Environments**
2. Click on environment name
3. Scroll to **Deployment history**
4. View who deployed what and when

### Enable Deployment Branch Requirements

**For each environment:**

1. Click on environment
2. Scroll to **Deployment branches and tags**
3. Select: **Selected branches**
4. Add specific branches that can deploy

**Example (Production):**
- Only `main` branch can create version tags
- Version tags trigger production deployments

---

## Testing Environments Locally

### Verify SSH Keys Work

```bash
# Test development key
ssh -i ~/.ssh/comserv-dev-deploy -l deploy your-dev-server.com "echo 'SSH Key Works!'"

# Test staging key
ssh -i ~/.ssh/comserv-staging-deploy -l deploy your-staging-server.com "echo 'SSH Key Works!'"

# Test production key
ssh -i ~/.ssh/comserv-prod-deploy -l deploy your-prod-server.com "echo 'SSH Key Works!'"
```

### Verify GitHub Can Access Secrets

Create test workflow (`.github/workflows/test-secrets.yml`):

```yaml
name: Test Secrets
on: workflow_dispatch

jobs:
  test:
    runs-on: ubuntu-latest
    environment: development
    steps:
      - name: Test DEV secret exists
        run: |
          if [ -z "${{ secrets.DEV_SERVER_HOST }}" ]; then
            echo "❌ DEV_SERVER_HOST not set"
            exit 1
          fi
          echo "✅ DEV_SERVER_HOST is set"
```

---

## Environment Protection Rules

### Branch Protection Rules by Environment

**Development:**
- ✅ Require pull request reviews: Optional
- ✅ Require status checks: build-and-test
- ✅ Branches that can deploy: any

**Staging:**
- ✅ Require pull request reviews: 1
- ✅ Require status checks: build-and-test, build, security-scan
- ✅ Branches that can deploy: main only
- ✅ Require approval: 1 person
- ✅ Dismiss stale approvals: Yes

**Production:**
- ✅ Require pull request reviews: 2 (recommended)
- ✅ Require status checks: ALL
- ✅ Branches that can deploy: main (for version tags)
- ✅ Require approval: 1+ (critical deployments need 2+)
- ✅ Dismiss stale approvals: Yes
- ✅ Require up-to-date branches: Yes
- ✅ Restrict who can push: Select team members

---

## Approval Process Flow

### Typical Deployment Approval Workflow

```
1. Developer pushes code
   ↓
2. GitHub Actions runs build/test/lint
   ↓
3. If all pass → Deployment workflow starts
   ↓
4. Workflow pauses at environment approval
   ↓
5. Required reviewer receives notification
   ↓
6. Reviewer goes to:
   Settings → Environments → [env] → Deployment history
   ↓
7. Reviewer clicks "Review deployments"
   ↓
8. Reviewer selects environment(s) to approve
   ↓
9. Deployment proceeds
```

---

## Slack Notifications for Approvals

### Create Slack App Webhook

1. Go to Slack → Your Workspace → Apps → Create New App
2. Choose "From scratch"
3. Name: "GitHub Deployments"
4. Select workspace
5. Enable "Incoming Webhooks"
6. Click "Add New Webhook to Workspace"
7. Select channel: #deployments (or create it)
8. Copy webhook URL
9. Add to GitHub Secrets as `SLACK_WEBHOOK_URL`

### Notification Content

The workflows send notifications like:

```
🚀 Production Deployment
Version: v1.0.0
Status: Pending Approval ⏳

Approvers needed:
→ ops-team@example.com

Review at: https://github.com/...settings/environments/...
```

---

## Best Practices

### ✅ DO

- ✅ Use different secrets for each environment
- ✅ Use Ed25519 SSH keys (more secure)
- ✅ Require approval for staging/production
- ✅ Set appropriate timeout for approvals
- ✅ Document who are reviewers for each environment
- ✅ Audit deployment history regularly
- ✅ Rotate SSH keys quarterly
- ✅ Use Slack notifications for critical deployments

### ❌ DON'T

- ❌ Store secrets in code or workflows
- ❌ Use same SSH key for multiple environments
- ❌ Skip approval for production deployments
- ❌ Leave reviewer notifications unchecked
- ❌ Store SSH keys in plaintext anywhere
- ❌ Share secrets via email or chat
- ❌ Disable branch protection for production

---

## Troubleshooting

### Secret Not Found in Workflow

**Error:** `secrets.MY_SECRET` is empty

**Solution:**
1. Check secret is added to correct environment
2. Check workflow uses `environment: production` (or correct env name)
3. Verify secret name matches exactly (case-sensitive)

### Approval Not Showing

**Error:** Workflow pauses but no approval dialog

**Solution:**
1. Verify environment has "Required reviewers" set to > 0
2. Check that deployment branch matches environment rules
3. Verify GitHub user has permission to approve

### SSH Key Fails

**Error:** Permission denied (publickey)

**Solution:**
1. Verify public key is on server in `~/.ssh/authorized_keys`
2. Check key permissions: `chmod 600 ~/.ssh/authorized_keys`
3. Test SSH manually: `ssh -i ~/.ssh/comserv-prod-deploy deploy@host`
4. Check server has deploy user created

---

## Production Environment Checklist

Before enabling production deployments:

- [ ] SSH keys generated and tested
- [ ] All secrets added to production environment
- [ ] Approval rules configured (require 1+ reviewers)
- [ ] Branch protection rules enabled for main
- [ ] Slack webhook URL configured
- [ ] Staging deployments tested successfully
- [ ] Production server set up with deploy user
- [ ] Database backup configured
- [ ] Rollback procedure documented
- [ ] Team trained on approval process

---

## Next Steps

1. Create three environments: development, staging, production
2. Add secrets to each environment
3. Generate and deploy SSH keys
4. Test SSH access from all environments
5. Test a workflow deployment to development
6. Document your team's approval process
7. Set up Slack notifications
8. Schedule SSH key rotation quarterly