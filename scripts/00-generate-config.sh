#!/bin/bash
# =============================================================================
# Configuration Generator
# =============================================================================
# Generates a secure alfresco.env configuration file with random passwords
# and optionally selects a version profile.
#
# Usage:
#   bash scripts/00-generate-config.sh [OPTIONS]
#
# Options:
#   --force              Overwrite existing configuration file
#   --profile PROFILE    Select version profile: 7.4, 23.x, 25.x (default: 23.x)
#   --list-profiles      List available version profiles
#
# Examples:
#   bash scripts/00-generate-config.sh                    # Use default (23.x)
#   bash scripts/00-generate-config.sh --profile 7.4      # Use Alfresco 7.4
#   bash scripts/00-generate-config.sh --profile 25.x     # Use Alfresco 25.x
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${SCRIPT_DIR}/../config"
CONFIG_FILE="${CONFIG_DIR}/alfresco.env"
VERSIONS_FILE="${CONFIG_DIR}/versions.conf"
PROFILES_DIR="${CONFIG_DIR}/profiles"
# shellcheck source=/dev/null

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

# Generate MD4 hash for Alfresco admin password
# Alfresco uses MD4 with UTF-16LE encoding for initial admin password
# Note: MD4 is deprecated in OpenSSL 3.x, so we use the legacy provider
generate_md4_hash() {
    local password=$1
    # Try with legacy provider first (OpenSSL 3.x), fallback to standard (OpenSSL 1.x)
    if printf '%s' "$password" | iconv -t utf-16le | openssl md4 -provider legacy -provider default 2>/dev/null | cut -d ' ' -f 2; then
        return 0
    elif printf '%s' "$password" | iconv -t utf-16le | openssl md4 2>/dev/null | cut -d ' ' -f 2; then
        return 0
    else
        log_error "Failed to generate MD4 hash. OpenSSL legacy provider may not be available."
        log_error "Using default admin password hash (admin/admin)"
        echo "209c6174da490caeb422f3fa5a7ae634"
    fi
}

# -----------------------------------------------------------------------------
# Profile Management
# -----------------------------------------------------------------------------
list_profiles() {
    echo ""
    echo "Available Alfresco Version Profiles:"
    echo "====================================="
    echo ""
    
    for profile in "$PROFILES_DIR"/versions-*.conf; do
        if [ -f "$profile" ]; then
            local name
            name=$(basename "$profile" | sed 's/versions-\(.*\)\.conf/\1/')
            local version
            version=$(grep "^ALFRESCO_VERSION=" "$profile" | cut -d'"' -f2)
            local java
            java=$(grep "^JAVA_VERSION=" "$profile" | cut -d'"' -f2)
            local tomcat
            tomcat=$(grep "^TOMCAT_VERSION=" "$profile" | cut -d'"' -f2)
            
            printf "  %-8s  Alfresco %-8s  Java %-4s  Tomcat %s\n" "$name" "$version" "$java" "$tomcat"
        fi
    done
    
    echo ""
    echo "Usage: $0 --profile <profile-name>"
    echo ""
}

select_profile() {
    local profile_name=$1
    local profile_file="${PROFILES_DIR}/versions-${profile_name}.conf"
    
    if [ ! -f "$profile_file" ]; then
        log_error "Profile not found: $profile_name"
        log_error "Available profiles:"
        for p in "$PROFILES_DIR"/versions-*.conf; do
            if [ -f "$p" ]; then
                echo "  - $(basename "$p" | sed 's/versions-\(.*\)\.conf/\1/')"
            fi
        done
        exit 1
    fi
    
    # Copy profile to versions.conf
    cp "$profile_file" "$VERSIONS_FILE"
    log_info "Selected version profile: $profile_name"
    
    # Display key versions
    local alf_version
    local search_version
    local transform_version
    alf_version=$(grep "^ALFRESCO_VERSION=" "$VERSIONS_FILE" | cut -d'"' -f2)
    search_version=$(grep "^ALFRESCO_SEARCH_VERSION=" "$VERSIONS_FILE" | cut -d'"' -f2)
    transform_version=$(grep "^ALFRESCO_TRANSFORM_VERSION=" "$VERSIONS_FILE" | cut -d'"' -f2)
    
    log_info "  Alfresco:  $alf_version"
    log_info "  Search:    $search_version"
    log_info "  Transform: $transform_version"
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
    local force=false
    local profile="23.x"  # Default profile
    local env_only=false
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --force)
                force=true
                shift
                ;;
            --profile)
                profile="$2"
                shift 2
                ;;
            --list-profiles)
                list_profiles
                exit 0
                ;;
            --env-only)
                env_only=true
                shift
                ;;
            -h|--help)
                echo "Usage: $0 [OPTIONS]"
                echo ""
                echo "Options:"
                echo "  --force              Overwrite existing configuration"
                echo "  --profile PROFILE    Select version profile: 7.4, 23.x, 25.x"
                echo "  --list-profiles      List available version profiles"
                echo "  --env-only           Only generate alfresco.env (skip versions.conf)"
                echo "  -h, --help           Show this help message"
                exit 0
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
    
    log_step "Generating Alfresco configuration..."
    echo ""
    
    # Select version profile (unless env-only)
    if [ "$env_only" != "true" ]; then
        select_profile "$profile"
        echo ""
    fi
    
    log_info "Generating secure credentials..."
    
    # Generate random passwords
    local db_password
    local solr_secret
    local activemq_password
    local admin_password
    local admin_password_hash
    
    db_password=$(generate_password 20)
    solr_secret=$(generate_hex_secret 32)
    activemq_password=$(generate_password 16)
    admin_password=$(generate_password 12)
    admin_password_hash=$(generate_md4_hash "$admin_password")
    
    # Detect current user and group
    local current_user
    local current_group
    local current_home
    current_user="$(whoami)"
    current_group="$(id -gn)"
    current_home="$(eval echo ~"$current_user")"
    
    log_info "Detected user: $current_user (group: $current_group, home: $current_home)"
    
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
export ALFRESCO_USER="${current_user}"
export ALFRESCO_GROUP="${current_group}"
export ALFRESCO_HOME="${current_home}"

