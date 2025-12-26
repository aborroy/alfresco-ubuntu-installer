#!/bin/bash
# =============================================================================
# PostgreSQL Installation Script
# =============================================================================
# Installs and configures PostgreSQL for Alfresco Content Services.
#
# Prerequisites:
# - Run 00-generate-config.sh first to create configuration
# - Ubuntu 22.04 or 24.04
# - sudo privileges
#
# Usage:
#   bash scripts/01-install_postgres.sh
# =============================================================================

# Load common functions and configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# -----------------------------------------------------------------------------
# Main Installation
# -----------------------------------------------------------------------------
main() {
    log_step "Starting PostgreSQL installation..."
    
    # Pre-flight checks
    check_root  # Ensure not running as root
    check_sudo  # Verify sudo access
    load_config # Load configuration from alfresco.env
    
    # Check memory requirements
    check_memory_requirements 8192 || true
    
    # Install PostgreSQL
    install_postgresql
    
    # Configure PostgreSQL
    configure_authentication
    configure_postgresql_memory
    
    # Restart service to apply configuration
    restart_postgresql
    
    # Create Alfresco database and user
    create_alfresco_database
    
    # Enable service on boot
    enable_postgresql
    
    # Verify installation
    verify_installation
    
    log_info "PostgreSQL installation and setup completed successfully!"
}

# -----------------------------------------------------------------------------
# Install PostgreSQL
# -----------------------------------------------------------------------------
install_postgresql() {
    log_step "Installing PostgreSQL ${POSTGRESQL_VERSION}..."
    
    # Check if PostgreSQL is already installed
    if command -v psql &> /dev/null; then
        local installed_version
        installed_version=$(psql --version | grep -oP '\d+' | head -1)
        log_info "PostgreSQL ${installed_version} is already installed"
        
        if [ "$installed_version" != "$POSTGRESQL_VERSION" ]; then
            log_warn "Installed version ($installed_version) differs from configured version ($POSTGRESQL_VERSION)"
            log_warn "Continuing with installed version..."
        fi
        return 0
    fi
    
    # Update package list
    log_info "Updating package list..."
    sudo apt-get update
    
    # Install PostgreSQL
    log_info "Installing PostgreSQL packages..."
    sudo apt-get install -y "postgresql-${POSTGRESQL_VERSION}" postgresql-contrib
    
    log_info "PostgreSQL ${POSTGRESQL_VERSION} installed successfully"
}

# -----------------------------------------------------------------------------
# Configure Authentication
# -----------------------------------------------------------------------------
configure_authentication() {
    log_step "Configuring PostgreSQL authentication..."
    
    local pg_hba_file="/etc/postgresql/${POSTGRESQL_VERSION}/main/pg_hba.conf"
    
    if [ ! -f "$pg_hba_file" ]; then
        log_error "pg_hba.conf not found at: $pg_hba_file"
        exit 1
    fi
    
    # Backup original configuration
    backup_file "$pg_hba_file"
    
    # Check if already configured for Alfresco
    if grep -q "# Alfresco Configuration" "$pg_hba_file"; then
        log_info "PostgreSQL authentication already configured for Alfresco"
        return 0
    fi
    
    # Configure authentication:
    # - Keep peer authentication for postgres user (secure local admin access)
    # - Use scram-sha-256 for alfresco user connections
    
    log_info "Updating pg_hba.conf..."
    
    # Add Alfresco-specific configuration before the default entries
    sudo sed -i '/^# TYPE/a\
# Alfresco Configuration\
host    alfresco        alfresco        127.0.0.1/32            scram-sha-256\
host    alfresco        alfresco        ::1/128                 scram-sha-256\
local   alfresco        alfresco                                md5' "$pg_hba_file"
    
    log_info "Authentication configured successfully"
}

