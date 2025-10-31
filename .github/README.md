# Comserv CI/CD Pipeline - Complete Documentation

## Welcome! 👋

This directory contains the complete GitHub Actions CI/CD pipeline for Comserv - a Kubernetes-ready, production-grade deployment automation system.

**What is this pipeline?**
- ✅ Automated testing on every code change
- ✅ Docker image building with layer caching
- ✅ Multi-environment deployments (dev/staging/prod)
- ✅ Automated database migrations
- ✅ Security scanning and vulnerability detection
- ✅ Email/Slack notifications
- ✅ Rollback capabilities
- ✅ Kubernetes-ready architecture

---

## 📚 Documentation Guide

### Quick Start (👈 Start Here!)
- **[DEPLOYMENT_QUICK_REFERENCE.md](DEPLOYMENT_QUICK_REFERENCE.md)**
  - 5-minute overview of how to deploy
  - Common tasks and troubleshooting
  - Server status checks

### Complete Setup
- **[PIPELINE_SETUP_GUIDE.md](PIPELINE_SETUP_GUIDE.md)**
  - Step-by-step server setup
  - Database configuration
  - First-time checklist
  - Maintenance schedule

### Environment Configuration
- **[GITHUB_ENVIRONMENTS_SETUP.md](GITHUB_ENVIRONMENTS_SETUP.md)**
  - Create GitHub environments
  - Configure approval rules
  - Set up Slack notifications
  - Best practices and security

### Secrets & Credentials
- **[SECRETS_TEMPLATE.md](SECRETS_TEMPLATE.md)**
  - All secrets needed
  - SSH key generation
  - Password guidelines
  - Rotation schedule

---

## 🚀 The Pipeline in 30 Seconds

```
1. Developer commits code → pushes to GitHub
   ↓
2. GitHub Actions automatically:
   • Runs tests
   • Builds Docker image
   • Pushes to registry
   ↓
3. Auto-deploys to development environment ✅
4. Staging deploys after approval ⏳
5. Production deploys after approval (with backup) 🔐
```

---

## 🏗️ Architecture

### Three-Tier Environment Strategy

```
DEVELOPMENT ENVIRONMENT
├─ Branch: develop
├─ Deployment: Automatic
├─ Database: Shared dev database
├─ URL: http://your-dev-server:3000
└─ Purpose: Rapid testing & iteration

STAGING ENVIRONMENT
├─ Branch: main
├─ Deployment: Requires approval
├─ Database: Mirrors production
├─ URL: https://staging.example.com
└─ Purpose: Production-like testing before release

PRODUCTION ENVIRONMENT
├─ Branch: version tags (v1.0.0, v2.1.3, etc.)
├─ Deployment: Requires approval + backup
├─ Database: Production database
├─ URL: https://app.example.com
└─ Purpose: Live customer-facing application
```

### Deployment Flow

```
CODE COMMIT
    ↓
BUILD & TEST (8-12 min)
├─ Perl syntax check
├─ Unit tests
├─ Integration tests
├─ Security scan
└─ Result: ✅ or ❌

DOCKER BUILD & PUSH (5-8 min)
├─ Multi-stage build
├─ Layer caching
├─ Push to registry
└─ Result: ghcr.io/your-org/comserv:tag

DEPLOY WORKFLOW
├─ Dev: Auto-deploy → http://dev:3000
├─ Staging: Approval → https://staging
└─ Prod: Approval → https://production
```

---

## 📋 Workflows Included

### 1. **Build & Test** (`build-and-test.yml`)
- **Triggers:** Every push/PR to `main` or `develop`
- **Duration:** 8-12 minutes
- **Steps:**
  - Perl syntax check
  - Unit tests
  - Integration tests (with MariaDB)
  - Pod coverage verification
  - YAML linting
  - Security scanning

### 2. **Build & Push Registry** (`build-push-registry.yml`)
- **Triggers:** Successful build on main/develop branches
- **Duration:** 5-8 minutes
- **Steps:**
  - Build Docker image
  - Push to GitHub Container Registry
  - Tag with version/branch/commit
  - Scan image for vulnerabilities

### 3. **Deploy to Servers** (`deploy-to-servers.yml`)
- **Triggers:** Build completion (dev), Tag push (prod)
- **Duration:** 10-15 minutes (including approval wait)
- **Steps:**
  - SSH to target server
  - Pull latest code
  - Pull Docker image from registry
  - Run database migrations
  - Health checks
  - Smoke tests

---

## 🔑 Key Files

### Workflows (in `.github/workflows/`)
```
.github/workflows/
├─ build-and-test.yml           ← Testing on every push
├─ build-push-registry.yml       ← Build & push Docker image
└─ deploy-to-servers.yml         ← Deploy to environments
```

