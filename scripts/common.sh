#!/bin/bash
# =============================================================================
# Common Functions and Configuration Loading
# =============================================================================
# This file provides shared utilities for all installation scripts.
# Source this file at the beginning of each script:
#   source "$(dirname "$0")/common.sh"
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# Color Codes for Output
# -----------------------------------------------------------------------------
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# -----------------------------------------------------------------------------
# Script Directory Detection
# -----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}")" && pwd)"
readonly SCRIPT_DIR
readonly CONFIG_DIR="${SCRIPT_DIR}/../config"

# -----------------------------------------------------------------------------
# Logging Functions
# -----------------------------------------------------------------------------
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

log_step() {
    echo -e "${BLUE}[STEP]${NC} $1"
}

# -----------------------------------------------------------------------------
# Configuration Loading
# -----------------------------------------------------------------------------
load_config() {
    local env_file="${CONFIG_DIR}/alfresco.env"
    local versions_file="${CONFIG_DIR}/versions.conf"
    
    # Load versions configuration
    if [ -f "$versions_file" ]; then
        # shellcheck source=/dev/null
        source "$versions_file"
        log_info "Versions loaded from $versions_file"
    else
        log_error "Versions file not found: $versions_file"
        exit 1
    fi
    
    # Load environment configuration
    if [ -f "$env_file" ]; then
        # shellcheck source=/dev/null
        source "$env_file"
        log_info "Configuration loaded from $env_file"
    else
        log_error "Configuration file not found: $env_file"
        log_error "Run 'bash scripts/00-generate-config.sh' first"
        exit 1
    fi
    
    # Validate critical settings
    validate_config
}

validate_config() {
    local errors=0
    
    # Check for default passwords that should be changed
    if [ "${ALFRESCO_DB_PASSWORD:-}" = "CHANGE_ME" ]; then
        log_error "ALFRESCO_DB_PASSWORD is set to default value. Please update config/alfresco.env"
        ((errors++))
    fi
    
    if [ "${SOLR_SHARED_SECRET:-}" = "CHANGE_ME" ]; then
        log_error "SOLR_SHARED_SECRET is set to default value. Please update config/alfresco.env"
        ((errors++))
    fi
    
    if [ $errors -gt 0 ]; then
        log_error "Configuration validation failed. Please fix the errors above."
        exit 1
    fi
}

