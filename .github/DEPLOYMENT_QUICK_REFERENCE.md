# Deployment Quick Reference

## Quick Links

- 📋 Full Setup Guide: [PIPELINE_SETUP_GUIDE.md](PIPELINE_SETUP_GUIDE.md)
- 🔐 Environment Configuration: [GITHUB_ENVIRONMENTS_SETUP.md](GITHUB_ENVIRONMENTS_SETUP.md)
- 📊 GitHub Actions Dashboard: https://github.com/YOUR-ORG/comserv2/actions
- 🌍 Deployments View: https://github.com/YOUR-ORG/comserv2/deployments

---

## Deployment Workflows at a Glance

### Diagram: Complete Pipeline

```
CODE PUSH
    ↓
┌─────────────────────────────────────┐
│ 1. BUILD & TEST                     │ ← Run on every push/PR
│   • Perl syntax check               │   Duration: 8-12 min
│   • Unit tests                      │
│   • Integration tests               │
│   • Security scan                   │
└─────────────────────────────────────┘
    ↓ (if passed)
┌─────────────────────────────────────┐
│ 2. BUILD & PUSH DOCKER IMAGE        │ ← Auto on develop/main
│   • Multi-stage build               │   Duration: 5-8 min
│   • Push to registry                │
│   • Image vulnerability scan        │
└─────────────────────────────────────┘
    ↓ (if passed)
┌─────────────────────────────────────┐
│ 3. DEPLOY WORKFLOW                  │ ← Environment-specific
│   Branch: develop → DEV             │
│   Branch: main → STAGING            │
│   Tag: v1.0.0 → PRODUCTION          │
└─────────────────────────────────────┘
    ↓ (deployment steps)
┌─────────────────────────────────────┐
│ 4. ENVIRONMENT APPROVAL (if needed) │ ← Manual gate
│   • Staging: requires approval      │
│   • Production: requires approval   │
└─────────────────────────────────────┘
    ↓ (approval given)
┌─────────────────────────────────────┐
│ 5. DEPLOY & MIGRATE                 │
│   • Pull image from registry        │
│   • Run database migrations         │
│   • Health checks                   │
│   • Smoke tests                     │
└─────────────────────────────────────┘
    ↓
✅ DEPLOYMENT COMPLETE
```

---

## Deployment by Branch

### Develop Branch → Development Environment

**How to deploy:**
```bash
git checkout develop
git commit -m "feature: add new feature"
git push origin develop
```

**What happens:**
1. ✅ Build & test workflow runs
2. ✅ Docker image built and pushed
3. ✅ **Auto-deploys to development** (no approval needed)
4. ✅ Database migrations run automatically
5. ✅ Available at: `http://your-dev-server:3000`