### Environment Configs (in `Comserv/`)
```
Comserv/
├─ .env.development              ← Dev environment variables
├─ .env.staging                  ← Staging environment variables
├─ .env.production               ← Production environment variables
├─ docker-compose.dev.yml        ← Dev services
├─ docker-compose.staging.yml    ← Staging services
├─ docker-compose.prod.yml       ← Production services
├─ Dockerfile                    ← Multi-stage build
└─ cpanfile                      ← Perl dependencies
```

### Documentation (in `.github/`)
```
.github/
├─ README.md                     ← This file
├─ PIPELINE_SETUP_GUIDE.md       ← Complete setup instructions
├─ GITHUB_ENVIRONMENTS_SETUP.md  ← Environment configuration
├─ DEPLOYMENT_QUICK_REFERENCE.md ← Quick tasks
└─ SECRETS_TEMPLATE.md           ← Secrets checklist
```

---

## ⚡ Getting Started (5 Steps)

### Step 1: Read the Quick Reference
Open: [DEPLOYMENT_QUICK_REFERENCE.md](DEPLOYMENT_QUICK_REFERENCE.md)

### Step 2: Set Up GitHub Secrets
Follow: [SECRETS_TEMPLATE.md](SECRETS_TEMPLATE.md)
- Generate SSH keys
- Add to GitHub Secrets
- Test access

### Step 3: Configure Servers
Follow: [PIPELINE_SETUP_GUIDE.md](PIPELINE_SETUP_GUIDE.md)
- Set up development server
- Set up staging server
- Set up production server

### Step 4: Create GitHub Environments
Follow: [GITHUB_ENVIRONMENTS_SETUP.md](GITHUB_ENVIRONMENTS_SETUP.md)
- Create 3 environments (dev/staging/prod)
- Add environment secrets
- Set up approval rules

### Step 5: Test Pipeline
1. Push to develop branch
2. Watch build workflow in Actions tab
3. Verify deployment to development
4. Test staging with manual trigger

---

## 💻 Common Commands

### Check Deployment Status
```bash
# SSH to server
ssh deploy@your-server.com
cd ~/comserv2/Comserv

# View services
docker-compose ps

# View logs
docker-compose logs -f web-dev --tail=50

# Health check
curl http://localhost:3000/
```

### Manual Deployment Trigger
1. Go to **Actions** tab
2. Click **Deploy to Servers**
3. Click **Run workflow**
4. Select environment
5. Click **Run workflow**

### Monitor Workflow Progress
1. Go to **Actions** tab
2. Click running workflow
3. Click job to see detailed logs

### Approve Staging/Production Deployment
1. Go to **Deployments** (link in repo settings)
2. Click "Review deployments"
3. Select environment
4. Click "Approve and deploy"

---

## 🔐 Security

### SSH Keys
- ✅ Generated per environment (dev/staging/prod)
- ✅ Ed25519 encryption (stronger than RSA)
- ✅ Stored ONLY in GitHub Secrets
- ✅ Rotated quarterly

### Database Credentials
- ✅ Strong passwords (32+ chars for production)
- ✅ Stored in GitHub Secrets
- ✅ Environment-specific
- ✅ Never committed to git

### Approvals
- ✅ Staging requires 1 approval
- ✅ Production requires 1+ approval (2+ recommended)
- ✅ Audit trail visible in Deployments
- ✅ Time limits on approvals

### Scanning
- ✅ Dockerfile security scanning
- ✅ Container image vulnerability scanning
- ✅ Dependency auditing
- ✅ YAML validation

---

## 📊 Performance

### Build Times
- **First build:** 8-12 minutes (fresh dependencies)
- **Cached builds:** 3-5 minutes (layer caching)
- **Docker layer caching:** Automatic via buildx
- **Perl module caching:** Cached between runs

### Deployment Times
- **Development:** 2-3 minutes (auto-deploy)
- **Staging:** 5-8 minutes (includes approval wait)
- **Production:** 10-15 minutes (includes backup + approval)

---

## 🐛 Troubleshooting

### Build Fails
- Check Perl syntax errors
- Verify cpanfile dependencies
- Review workflow logs

### Deployment Fails
- Check SSH key access
- Verify server connectivity
- Check Docker is running
- Review deployment logs

### Tests Fail
- Run tests locally
- Check database connection
- Review test output

**For detailed help:**
→ See [DEPLOYMENT_QUICK_REFERENCE.md](DEPLOYMENT_QUICK_REFERENCE.md) Troubleshooting section

---

## 📈 Monitoring

### GitHub Actions Dashboard
- https://github.com/YOUR-ORG/comserv2/actions

