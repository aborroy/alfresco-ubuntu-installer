# Alfresco Ubuntu Installer

[![CI - Test Alfresco Ubuntu Installer](https://github.com/aborroy/alfresco-ubuntu-installer/actions/workflows/ci.yml/badge.svg)](https://github.com/aborroy/alfresco-ubuntu-installer/actions/workflows/ci.yml)

Automated installation scripts for deploying **Alfresco Content Services Community Edition** on Ubuntu using ZIP distribution files.

## Overview

This project provides a collection of bash scripts to automate the installation and configuration of Alfresco Content Services on Ubuntu 22.04/24.04 LTS.

## Deployment Options

Alfresco Platform supports multiple deployment approaches:

| Method | Best For | Documentation |
|--------|----------|---------------|
| **ZIP Distribution** (this project) | Custom deployments, learning | [Alfresco Docs](https://docs.alfresco.com/content-services/latest/install/zip/) |
| **Ansible** | Multi-server automation | [Ansible Docs](https://docs.alfresco.com/content-services/latest/install/ansible/) |
| **Docker Compose** | Development, small production | [Docker Docs](https://docs.alfresco.com/content-services/latest/install/containers/docker-compose/) |
| **Helm/Kubernetes** | Enterprise production | [Helm Docs](https://docs.alfresco.com/content-services/latest/install/containers/helm/) |

## Prerequisites

### Hardware Requirements

| Deployment | CPU | RAM | Disk |
|------------|-----|-----|------|
| Development | 2+ cores | 8 GB | 20 GB |
| Small Production | 4+ cores | 16 GB | 100 GB |
| Large Production | 8+ cores | 32 GB+ | 500 GB+ |

### Software Requirements

- **Ubuntu** 22.04 LTS or 24.04 LTS (fresh installation recommended)
- **User** with sudo privileges
- **Internet connectivity** for downloading packages

### Network Ports

Ensure these ports are available:

| Port | Service | Description |
|------|---------|-------------|
| 80 | Nginx | HTTP (external access) |
| 443 | Nginx | HTTPS (optional) |
| 5432 | PostgreSQL | Database |
| 8080 | Tomcat | Alfresco/Share (internal) |
| 8090 | Transform | Document transformation |
| 8161 | ActiveMQ | Web console |
| 8983 | Solr | Search service |
| 61616 | ActiveMQ | OpenWire protocol |

## Quick Start

### 1. Clone the Repository

```bash
git clone https://github.com/YOUR_ORG/alfresco-ubuntu-installer.git
cd alfresco-ubuntu-installer
```

### 2. Generate Configuration

```bash
bash scripts/00-generate-config.sh
```

This creates `config/alfresco.env` with secure random passwords. Review and customize if needed:

```bash
cat config/alfresco.env
```

### 3. Run Installation Scripts

```bash
# Install all components
bash scripts/01-install_postgres.sh
bash scripts/02-install_java.sh
bash scripts/03-install_tomcat.sh
bash scripts/04-install_activemq.sh
bash scripts/05-download_alfresco_resources.sh
bash scripts/06-install_alfresco.sh
bash scripts/07-install_solr.sh
bash scripts/08-install_transform.sh
bash scripts/09-build_aca.sh
bash scripts/10-install_nginx.sh
```

### 4. Start Services

```bash
bash scripts/11-start_services.sh
```

The script starts all services in the correct order with health checks.

### 5. Access Alfresco

| Application | URL | Default Credentials |
|-------------|-----|---------------------|
| Alfresco Content App | http://localhost/ | admin / admin |
| Alfresco Repository | http://localhost/alfresco/ | admin / admin |
| Alfresco Share | http://localhost/share/ | admin / admin |
| Solr Admin | http://localhost:8983/solr/ | (uses secret header) |
| ActiveMQ Console | http://localhost:8161/ | (see config) |

## Project Structure

```
alfresco-ubuntu-installer/
├── config/
│   ├── alfresco.env.template    # Configuration template
│   ├── alfresco.env             # Your configuration (gitignored)
│   └── versions.conf            # Pinned component versions
├── scripts/
│   ├── common.sh                # Shared functions
│   ├── 00-generate-config.sh    # Generate secure configuration
│   ├── 01-install_postgres.sh   # PostgreSQL database
│   ├── 02-install_java.sh       # Java JDK
│   ├── 03-install_tomcat.sh     # Apache Tomcat
│   ├── 04-install_activemq.sh   # Apache ActiveMQ
│   ├── 05-download_alfresco_resources.sh  # Download artifacts
│   ├── 06-install_alfresco.sh   # Alfresco + Share
│   ├── 07-install_solr.sh       # Alfresco Search Services
│   ├── 08-install_transform.sh  # Transform Service
│   ├── 09-build_aca.sh          # Alfresco Content App
│   ├── 10-install_nginx.sh      # Nginx reverse proxy
│   └── 11-start_services.sh     # Start all services
├── downloads/                   # Downloaded artifacts (gitignored)
├── .github/workflows/
│   └── ci.yml                   # CI/CD pipeline
└── README.md
```

## Configuration

### Version Configuration (`config/versions.conf`)

Pinned, tested version combinations:

```bash
# Alfresco Components
ALFRESCO_VERSION="23.2.1"
ALFRESCO_SEARCH_VERSION="2.0.8.2"
ALFRESCO_TRANSFORM_VERSION="5.1.7"

# Infrastructure
POSTGRESQL_VERSION="16"
TOMCAT_VERSION="10.1.28"
ACTIVEMQ_VERSION="6.1.2"
JAVA_VERSION="17"

# Frontend
ACA_VERSION="5.0.0"
NODEJS_VERSION="20"
```

### Environment Configuration (`config/alfresco.env`)

Generated by `00-generate-config.sh` with secure random passwords:

```bash
# Database
ALFRESCO_DB_HOST="localhost"
ALFRESCO_DB_PORT="5432"
ALFRESCO_DB_NAME="alfresco"
ALFRESCO_DB_USER="alfresco"
ALFRESCO_DB_PASSWORD="<auto-generated>"

# Solr
SOLR_HOST="localhost"
SOLR_PORT="8983"
SOLR_SHARED_SECRET="<auto-generated>"

# And more...
```

## Memory Management

### Automatic Memory Allocation

The installer automatically detects system RAM and applies optimal memory settings for all components. This ensures Alfresco runs efficiently without manual tuning.

#### Memory Profiles

| Profile | System RAM | Tomcat/Alfresco | Solr | Transform | ActiveMQ | PostgreSQL |
|---------|------------|-----------------|------|-----------|----------|------------|
| **minimal** | < 8 GB | 1-2 GB | 512 MB | 512 MB | 256 MB | 256 MB shared |
| **small** | 8-16 GB | 2-3 GB | 1 GB | 768 MB | 512 MB | 512 MB shared |
| **medium** | 16-32 GB | 4-6 GB | 2 GB | 1 GB | 512 MB | 1 GB shared |
| **large** | 32-64 GB | 8-12 GB | 4 GB | 2 GB | 1 GB | 2 GB shared |
| **xlarge** | 64+ GB | 16-24 GB | 8 GB | 4 GB | 2 GB | 4 GB shared |

> **Recommendation**: 16 GB RAM minimum for production workloads (medium profile).

#### PostgreSQL Tuning

The installer automatically configures these PostgreSQL parameters based on available RAM:

| Parameter | Description | Example (16GB) |
|-----------|-------------|----------------|
| `shared_buffers` | Memory for caching data | 1024 MB |
| `effective_cache_size` | Planner's assumption of available cache | 2048 MB |
| `work_mem` | Memory per sort/hash operation | 64 MB |
| `maintenance_work_mem` | Memory for maintenance operations | 256 MB |
| `wal_buffers` | Memory for WAL data | 16 MB |
| `checkpoint_completion_target` | WAL checkpoint spread | 0.9 |

#### JVM Settings

Each Java-based service receives optimized JVM settings:

**Tomcat/Alfresco** (medium profile):
```
-Xms4096m -Xmx6144m -XX:+UseG1GC -XX:+UseStringDeduplication -XX:MaxGCPauseMillis=200
```

**Solr** (medium profile):
```
-Xms2048m -Xmx2048m
```

**Transform Service** (medium profile):
```
-Xms512m -Xmx1024m -XX:+UseG1GC
```

**ActiveMQ** (medium profile):
```
-Xms512m -Xmx512m
```

### Manual Memory Override

To override automatic detection, uncomment and modify these lines in `config/alfresco.env`:

```bash
# Memory overrides (values in MB)
export TOMCAT_XMS_MB="4096"               # Tomcat initial heap
export TOMCAT_XMX_MB="6144"               # Tomcat maximum heap
export SOLR_HEAP_MB="2048"                # Solr heap
export TRANSFORM_HEAP_MB="1024"           # Transform service heap
export ACTIVEMQ_HEAP_MB="512"             # ActiveMQ heap
export POSTGRES_SHARED_BUFFERS_MB="1024"  # PostgreSQL shared_buffers
export POSTGRES_EFFECTIVE_CACHE_MB="2048" # PostgreSQL effective_cache_size
```

### Viewing Current Allocation

The start script displays the active memory profile:

```bash
$ bash scripts/11-start_services.sh

[INFO] Detected system memory: 16384MB
[INFO] Applying 'medium' memory profile (16-32GB)
[INFO] Memory allocation (medium profile):
[INFO]   Tomcat/Alfresco: 4096MB - 6144MB
[INFO]   Solr:            2048MB
[INFO]   Transform:       1024MB
[INFO]   ActiveMQ:        512MB
[INFO]   PostgreSQL:      shared_buffers=1024MB, effective_cache=2048MB
```

## Component Details

### 1. PostgreSQL

- **Version**: 16
- **Port**: 5432
- **Data**: `/var/lib/postgresql/16`
- **Logs**: `/var/log/postgresql`

### 2. Java JDK

- **Version**: 17 (OpenJDK)
- **JAVA_HOME**: `/usr/lib/jvm/java-17-openjdk-amd64`
- **Architecture**: Auto-detected (amd64/arm64)

### 3. Apache Tomcat

- **Version**: 10.1.28
- **Home**: `/home/ubuntu/tomcat`
- **Logs**: `/home/ubuntu/tomcat/logs`
- **Memory**: Configurable via `TOMCAT_XMS`/`TOMCAT_XMX`

### 4. Apache ActiveMQ

- **Version**: 5.17.8
- **Home**: `/home/ubuntu/activemq`
- **OpenWire Port**: 61616
- **Web Console**: 8161

### 5. Alfresco Content Services

- **Version**: 23.2.1 Community
- **Context**: `/alfresco`
- **Data**: `/home/ubuntu/alf_data`
- **Config**: `/home/ubuntu/tomcat/shared/classes/alfresco-global.properties`

### 6. Alfresco Share

- **Context**: `/share`
- **Logs**: `/home/ubuntu/tomcat/logs/share.log`

### 7. Alfresco Search Services (Solr)

- **Version**: 2.0.8.2
- **Home**: `/home/ubuntu/alfresco-search-services`
- **Port**: 8983
- **Authentication**: Shared secret

### 8. Transform Service

- **Version**: 5.1.7 (All-In-One)
- **Home**: `/home/ubuntu/transform`
- **Port**: 8090
- **Dependencies**: ImageMagick, LibreOffice, ExifTool

### 9. Alfresco Content App

- **Version**: 5.0.0
- **Source**: `/home/ubuntu/alfresco-content-app`
- **Build Output**: `/home/ubuntu/alfresco-content-app/dist/content-ce`

### 10. Nginx

- **Port**: 80
- **Config**: `/etc/nginx/sites-available/alfresco`
- **Web Root**: `/var/www/alfresco-content-app`
- **Logs**: `/var/log/nginx/alfresco_*.log`

## Service Management

### Start All Services

```bash
bash scripts/11-start_services.sh
```

### Start Individual Services

```bash
sudo systemctl start postgresql
sudo systemctl start activemq
sudo systemctl start transform
sudo systemctl start tomcat
sudo systemctl start solr
sudo systemctl start nginx
```

### Check Service Status

```bash
sudo systemctl status postgresql activemq transform tomcat solr nginx
```

### View Logs

```bash
# Alfresco logs
tail -f /home/ubuntu/tomcat/logs/catalina.out
tail -f /home/ubuntu/tomcat/logs/alfresco.log

# Solr logs
tail -f /home/ubuntu/alfresco-search-services/logs/solr.log

# Nginx logs
tail -f /var/log/nginx/alfresco_access.log
tail -f /var/log/nginx/alfresco_error.log
```

## Troubleshooting

### Alfresco Won't Start

1. **Check Tomcat logs**:
   ```bash
   tail -100 /home/ubuntu/tomcat/logs/catalina.out
   ```

2. **Verify database connection**:
   ```bash
   PGPASSWORD=$(grep ALFRESCO_DB_PASSWORD config/alfresco.env | cut -d= -f2) \
     psql -h localhost -U alfresco -d alfresco -c "SELECT 1"
   ```

3. **Check memory**:
   ```bash
   free -h
   ```

### Solr Not Indexing

1. **Check Solr is running**:
   ```bash
   curl -H "X-Alfresco-Search-Secret: $(grep SOLR_SHARED_SECRET config/alfresco.env | cut -d= -f2)" \
     http://localhost:8983/solr/alfresco/admin/ping
   ```

2. **Verify shared secret matches** in both:
   - `/home/ubuntu/tomcat/shared/classes/alfresco-global.properties`
   - `/home/ubuntu/alfresco-search-services/solrhome/conf/shared.properties`

### Transform Service Errors

1. **Check health endpoint**:
   ```bash
   curl http://localhost:8090/actuator/health
   ```

2. **Verify LibreOffice is installed**:
   ```bash
   soffice --version
   ```

### Port Conflicts

If you need to change ports, update:

1. `config/alfresco.env` - Update the port variables
2. Re-run the relevant installation script
3. Restart services

## Multi-Machine Deployment

For production deployments across multiple machines:

1. **Edit `config/alfresco.env`** to set correct hostnames:
   ```bash
   ALFRESCO_DB_HOST="db.example.com"
   SOLR_HOST="search.example.com"
   ACTIVEMQ_HOST="mq.example.com"
   ```

2. **Run only relevant scripts** on each machine:
   - Database server: `01-install_postgres.sh`
   - Application server: `02-06` and `08`
   - Search server: `02` and `07`
   - Web server: `09-10`

3. **Ensure network connectivity** between machines on required ports.

## Security Considerations

1. **Change default admin password** after first login
2. **Configure HTTPS** in Nginx for production
3. **Restrict network access** to internal ports (8080, 8983, etc.)
4. **Keep `config/alfresco.env` secure** - it contains passwords
5. **Regular backups** of `/home/ubuntu/alf_data` and PostgreSQL

## Upgrading

To upgrade components:

1. Update versions in `config/versions.conf`
2. Re-run the relevant installation script
3. Restart services

For Transform Service (uses symlink):
```bash
# Copy new JAR
cp new-transform-core-aio-X.Y.Z.jar /home/ubuntu/transform/

# Update symlink
ln -sf alfresco-transform-core-aio-X.Y.Z.jar /home/ubuntu/transform/alfresco-transform-core-aio.jar

# Restart
sudo systemctl restart transform
```