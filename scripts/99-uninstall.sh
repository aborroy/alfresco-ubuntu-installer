#!/bin/bash
# =============================================================================
# Uninstall Script
# =============================================================================
# Stops services, disables them, and removes all Alfresco-related files,
# configurations, and systemd units created by the installer.
#
# Usage:
#   bash scripts/99-uninstall.sh [OPTIONS]
#
# Options:
#   --force            Skip confirmation prompts
#   --keep-db          Keep PostgreSQL database and user
#   --keep-java        Keep the installed Java JDK
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh" 2>/dev/null || true

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }
log_step() { echo -e "${BLUE}[STEP]${NC} $1"; }

# Defaults
FORCE=false
KEEP_DB=false
KEEP_JAVA=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --force)
            FORCE=true
            shift
            ;;
        --keep-db)
            KEEP_DB=true
            shift
            ;;
        --keep-java)
            KEEP_JAVA=true
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --force            Skip confirmation prompts"
            echo "  --keep-db          Keep PostgreSQL database and user"
            echo "  --keep-java        Keep the installed Java JDK"
            echo "  -h, --help         Show this help message"
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

if [ "$FORCE" != "true" ]; then
    echo ""
    log_warn "============================================================"
    log_warn "WARNING: This script will remove Alfresco and its dependencies."
    log_warn "All data, configurations, and logs will be permanently deleted!"
    log_warn "============================================================"
    echo ""
    read -r -p "Are you sure you want to proceed? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log_info "Uninstall cancelled."
        exit 0
    fi
fi

log_step "Stopping and disabling services..."
for service in tomcat activemq transform solr opensearch batch-indexer; do
    if systemctl is-active --quiet "$service" 2>/dev/null; then
        sudo systemctl stop "$service" 2>/dev/null || true
        log_info "Stopped $service"
    fi
    if systemctl is-enabled --quiet "$service" 2>/dev/null; then
        sudo systemctl disable "$service" 2>/dev/null || true
        log_info "Disabled $service"
    fi
done

log_step "Removing systemd service files..."
for service in tomcat activemq transform solr opensearch batch-indexer; do
    if [ -f "/etc/systemd/system/${service}.service" ]; then
        sudo rm -f "/etc/systemd/system/${service}.service"
        log_info "Removed ${service}.service"
    fi
done
sudo systemctl daemon-reload 2>/dev/null || true

log_step "Removing Nginx configuration..."
if [ -f /etc/nginx/sites-available/alfresco ]; then
    sudo rm -f /etc/nginx/sites-available/alfresco
    sudo rm -f /etc/nginx/sites-enabled/alfresco
    log_info "Removed Nginx site configuration"
fi
if [ -f /etc/nginx/sites-available/alfresco.conf ]; then
    sudo rm -f /etc/nginx/sites-available/alfresco.conf
    sudo rm -f /etc/nginx/sites-enabled/alfresco.conf
    log_info "Removed Nginx site configuration (alt)"
fi

log_step "Removing installation directories..."
USER_HOME="${ALFRESCO_HOME:-$HOME}"

dirs_to_remove=(
    "$USER_HOME/tomcat"
    "$USER_HOME/activemq"
    "$USER_HOME/transform"
    "$USER_HOME/solr"
    "$USER_HOME/opensearch"
    "$USER_HOME/batch-indexer"
    "$USER_HOME/alf_data"
    "$USER_HOME/alfresco"
)

for dir in "${dirs_to_remove[@]}"; do
    if [ -d "$dir" ]; then
        sudo rm -rf "$dir"
        log_info "Removed $dir"
    fi
done

if [ "$KEEP_DB" != "true" ]; then
    log_step "Removing PostgreSQL database and user..."
    if command -v psql &> /dev/null; then
        sudo -u postgres psql -c "DROP DATABASE IF EXISTS alfresco;" 2>/dev/null || true
        sudo -u postgres psql -c "DROP ROLE IF EXISTS alfresco;" 2>/dev/null || true
        log_info "Removed Alfresco database and user from PostgreSQL"
    else
        log_warn "PostgreSQL client not found, skipping database cleanup"
    fi
else
    log_info "Keeping PostgreSQL database and user (--keep-db)"
fi

if [ "$KEEP_JAVA" != "true" ]; then
    log_step "Removing Java JDK..."
    if command -v java &> /dev/null; then
        JAVA_VERSION_NUM=$(java -version 2>&1 | head -1 | grep -oP '(?<=version ")1\.\d+\.\d+"$' | cut -d. -f2)
        if [ -n "$JAVA_VERSION_NUM" ]; then
            sudo apt-get purge -y "openjdk-${JAVA_VERSION_NUM}-*" 2>/dev/null || true
        fi
        if [ -f /etc/profile.d/java.sh ]; then
            sudo rm -f /etc/profile.d/java.sh
            log_info "Removed Java environment configuration"
        fi
        log_info "Java cleanup completed (run 'sudo apt autoremove' to clear dependencies)"
    else
        log_warn "Java not found via command, skipping Java cleanup"
    fi
else
    log_info "Keeping Java JDK (--keep-java)"
fi

log_step "Cleaning up..."
if [ -d "$USER_HOME/.m2" ]; then
    log_info "Leaving Maven cache ($USER_HOME/.m2) intact"
fi

echo ""
log_info "Uninstallation completed successfully!"
log_warn "Remember to remove 'config/alfresco.env' if you want to regenerate it later:"
log_warn "  rm ${SCRIPT_DIR}/../config/alfresco.env"