# -----------------------------------------------------------------------------
# Restart PostgreSQL
# -----------------------------------------------------------------------------
restart_postgresql() {
    log_step "Restarting PostgreSQL service..."
    
    sudo systemctl restart postgresql
    
    # Wait for PostgreSQL to be ready
    local max_attempts=30
    local attempt=1
    
    while ! sudo -u postgres pg_isready -q 2>/dev/null; do
        if [ $attempt -ge $max_attempts ]; then
            log_error "PostgreSQL failed to start within expected time"
            exit 1
        fi
        echo -n "."
        sleep 1
        ((attempt++))
    done
    echo ""
    
    log_info "PostgreSQL is running"
}

# -----------------------------------------------------------------------------
# Create Alfresco Database and User
# -----------------------------------------------------------------------------
create_alfresco_database() {
    log_step "Configuring Alfresco database..."
    
    # Create user if not exists
    if pg_user_exists "${ALFRESCO_DB_USER}"; then
        log_info "User '${ALFRESCO_DB_USER}' already exists"
        
        # Update password in case it changed
        log_info "Updating password for user '${ALFRESCO_DB_USER}'..."
        pg_execute "ALTER USER ${ALFRESCO_DB_USER} WITH PASSWORD '${ALFRESCO_DB_PASSWORD}';"
    else
        log_info "Creating user '${ALFRESCO_DB_USER}'..."
        pg_execute "CREATE USER ${ALFRESCO_DB_USER} WITH PASSWORD '${ALFRESCO_DB_PASSWORD}';"
    fi
    
    # Create database if not exists
    if pg_database_exists "${ALFRESCO_DB_NAME}"; then
        log_info "Database '${ALFRESCO_DB_NAME}' already exists"
    else
        log_info "Creating database '${ALFRESCO_DB_NAME}'..."
        pg_execute "CREATE DATABASE ${ALFRESCO_DB_NAME} OWNER ${ALFRESCO_DB_USER} ENCODING 'UTF8';"
    fi
    
    # Ensure privileges are set correctly
    log_info "Configuring database privileges..."
    pg_execute "GRANT ALL PRIVILEGES ON DATABASE ${ALFRESCO_DB_NAME} TO ${ALFRESCO_DB_USER};"
    
    # For PostgreSQL 15+, also grant schema privileges
    local pg_version
    pg_version=$(sudo -u postgres psql -tAc "SHOW server_version_num" | cut -c1-2)
    if [ "$pg_version" -ge 15 ]; then
        log_info "Configuring schema privileges for PostgreSQL ${pg_version}..."
        sudo -u postgres psql -d "${ALFRESCO_DB_NAME}" -c "GRANT ALL ON SCHEMA public TO ${ALFRESCO_DB_USER};"
    fi
    
    log_info "Database configuration completed"
}