### Deployments View
- https://github.com/YOUR-ORG/comserv2/deployments

### Workflow Status Badge
Add to README.md:
```markdown
[![Build and Test](https://github.com/YOUR-ORG/comserv2/workflows/Build%20&%20Test/badge.svg)](https://github.com/YOUR-ORG/comserv2/actions)
```

### Email Notifications
- Set in **Settings → Notifications**
- Configure per workflow

### Slack Notifications
- Set webhook URL in GitHub Secrets
- Workflows auto-notify to #deployments

---

## 🚀 Kubernetes Migration (Future)

This pipeline is **Kubernetes-ready**:
1. ✅ Docker images already built
2. ✅ Environment variables externalized
3. ✅ No server-specific dependencies
4. ✅ Health checks implemented
5. ✅ Logging configured

**To migrate to Kubernetes:**
- Create Helm charts
- Set up ArgoCD for GitOps
- Configure persistent volumes
- Update deployment workflow

See planned Kubernetes migration guide (Phase 3).

---

## 📅 Maintenance

### Weekly
- Monitor workflow execution times
- Check log file sizes
- Review failed deployments

### Monthly
- Review branch protection rules
- Update Perl dependencies
- Audit GitHub Secrets access

### Quarterly
- Rotate SSH keys
- Rotate database passwords
- Update base Docker image
- Review security scan results

### Annually
- Full audit of all secrets
- Performance optimization review
- Documentation updates

---

## 🆘 Support & Resources

### Documentation
- [PIPELINE_SETUP_GUIDE.md](PIPELINE_SETUP_GUIDE.md) - Complete setup
- [GITHUB_ENVIRONMENTS_SETUP.md](GITHUB_ENVIRONMENTS_SETUP.md) - Environments
- [DEPLOYMENT_QUICK_REFERENCE.md](DEPLOYMENT_QUICK_REFERENCE.md) - Quick tasks
- [SECRETS_TEMPLATE.md](SECRETS_TEMPLATE.md) - Secrets checklist

### External Resources
- [GitHub Actions Documentation](https://docs.github.com/en/actions)
- [GitHub Environments](https://docs.github.com/en/actions/deployment/targeting-different-environments/using-environments-for-deployment)
- [Docker Best Practices](https://docs.docker.com/develop/dev-best-practices/)
- [Catalyst Framework Docs](https://metacpan.org/pod/Catalyst::Manual)

---

## ✅ Pre-Launch Checklist

Before going live with this pipeline:

- [ ] Read all documentation
- [ ] Generate SSH keys for all environments
- [ ] Create GitHub Secrets
- [ ] Set up all servers
- [ ] Configure GitHub Environments
- [ ] Set up branch protection rules
- [ ] Test build workflow
- [ ] Test deployment to development
- [ ] Test deployment to staging
- [ ] Configure Slack notifications (optional)
- [ ] Document team approval process
- [ ] Train team on deployment procedures
- [ ] Set up backup procedures
- [ ] Document rollback procedures
- [ ] Plan security key rotation
- [ ] Schedule maintenance windows

---

## 🎯 Next Steps

1. **Read:** [DEPLOYMENT_QUICK_REFERENCE.md](DEPLOYMENT_QUICK_REFERENCE.md) (5 min)
2. **Follow:** [SECRETS_TEMPLATE.md](SECRETS_TEMPLATE.md) (15 min)
3. **Setup:** [PIPELINE_SETUP_GUIDE.md](PIPELINE_SETUP_GUIDE.md) (1-2 hours)
4. **Configure:** [GITHUB_ENVIRONMENTS_SETUP.md](GITHUB_ENVIRONMENTS_SETUP.md) (30 min)
5. **Test:** Push to develop and watch it deploy! ✅

---

## 📝 Document Versions

- **Pipeline Setup:** v1.0
- **Environments Guide:** v1.0
- **Secrets Template:** v1.0
- **Quick Reference:** v1.0
- **Last Updated:** 2024

---

## 📞 Questions?

Each guide includes troubleshooting sections. Start with:
- Quick questions → [DEPLOYMENT_QUICK_REFERENCE.md](DEPLOYMENT_QUICK_REFERENCE.md)
- Setup questions → [PIPELINE_SETUP_GUIDE.md](PIPELINE_SETUP_GUIDE.md)
- Environment questions → [GITHUB_ENVIRONMENTS_SETUP.md](GITHUB_ENVIRONMENTS_SETUP.md)
- Secrets questions → [SECRETS_TEMPLATE.md](SECRETS_TEMPLATE.md)

---

**Happy Deploying! 🚀**

This pipeline is designed to be reliable, fast, and secure. Enjoy automated deployments!