# -----------------------------------------------------------------------------
# Database Configuration (PostgreSQL)
# -----------------------------------------------------------------------------
export ALFRESCO_DB_HOST="localhost"
export ALFRESCO_DB_PORT="5432"
export ALFRESCO_DB_NAME="alfresco"
export ALFRESCO_DB_USER="alfresco"
export ALFRESCO_DB_PASSWORD="${db_password}"

# -----------------------------------------------------------------------------
# Alfresco Admin User Configuration
# -----------------------------------------------------------------------------
# Admin password is set during initial repository bootstrap.
# Once the repository is initialized, changing this will have no effect.
# To change password after initialization, use the Alfresco UI or API.
export ALFRESCO_ADMIN_PASSWORD="${admin_password}"
export ALFRESCO_ADMIN_PASSWORD_HASH="${admin_password_hash}"

# -----------------------------------------------------------------------------
# Solr Configuration
# -----------------------------------------------------------------------------
export SOLR_HOST="localhost"
export SOLR_PORT="8983"
export SOLR_SHARED_SECRET="${solr_secret}"

# -----------------------------------------------------------------------------
# Keystore Configuration - Fixed (using default / previous keystore)
# -----------------------------------------------------------------------------
export KEYSTORE_PASSWORD="mp6yc0UD9e"
export KEYSTORE_METADATA_PASSWORD="oKIWzVdEdA"

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

# -----------------------------------------------------------------------------
# Memory Settings (Auto-calculated based on system RAM if not set)
# -----------------------------------------------------------------------------
# Memory is automatically allocated based on total system RAM:
#   < 8GB:   minimal profile (not recommended for production)
#   8-16GB:  small profile
#   16-32GB: medium profile (recommended)
#   32-64GB: large profile
#   64GB+:   xlarge profile
#
# Current system: $(free -h | awk '/^Mem:/{print $2}') RAM
#
# Uncomment and modify these lines to override auto-detection (values in MB):
# export TOMCAT_XMS_MB="4096"        # Tomcat initial heap
# export TOMCAT_XMX_MB="6144"        # Tomcat maximum heap
# export SOLR_HEAP_MB="2048"         # Solr heap
# export TRANSFORM_HEAP_MB="1024"    # Transform service heap
# export ACTIVEMQ_HEAP_MB="512"      # ActiveMQ heap
# export POSTGRES_SHARED_BUFFERS_MB="1024"   # PostgreSQL shared_buffers
# export POSTGRES_EFFECTIVE_CACHE_MB="2048"  # PostgreSQL effective_cache_size
EOF

    # Secure the configuration file
    chmod 600 "$CONFIG_FILE"
    
    log_info "Configuration generated successfully: $CONFIG_FILE"
    log_info ""
    log_warn "IMPORTANT: Review and customize the configuration before installation:"
    log_info "  - Installation user: ${current_user}"
    log_info "  - Installation home: ${current_home}"
    log_info "  - Admin password: (auto-generated, see config file)"
    log_info "  - Database password: (auto-generated)"
    log_info "  - Solr secret: (auto-generated)"
    log_info "  - Memory settings: TOMCAT_XMS/TOMCAT_XMX"
    log_info "  - Host settings: for multi-machine deployment"
    log_info ""
    log_warn "SECURITY: The admin password is only set during initial bootstrap."
    log_warn "          Save it securely - you'll need it to log in!"
    log_info ""
    log_info "To view generated passwords:"
    log_info "  cat $CONFIG_FILE"
}

main "$@"