**Status:** Check [Actions tab](https://github.com/YOUR-ORG/comserv2/actions)

---

### Main Branch → Staging Environment

**How to deploy:**
```bash
# Create pull request to main branch
# After review and merge:
git checkout main
git pull origin main
```

**What happens:**
1. ✅ Build & test workflow runs
2. ✅ Docker image built and pushed
3. ⏳ **Pauses for approval** (you must approve)
4. ✅ After approval: deploys to staging
5. ✅ Database migrations run
6. ✅ Available at: `https://staging.example.com`

**To approve:**
1. Go to [Deployments](https://github.com/YOUR-ORG/comserv2/deployments)
2. Click "Review deployments"
3. Select "staging" environment
4. Click "Approve and deploy"

---

### Version Tag → Production Environment

**How to deploy:**
```bash
# On main branch
git tag -a v1.0.0 -m "Release v1.0.0"
git push origin v1.0.0
```

**What happens:**
1. ✅ Build & test workflow runs
2. ✅ Docker image built and tagged as v1.0.0
3. ⏳ **Pauses for approval** (requires manual approval)
4. ✅ After approval: deploys to production
5. ✅ Auto-backup created before deployment
6. ✅ Database migrations run
7. ✅ Available at: `https://app.example.com`

**To approve production deployment:**
1. Go to [Deployments](https://github.com/YOUR-ORG/comserv2/deployments)
2. Click "Review deployments"
3. Select "production" environment
4. **Review the version tag and commit**
5. Click "Approve and deploy"

---

## Manual Deployment Trigger

**For special cases (manual deployment):**

1. Go to **Actions** tab
2. Click **Deploy to Servers** workflow
3. Click **Run workflow** button (top right)
4. Select environment: development | staging | production
5. Click **Run workflow** button
6. Workflow will deploy to selected environment

---

## Server Status Check

### Check Development Server

```bash
ssh deploy@your-dev-server.com
cd ~/comserv2

# Status
docker-compose -f Comserv/docker-compose.dev.yml ps

# Logs
docker-compose -f Comserv/docker-compose.dev.yml logs -f web-dev --tail=50

# Health check
curl http://localhost:3000/
```

### Check Staging Server

```bash
ssh deploy@your-staging-server.com
cd ~/comserv2

# Status
docker-compose -f Comserv/docker-compose.staging.yml ps

# Logs
docker-compose -f Comserv/docker-compose.staging.yml logs -f web-staging --tail=50

# Health check
curl http://localhost:5000/
```

### Check Production Server

```bash
ssh deploy@your-prod-server.com
cd ~/comserv2

# Status
docker-compose -f Comserv/docker-compose.prod.yml ps

# Logs
docker-compose -f Comserv/docker-compose.prod.yml logs -f web-prod --tail=50

# Health check
curl http://localhost:5000/
```

---

## Common Tasks

### View Workflow Logs

1. Go to **Actions** tab
2. Click on workflow run
3. Click on job name
4. Click on step to expand

### Restart a Failed Workflow

1. Go to **Actions** tab
2. Click workflow run
3. Click **Re-run all jobs** (top right)

### View Deployment History

1. Go to **Settings** → **Environments**
2. Click environment name
3. Scroll to "Deployment history"
4. See who deployed what and when

### Rollback to Previous Deployment

For production rollback:

```bash
ssh deploy@your-prod-server.com
cd ~/comserv2

# Check backups
ls -la ~/backups/

# Restore backup
tar -xzf ~/backups/comserv_YYYYMMDD_HHMMSS.tar.gz

# Or checkout previous tag
git checkout v1.0.0  # Previous version

# Redeploy
cd Comserv
docker-compose -f docker-compose.prod.yml down
docker-compose -f docker-compose.prod.yml up -d
```

---

## Monitoring Deployments

### GitHub Notifications

- ✅ Star notifications enabled for workflow runs
- ✅ Email on failure/success (configure in GitHub settings)
- ✅ Check **Actions** tab for real-time status

### Slack Notifications

**Setup required:**
1. Create Slack app webhook URL
2. Add to GitHub Secrets as `SLACK_WEBHOOK_URL`
3. Workflows automatically post to #deployments channel

### Typical Timeline

```
Deploy triggered: 10:00 AM
├─ Build & Test:      10:00 AM → 10:12 AM (12 min)
├─ Build & Push:      10:12 AM → 10:18 AM (6 min)
├─ Deploy workflow:   10:18 AM → 10:20 AM (2 min)
├─ ⏳ Awaiting approval: 10:20 AM
├─ Approval given:    10:25 AM
├─ Deploying:         10:25 AM → 10:28 AM (3 min)
├─ Health checks:     10:28 AM → 10:30 AM (2 min)
└─ ✅ Complete:       10:30 AM (Total: 30 min)
```

---

## Troubleshooting Common Issues

### Build Fails

**Check:**
```
1. Recent code changes for syntax errors
2. Dependencies in cpanfile
3. Database connection in tests
```

**Solution:**
```bash
# Test locally
cd Comserv
docker build -t comserv:test .
docker run -it comserv:test perl -c lib/Comserv.pm
```

### Deployment Fails

**Check:**
```
1. Server is reachable: ping your-server.com
2. SSH key works: ssh -i ~/.ssh/key deploy@server
3. Docker available: ssh deploy@server docker --version
4. Disk space: ssh deploy@server df -h
```

**Solution:**
```bash
# SSH to server and manually deploy
ssh deploy@your-server.com
cd ~/comserv2
git pull origin main
docker-compose -f Comserv/docker-compose.prod.yml pull
docker-compose -f Comserv/docker-compose.prod.yml up -d
```

### Approval Not Showing

**Check:**
```
1. Environment is configured in settings
2. Required reviewers > 0
3. Branch matches environment rules
```

**Solution:**
1. Go to Settings → Environments
2. Verify environment exists
3. Verify "Required reviewers" > 0

### Health Check Fails

**Check:**
```
1. Container is running: docker ps
2. Logs for errors: docker-compose logs web-prod
3. Port is open: curl http://localhost:5000
4. Database connection
```

**Solution:**
```bash
# On server
docker-compose -f Comserv/docker-compose.prod.yml logs web-prod
docker-compose -f Comserv/docker-compose.prod.yml restart web-prod
```

---

## Secret Management

### Add New Secret

1. Go to **Settings** → **Secrets and variables** → **Actions**
2. Click **New repository secret**
3. Enter name and value
4. Click **Add secret**

### Update Secret

1. Go to **Settings** → **Secrets and variables** → **Actions**
2. Find secret
3. Click **Update**
4. Enter new value
5. Click **Update secret**

### Environment-Specific Secrets

1. Go to **Settings** → **Environments**
2. Click environment name
3. Scroll to **Environment secrets**
4. Click **Add secret**
5. Enter name and value

---

## Access Control

### Who Can Deploy?

**Development:** Anyone with push access to develop branch

**Staging:** Reviewers with push access to main branch

**Production:** 
- Requires approved environment
- Reviewers configured in environment settings
- Recommended: 2+ approvals for critical changes

### Add Reviewer to Environment

1. Settings → Environments → [environment]
2. Scroll to "Required reviewers"
3. Add GitHub user or team
4. Save

---

## Performance Tips

### Faster Builds

1. Docker layer caching automatically optimized
2. Perl module layer cached between builds
3. Average build time: 8-12 minutes (first time)
4. Subsequent builds: 3-5 minutes (cached)

### Faster Deployments

1. Bring development into local Docker first
2. Test extensively on dev
3. Minimize staging->prod deployments

---

## Documentation

| Document | Purpose |
|----------|---------|
| [PIPELINE_SETUP_GUIDE.md](PIPELINE_SETUP_GUIDE.md) | Complete setup instructions |
| [GITHUB_ENVIRONMENTS_SETUP.md](GITHUB_ENVIRONMENTS_SETUP.md) | Environment configuration |
| [DEPLOYMENT_QUICK_REFERENCE.md](DEPLOYMENT_QUICK_REFERENCE.md) | This file - quick tasks |

---

## Key Secrets Needed

**All Environments:**
- `IMAGE_REGISTRY`: yourusername/comserv

**Development:**
- `DEV_SERVER_HOST`, `DEV_SERVER_USER`, `DEV_SERVER_SSH_KEY`

**Staging:**
- `STAGING_SERVER_HOST`, `STAGING_SERVER_USER`, `STAGING_SERVER_SSH_KEY`
- `SLACK_WEBHOOK_URL` (optional)

**Production:**
- `PROD_SERVER_HOST`, `PROD_SERVER_USER`, `PROD_SERVER_SSH_KEY`
- `SLACK_WEBHOOK_URL` (optional)
- `PAGERDUTY_INTEGRATION_KEY` (optional)

---

## Emergency Procedures

### Stop Deployment in Progress

1. Go to **Actions** tab
2. Click on running workflow
3. Click **Cancel workflow** (top right)
4. Confirm cancellation

### Rollback Production

```bash
ssh deploy@prod-server.com
cd ~/comserv2

# List available backups
ls -lh ~/backups/

# Restore previous version
git checkout v1.0.0  # Previous tag
cd Comserv
docker-compose -f docker-compose.prod.yml down
docker-compose -f docker-compose.prod.yml up -d
```

### Manual Server Restart

```bash
ssh deploy@server.com
cd ~/comserv2/Comserv

# Restart services
docker-compose -f docker-compose.prod.yml restart web-prod

# Wait for health check
sleep 5
docker-compose ps
```

---

## Support

For full documentation: See [PIPELINE_SETUP_GUIDE.md](PIPELINE_SETUP_GUIDE.md)

Need help? Check workflow logs in [Actions tab](https://github.com/YOUR-ORG/comserv2/actions)