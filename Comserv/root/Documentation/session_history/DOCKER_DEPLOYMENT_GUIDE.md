# Comserv Docker Deployment Guide

Complete Infrastructure as Code documentation for containerizing and deploying Comserv.

## Quick Start

### Development (5 minutes)
```bash
cd /home/shanta/PycharmProjects/comserv2

# Copy environment
cp .env.development .env

# Start services
docker-compose up -d

# Verify
docker-compose ps

# Access: http://localhost:3000
```

### Production
```bash
# Edit production secrets
cp .env.production .env.prod.secret
nano .env.prod.secret

# Deploy
docker-compose --env-file .env.prod.secret up -d
```

## Architecture

```
┌──────────────┐
│  Nginx       │ (Port 80/443)
│  Proxy       │
└──────┬───────┘
       │
┌──────▼─────────┐
│  Comserv App   │ (Port 3000)
│  4 Starman     │
│  Workers       │
└──────┬─────┬──┘
       │     │
   ┌───▼──┐ ┌┴────┐
   │MySQL │ │Redis│
   │3306  │ │6379 │
   └──────┘ └─────┘

All services on Docker bridge network (172.20.0.0/16)
```

## Files Overview

### Core Files
- **Dockerfile**: Multi-stage image build (Comserv/Dockerfile)
- **docker-compose.yml**: Service orchestration (MySQL, Redis, App, Nginx) [File name unchanged for V2]
- **.env.example**: Configuration template
- **.env.development**: Dev preset (debug ON, exposed ports)
- **.env.production**: Production preset (debug OFF, hardened)
- **.dockerignore**: Build context optimization

### Configuration Files
- **config/mysql.cnf**: MySQL optimization settings
- **config/nginx.conf**: Reverse proxy, SSL, rate limiting
- **Makefile.docker**: Convenient command shortcuts

### Documentation
- **DOCKER_DEPLOYMENT_GUIDE.md**: This file
- **DOCKER_IaC_SUMMARY.md**: Detailed technical overview

## Service Management

```bash
# View services
docker-compose ps

# View logs
docker-compose logs -f web      # App
docker-compose logs -f database # Database
docker-compose logs -f redis    # Cache

# Container shell
docker-compose exec web bash
docker-compose exec database mysql -u comserv -p
docker-compose exec redis redis-cli -a redispass
```

## Database Operations

```bash
# Backup
docker-compose exec database mysqldump -u comserv -pcomserv_pass \
  --all-databases > backup.sql

# Restore
docker-compose exec -T database mysql -u comserv -pcomserv_pass < backup.sql

# Connect
docker-compose exec database mysql -u comserv -p comserv
```

## Troubleshooting

### Services won't start
```bash
docker-compose logs                 # Check logs
sudo lsof -i :3000                  # Check port conflicts
docker-compose down -v              # Clean restart
docker-compose up -d
```

### Database connection fails
```bash
# Test connectivity
docker compose exec web perl -e \
  "use DBI; \$dbh = DBI->connect('DBI:mysql:comserv:database', \
   'comserv', 'comserv_pass'); print \"OK\n\" if \$dbh"
```

### Memory/CPU issues
```bash
docker stats            # Monitor resource usage
docker-compose config   # View limits
```

## Production Deployment Checklist

- [ ] Security credentials in `.env.production`
- [ ] Database backups tested
- [ ] SSL certificates obtained
- [ ] Firewall configured (ports 80, 443 only)
- [ ] Database replication setup
- [ ] Monitoring/logging configured
- [ ] Health checks verified
- [ ] Disaster recovery plan tested

## Security Best Practices

✓ Use strong passwords (30+ chars, mixed case, numbers, symbols)
✓ Don't commit `.env` files to git
✓ Use SSL/TLS certificates (not self-signed)
✓ Enable rate limiting (configured in nginx.conf)
✓ Network isolation via Docker bridge
✓ Non-root application user
✓ Regular database backups
✓ Keep images updated

## Performance Optimization

### Database
```sql
ANALYZE TABLE table_name;          -- Optimize queries
CREATE INDEX idx_col ON table(col); -- Add indexes
```

### Application
- Increase Starman workers: `--workers=8` in supervisor config
- Monitor memory: `docker stats`
- Scale to multiple containers if needed

### Cache
```bash
# Redis memory stats
docker-compose exec redis redis-cli -a redispass info stats

# Clear cache
docker-compose exec redis redis-cli -a redispass FLUSHALL
```

## Useful Make Commands

```bash
make dev              # Start development
make prod             # Start production
make up               # Start services
make down             # Stop services
make logs             # View logs
make shell            # Access app shell
make db-shell         # Connect to database
make health           # Run health checks
make monitoring       # Show resource usage
```

Or use: `make -f Makefile.docker help`

## Additional Resources

- [Docker Documentation](https://docs.docker.com/)
- [Docker Compose Reference](https://docs.docker.com/compose/compose-file/)
- [Catalyst Web Framework](https://metacpan.org/pod/Catalyst)
- [MySQL 8.0 Docs](https://dev.mysql.com/doc/)
- [Nginx Docs](https://nginx.org/en/docs/)
- [Redis Docs](https://redis.io/documentation)

---

**Version**: 1.0  
**Last Updated**: 2025-01-10  
**Status**: Production Ready
