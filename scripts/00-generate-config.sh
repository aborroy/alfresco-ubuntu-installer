#!/bin/bash
# =============================================================================
# Configuration Generator
# =============================================================================
# Generates a secure alfresco.env configuration file with random passwords.
#
# Usage:
#   bash scripts/00-generate-config.sh [--force]
#
# Options:
#   --force    Overwrite existing configuration file
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${SCRIPT_DIR}/../config"
CONFIG_FILE="${CONFIG_DIR}/alfresco.env"
TEMPLATE_FILE="${CONFIG_DIR}/alfresco.env.template"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

# -----------------------------------------------------------------------------
# Password Generation
# -----------------------------------------------------------------------------
generate_password() {
    local length=${1:-16}
    # Generate alphanumeric password (safe for most contexts)
    openssl rand -base64 "$((length * 2))" | tr -dc 'a-zA-Z0-9' | head -c "$length"
}

generate_hex_secret() {
    local length=${1:-32}
    openssl rand -hex "$length"
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
    local force=false
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --force)
                force=true
                shift
                ;;
            *)
                log_error "Unknown option: $1"
                exit 1
                ;;
        esac
    done
    
    # Check if config already exists
    if [ -f "$CONFIG_FILE" ] && [ "$force" != "true" ]; then
        log_error "Configuration file already exists: $CONFIG_FILE"
        log_error "Use --force to overwrite"
        exit 1
    fi
    
    # Ensure config directory exists
    mkdir -p "$CONFIG_DIR"
    
    log_info "Generating secure configuration..."
    
    # Generate random passwords
    local db_password
    local solr_secret
    local keystore_password
    local keystore_metadata_password
    local activemq_password
    
    db_password=$(generate_password 20)
    solr_secret=$(generate_hex_secret 32)
    keystore_password=$(generate_password 16)
    keystore_metadata_password=$(generate_password 16)
    activemq_password=$(generate_password 16)
    
    # Create configuration file
    cat > "$CONFIG_FILE" << EOF
# =============================================================================
# Alfresco Environment Configuration
# =============================================================================
# Generated: $(date)
# 
# SECURITY WARNING:
# - Keep this file secure and never commit it to version control
# - Add 'config/alfresco.env' to your .gitignore
# =============================================================================

# -----------------------------------------------------------------------------
# Installation User and Paths
# -----------------------------------------------------------------------------
export ALFRESCO_USER="ubuntu"
export ALFRESCO_GROUP="ubuntu"
export ALFRESCO_HOME="/home/ubuntu"

# -----------------------------------------------------------------------------
# Database Configuration (PostgreSQL)
# -----------------------------------------------------------------------------
export ALFRESCO_DB_HOST="localhost"
export ALFRESCO_DB_PORT="5432"
export ALFRESCO_DB_NAME="alfresco"
export ALFRESCO_DB_USER="alfresco"
export ALFRESCO_DB_PASSWORD="${db_password}"

# -----------------------------------------------------------------------------
# Solr Configuration
# -----------------------------------------------------------------------------
export SOLR_HOST="localhost"
export SOLR_PORT="8983"
export SOLR_SHARED_SECRET="${solr_secret}"

# -----------------------------------------------------------------------------
# Keystore Configuration
# -----------------------------------------------------------------------------
export KEYSTORE_PASSWORD="${keystore_password}"
export KEYSTORE_METADATA_PASSWORD="${keystore_metadata_password}"

# -----------------------------------------------------------------------------
# ActiveMQ Configuration
# -----------------------------------------------------------------------------
export ACTIVEMQ_HOST="localhost"
export ACTIVEMQ_PORT="61616"
export ACTIVEMQ_WEBCONSOLE_PORT="8161"
export ACTIVEMQ_ADMIN_USER="admin"
export ACTIVEMQ_ADMIN_PASSWORD="${activemq_password}"

# -----------------------------------------------------------------------------
# Transform Service Configuration
# -----------------------------------------------------------------------------
export TRANSFORM_HOST="localhost"
export TRANSFORM_PORT="8090"

# -----------------------------------------------------------------------------
# Tomcat Configuration
# -----------------------------------------------------------------------------
export TOMCAT_HTTP_PORT="8080"
export TOMCAT_SHUTDOWN_PORT="8005"
export TOMCAT_AJP_PORT="8009"

# JVM Memory Settings (adjust based on available RAM)
export TOMCAT_XMS="2048M"
export TOMCAT_XMX="3072M"

# -----------------------------------------------------------------------------
# Nginx Configuration
# -----------------------------------------------------------------------------
export NGINX_HTTP_PORT="80"
export NGINX_HTTPS_PORT="443"
export NGINX_SERVER_NAME="localhost"

# -----------------------------------------------------------------------------
# Alfresco URL Configuration
# -----------------------------------------------------------------------------
export ALFRESCO_PROTOCOL="http"
export ALFRESCO_HOST="localhost"
export ALFRESCO_PORT="8080"

export SHARE_PROTOCOL="http"
export SHARE_HOST="localhost"
export SHARE_PORT="8080"
EOF

    # Secure the configuration file
    chmod 600 "$CONFIG_FILE"
    
    log_info "Configuration generated successfully: $CONFIG_FILE"
    log_info ""
    log_warn "IMPORTANT: Review and customize the configuration before installation:"
    log_info "  - Database password: (auto-generated)"
    log_info "  - Solr secret: (auto-generated)"
    log_info "  - Memory settings: TOMCAT_XMS/TOMCAT_XMX"
    log_info "  - Host settings: for multi-machine deployment"
    log_info ""
    log_info "To view generated passwords:"
    log_info "  cat $CONFIG_FILE"
}

main "$@"