# -----------------------------------------------------------------------------
# Configure PostgreSQL Performance
# -----------------------------------------------------------------------------
configure_postgresql_memory() {
    log_step "Configuring PostgreSQL memory settings..."
    
    # Calculate memory allocation
    calculate_memory_allocation
    
    local pg_conf="/etc/postgresql/${POSTGRESQL_VERSION}/main/postgresql.conf"
    
    if [ ! -f "$pg_conf" ]; then
        log_warn "postgresql.conf not found, skipping memory configuration"
        return 0
    fi
    
    backup_file "$pg_conf"
    
    log_info "Applying memory settings: shared_buffers=${MEM_POSTGRES_SHARED}MB, effective_cache_size=${MEM_POSTGRES_CACHE}MB"
    
    # Update shared_buffers
    if grep -q "^shared_buffers" "$pg_conf"; then
        sudo sed -i "s/^shared_buffers.*/shared_buffers = ${MEM_POSTGRES_SHARED}MB/" "$pg_conf"
    else
        echo "shared_buffers = ${MEM_POSTGRES_SHARED}MB" | sudo tee -a "$pg_conf" > /dev/null
    fi
    
    # Update effective_cache_size
    if grep -q "^effective_cache_size" "$pg_conf"; then
        sudo sed -i "s/^effective_cache_size.*/effective_cache_size = ${MEM_POSTGRES_CACHE}MB/" "$pg_conf"
    else
        echo "effective_cache_size = ${MEM_POSTGRES_CACHE}MB" | sudo tee -a "$pg_conf" > /dev/null
    fi
    
    # Update work_mem (per-operation memory)
    local work_mem=$((MEM_POSTGRES_SHARED / 16))
    [ $work_mem -lt 4 ] && work_mem=4
    [ $work_mem -gt 256 ] && work_mem=256
    
    if grep -q "^work_mem" "$pg_conf"; then
        sudo sed -i "s/^work_mem.*/work_mem = ${work_mem}MB/" "$pg_conf"
    else
        echo "work_mem = ${work_mem}MB" | sudo tee -a "$pg_conf" > /dev/null
    fi
    
    # Update maintenance_work_mem
    local maint_mem=$((MEM_POSTGRES_SHARED / 4))
    [ $maint_mem -lt 64 ] && maint_mem=64
    [ $maint_mem -gt 2048 ] && maint_mem=2048
    
    if grep -q "^maintenance_work_mem" "$pg_conf"; then
        sudo sed -i "s/^maintenance_work_mem.*/maintenance_work_mem = ${maint_mem}MB/" "$pg_conf"
    else
        echo "maintenance_work_mem = ${maint_mem}MB" | sudo tee -a "$pg_conf" > /dev/null
    fi
    
    # Checkpoint settings for better write performance
    if grep -q "^checkpoint_completion_target" "$pg_conf"; then
        sudo sed -i "s/^checkpoint_completion_target.*/checkpoint_completion_target = 0.9/" "$pg_conf"
    else
        echo "checkpoint_completion_target = 0.9" | sudo tee -a "$pg_conf" > /dev/null
    fi
    
    # WAL settings
    if grep -q "^wal_buffers" "$pg_conf"; then
        sudo sed -i "s/^wal_buffers.*/wal_buffers = 16MB/" "$pg_conf"
    else
        echo "wal_buffers = 16MB" | sudo tee -a "$pg_conf" > /dev/null
    fi
    
    log_info "PostgreSQL memory configuration applied"
}

# -----------------------------------------------------------------------------
# Enable PostgreSQL on Boot
# -----------------------------------------------------------------------------
enable_postgresql() {
    log_step "Enabling PostgreSQL to start on boot..."
    
    sudo systemctl enable postgresql
    
    log_info "PostgreSQL enabled on boot"
}

# -----------------------------------------------------------------------------
# Verify Installation
# -----------------------------------------------------------------------------
verify_installation() {
    log_step "Verifying PostgreSQL installation..."
    
    local errors=0
    
    # Check service status
    if systemctl is-active --quiet postgresql; then
        log_info "PostgreSQL service is running"
    else
        log_error "PostgreSQL service is not running"
        ((errors++))
    fi
    
    # Check database connectivity
    if PGPASSWORD="${ALFRESCO_DB_PASSWORD}" psql -h localhost -U "${ALFRESCO_DB_USER}" -d "${ALFRESCO_DB_NAME}" -c "SELECT 1" &>/dev/null; then
        log_info "Database connection successful"
    else
        log_error "Cannot connect to database"
        ((errors++))
    fi
    
    # Check encoding
    local db_encoding
    db_encoding=$(sudo -u postgres psql -tAc "SELECT pg_encoding_to_char(encoding) FROM pg_database WHERE datname='${ALFRESCO_DB_NAME}'")
    if [ "$db_encoding" = "UTF8" ]; then
        log_info "Database encoding is UTF8"
    else
        log_error "Database encoding is $db_encoding (expected UTF8)"
        ((errors++))
    fi
    
    if [ $errors -gt 0 ]; then
        log_error "Verification failed with $errors error(s)"
        exit 1
    fi
    
    log_info "All verifications passed"
}

# -----------------------------------------------------------------------------
# Run Main
# -----------------------------------------------------------------------------
main "$@"