# -----------------------------------------------------------------------------
# Prerequisite Checking
# -----------------------------------------------------------------------------
check_prerequisites() {
    local prereqs=("$@")
    local missing=()
    
    for cmd in "${prereqs[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            missing+=("$cmd")
        fi
    done
    
    if [ ${#missing[@]} -gt 0 ]; then
        log_error "Missing required commands: ${missing[*]}"
        exit 1
    fi
}

check_root() {
    if [ "$(id -u)" -eq 0 ]; then
        log_error "This script should not be run as root. Use a regular user with sudo privileges."
        exit 1
    fi
}

check_sudo() {
    if ! sudo -n true 2>/dev/null; then
        log_warn "This script requires sudo privileges. You may be prompted for your password."
    fi
}

# -----------------------------------------------------------------------------
# Service Management
# -----------------------------------------------------------------------------
wait_for_service() {
    local host=$1
    local port=$2
    local service_name=$3
    local max_attempts=${4:-30}
    local attempt=1

    log_info "Waiting for $service_name to be ready on $host:$port..."
    
    while ! nc -z "$host" "$port" 2>/dev/null; do
        if [ $attempt -ge "$max_attempts" ]; then
            log_error "$service_name failed to start within expected time"
            return 1
        fi
        echo -n "."
        sleep 2
        ((attempt++))
    done
    
    echo ""
    log_info "$service_name is ready"
}

service_exists() {
    local service_name=$1
    systemctl list-unit-files "${service_name}.service" &>/dev/null
}

service_is_active() {
    local service_name=$1
    systemctl is-active --quiet "$service_name"
}

# -----------------------------------------------------------------------------
# File and Directory Management
# -----------------------------------------------------------------------------
ensure_directory() {
    local dir=$1
    local owner=${2:-$USER}
    local perms=${3:-755}
    
    if [ ! -d "$dir" ]; then
        mkdir -p "$dir"
        log_info "Created directory: $dir"
    fi
    
    if [ "$(id -u)" -eq 0 ] || sudo -n true 2>/dev/null; then
        sudo chown "$owner:$owner" "$dir"
        sudo chmod "$perms" "$dir"
    fi
}

backup_file() {
    local file=$1
    local backup_dir=${2:-/tmp/alfresco-backup}
    
    if [ -f "$file" ]; then
        mkdir -p "$backup_dir"
        local backup_name
        backup_name="$(basename "$file").$(date +%Y%m%d_%H%M%S).bak"
        # Use sudo if file is not readable by current user
        if [ -r "$file" ]; then
            cp "$file" "$backup_dir/$backup_name"
        else
            sudo cp "$file" "$backup_dir/$backup_name"
        fi
        log_info "Backed up $file to $backup_dir/$backup_name"
    fi
}

# -----------------------------------------------------------------------------
# PostgreSQL Helpers
# -----------------------------------------------------------------------------
pg_user_exists() {
    local username=$1
    sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$username'" 2>/dev/null | grep -q 1
}

pg_database_exists() {
    local dbname=$1
    sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='$dbname'" 2>/dev/null | grep -q 1
}

pg_execute() {
    local sql=$1
    sudo -u postgres psql -c "$sql"
}

# -----------------------------------------------------------------------------
# Version Fetching (for USE_LATEST_VERSIONS=true)
# -----------------------------------------------------------------------------
fetch_latest_version() {
    local base_url=$1
    curl -s "$base_url" \
        | sed -n 's/.*<a href="\(.*\)\/">.*/\1/p' \
        | grep -E '^[0-9]+(\.[0-9]+)*$' \
        | sort -V \
        | tail -n 1
}

get_version() {
    local component=$1
    local pinned_version=$2
    local base_url=${3:-}
    
    if [ "${USE_LATEST_VERSIONS:-false}" = "true" ] && [ -n "$base_url" ]; then
        local latest
        latest=$(fetch_latest_version "$base_url")
        if [ -n "$latest" ]; then
            log_warn "Using latest $component version: $latest (pinned was: $pinned_version)"
            echo "$latest"
            return
        fi
    fi
    
    log_info "Using pinned $component version: $pinned_version"
    echo "$pinned_version"
}

# -----------------------------------------------------------------------------
# Error Handling
# -----------------------------------------------------------------------------
trap_error() {
    log_error "Script failed at line $1. Exit code: $2"
}

setup_error_handling() {
    trap 'trap_error ${LINENO} $?' ERR
}

# -----------------------------------------------------------------------------
# Cleanup Handler
# -----------------------------------------------------------------------------
cleanup_on_exit() {
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        log_error "Script exited with error code: $exit_code"
    fi
}

setup_cleanup() {
    trap cleanup_on_exit EXIT
}

# -----------------------------------------------------------------------------
# Memory Detection and Allocation
# -----------------------------------------------------------------------------
# Recommended memory distribution for 16GB system:
#   - PostgreSQL: ~2GB (shared_buffers, effective_cache_size)
#   - Tomcat/Alfresco: ~4-6GB heap
#   - Solr: ~2GB heap
#   - Transform: ~1GB heap
#   - ActiveMQ: ~512MB heap
#   - OS/Buffer: ~4-5GB
# -----------------------------------------------------------------------------

# Get total system memory in MB
get_total_memory_mb() {
    local mem_kb
    mem_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    echo $((mem_kb / 1024))
}

# Get available memory in MB
get_available_memory_mb() {
    local mem_kb
    mem_kb=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
    echo $((mem_kb / 1024))
}

# Calculate memory allocation for all Alfresco components
# Sets global variables: MEM_TOMCAT_XMS, MEM_TOMCAT_XMX, MEM_SOLR, etc.
calculate_memory_allocation() {
    local total_mb
    total_mb=$(get_total_memory_mb)
    
    log_info "Detected system memory: ${total_mb}MB"
    
    # Memory profiles based on total RAM
    if [ "$total_mb" -lt 8192 ]; then
        # < 8GB - Minimal (development only)
        log_warn "System has less than 8GB RAM. Performance may be degraded."
        MEM_PROFILE="minimal"
        MEM_TOMCAT_XMS=1024
        MEM_TOMCAT_XMX=2048
        MEM_SOLR=512
        MEM_TRANSFORM=512
        MEM_ACTIVEMQ=256
        MEM_POSTGRES_SHARED=256
        MEM_POSTGRES_CACHE=512
        
    elif [ "$total_mb" -lt 16384 ]; then
        # 8-16GB - Small
        log_info "Applying 'small' memory profile (8-16GB)"
        MEM_PROFILE="small"
        MEM_TOMCAT_XMS=2048
        MEM_TOMCAT_XMX=3072
        MEM_SOLR=1024
        MEM_TRANSFORM=768
        MEM_ACTIVEMQ=512
        MEM_POSTGRES_SHARED=512
        MEM_POSTGRES_CACHE=1024
        
    elif [ "$total_mb" -lt 32768 ]; then
        # 16-32GB - Medium (recommended)
        log_info "Applying 'medium' memory profile (16-32GB)"
        MEM_PROFILE="medium"
        MEM_TOMCAT_XMS=4096
        MEM_TOMCAT_XMX=6144
        MEM_SOLR=2048
        MEM_TRANSFORM=1024
        MEM_ACTIVEMQ=512
        MEM_POSTGRES_SHARED=1024
        MEM_POSTGRES_CACHE=2048
        
    elif [ "$total_mb" -lt 65536 ]; then
        # 32-64GB - Large
        log_info "Applying 'large' memory profile (32-64GB)"
        MEM_PROFILE="large"
        MEM_TOMCAT_XMS=8192
        MEM_TOMCAT_XMX=12288
        MEM_SOLR=4096
        MEM_TRANSFORM=2048
        MEM_ACTIVEMQ=1024
        MEM_POSTGRES_SHARED=2048
        MEM_POSTGRES_CACHE=4096
        
    else
        # 64GB+ - Extra Large
        log_info "Applying 'xlarge' memory profile (64GB+)"
        MEM_PROFILE="xlarge"
        MEM_TOMCAT_XMS=16384
        MEM_TOMCAT_XMX=24576
        MEM_SOLR=8192
        MEM_TRANSFORM=4096
        MEM_ACTIVEMQ=2048
        MEM_POSTGRES_SHARED=4096
        MEM_POSTGRES_CACHE=8192
    fi
    
    # Allow override from environment/config
    MEM_TOMCAT_XMS="${TOMCAT_XMS_MB:-$MEM_TOMCAT_XMS}"
    MEM_TOMCAT_XMX="${TOMCAT_XMX_MB:-$MEM_TOMCAT_XMX}"
    MEM_SOLR="${SOLR_HEAP_MB:-$MEM_SOLR}"
    MEM_TRANSFORM="${TRANSFORM_HEAP_MB:-$MEM_TRANSFORM}"
    MEM_ACTIVEMQ="${ACTIVEMQ_HEAP_MB:-$MEM_ACTIVEMQ}"
    MEM_POSTGRES_SHARED="${POSTGRES_SHARED_BUFFERS_MB:-$MEM_POSTGRES_SHARED}"
    MEM_POSTGRES_CACHE="${POSTGRES_EFFECTIVE_CACHE_MB:-$MEM_POSTGRES_CACHE}"
    
    # Export for use in scripts
    export MEM_PROFILE
    export MEM_TOMCAT_XMS MEM_TOMCAT_XMX
    export MEM_SOLR MEM_TRANSFORM MEM_ACTIVEMQ
    export MEM_POSTGRES_SHARED MEM_POSTGRES_CACHE
}

# Display memory allocation summary
show_memory_allocation() {
    log_info "Memory allocation (${MEM_PROFILE} profile):"
    log_info "  Tomcat/Alfresco: ${MEM_TOMCAT_XMS}MB - ${MEM_TOMCAT_XMX}MB"
    log_info "  Solr:            ${MEM_SOLR}MB"
    log_info "  Transform:       ${MEM_TRANSFORM}MB"
    log_info "  ActiveMQ:        ${MEM_ACTIVEMQ}MB"
    log_info "  PostgreSQL:      shared_buffers=${MEM_POSTGRES_SHARED}MB, effective_cache=${MEM_POSTGRES_CACHE}MB"
}

# Check if system meets minimum memory requirements
check_memory_requirements() {
    local min_mb=${1:-8192}  # Default 8GB minimum
    local total_mb
    total_mb=$(get_total_memory_mb)
    
    if [ "$total_mb" -lt "$min_mb" ]; then
        log_warn "System has ${total_mb}MB RAM, but ${min_mb}MB is recommended."
        log_warn "Alfresco may not perform well with limited memory."
        return 1
    fi
    
    return 0
}

# -----------------------------------------------------------------------------
# Initialize
# -----------------------------------------------------------------------------
setup_error_handling