#!/bin/bash
# =============================================================================
# Alfresco Search Services (Solr) Installation Script
# =============================================================================
# Installs and configures Alfresco Search Services for Alfresco Content Services.
#
# Prerequisites:
# - Run 00-generate-config.sh first to create configuration
# - Run 02-install_java.sh to install Java
# - Run 05-download_alfresco_resources.sh to download artifacts
# - Ubuntu 22.04 or 24.04
# - sudo privileges
#
# Usage:
#   bash scripts/07-install_solr.sh
# =============================================================================

# Load common functions and configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
DOWNLOAD_DIR="${SCRIPT_DIR}/../downloads"

# -----------------------------------------------------------------------------
# Main Installation
# -----------------------------------------------------------------------------
main() {
    log_step "Starting Alfresco Search Services installation..."
    
    # Pre-flight checks
    check_root
    check_sudo
    load_config
    check_prerequisites unzip
    
    # Detect architecture for JAVA_HOME
    detect_architecture
    
    # Verify prerequisites
    verify_prerequisites
    
    # Install Solr
    extract_search_services
    
    # Configure Solr
    configure_solr_properties
    create_systemd_service
    
    # Set permissions
    set_permissions
    
    # Enable service
    enable_service
    
    # Verify installation
    verify_installation
    
    log_info "Alfresco Search Services installation completed successfully!"
}

# -----------------------------------------------------------------------------
# Detect System Architecture
# -----------------------------------------------------------------------------
detect_architecture() {
    log_step "Detecting system architecture..."
    
    ARCH=$(dpkg --print-architecture)
    
    case "$ARCH" in
        amd64)
            JAVA_ARCH="amd64"
            ;;
        arm64)
            JAVA_ARCH="arm64"
            ;;
        *)
            log_error "Unsupported architecture: $ARCH"
            exit 1
            ;;
    esac
    
    JAVA_HOME_PATH="/usr/lib/jvm/java-${JAVA_VERSION}-openjdk-${JAVA_ARCH}"
    
    if [ ! -d "$JAVA_HOME_PATH" ]; then
        log_error "JAVA_HOME not found: $JAVA_HOME_PATH"
        log_error "Please run 02-install_java.sh first"
        exit 1
    fi
    
    log_info "Using JAVA_HOME: $JAVA_HOME_PATH"
}

# -----------------------------------------------------------------------------
# Verify Prerequisites
# -----------------------------------------------------------------------------
verify_prerequisites() {
    log_step "Verifying prerequisites..."
    
    local errors=0
    
    # Check downloads exist
    local search_file
    search_file=$(find "$DOWNLOAD_DIR" -name "alfresco-search-services-*.zip" 2>/dev/null | head -1)
    
    if [ -z "$search_file" ] || [ ! -f "$search_file" ]; then
        log_error "Alfresco Search Services not found in $DOWNLOAD_DIR"
        log_error "Please run 05-download_alfresco_resources.sh first"
        ((errors++))
    else
        log_info "Found: $(basename "$search_file")"
    fi
    
    if [ $errors -gt 0 ]; then
        log_error "Prerequisites check failed"
        exit 1
    fi
    
    log_info "All prerequisites verified"
}

# -----------------------------------------------------------------------------
# Extract Search Services
# -----------------------------------------------------------------------------
extract_search_services() {
    log_step "Extracting Alfresco Search Services..."
    
    local solr_home="${ALFRESCO_HOME}/alfresco-search-services"
    local search_file
    search_file=$(find "$DOWNLOAD_DIR" -name "alfresco-search-services-*.zip" | head -1)
    
    # Check if already installed
    if [ -d "$solr_home" ] && [ -f "$solr_home/solr/bin/solr" ]; then
        log_info "Alfresco Search Services already installed at $solr_home"
        return 0
    fi
    
    # Extract to temp location first
    local temp_dir="/tmp/solr-install"
    rm -rf "$temp_dir"
    mkdir -p "$temp_dir"
    
    log_info "Extracting $(basename "$search_file")..."
    unzip -q "$search_file" -d "$temp_dir"
    
    # Move to final location
    if [ -d "$temp_dir/alfresco-search-services" ]; then
        mv "$temp_dir/alfresco-search-services" "$solr_home"
    else
        # Files might be directly in temp_dir
        mkdir -p "$solr_home"
        mv "$temp_dir"/* "$solr_home/"
    fi
    
    # Cleanup
    rm -rf "$temp_dir"
    
    log_info "Extracted to: $solr_home"
}

# -----------------------------------------------------------------------------
# Configure Solr Properties
# -----------------------------------------------------------------------------
configure_solr_properties() {
    log_step "Configuring Solr properties..."
    
    local solr_home="${ALFRESCO_HOME}/alfresco-search-services"
    local solrhome_dir="$solr_home/solrhome"
    
    # Configure shared.properties for secret-based communication
    local shared_props="$solrhome_dir/conf/shared.properties"
    
    if [ -f "$shared_props" ]; then
        backup_file "$shared_props"
        
        log_info "Updating shared.properties..."
        
        # Update Alfresco host and port
        sed -i "s|^solr.host=.*|solr.host=${SOLR_HOST}|" "$shared_props"
        sed -i "s|^solr.port=.*|solr.port=${SOLR_PORT}|" "$shared_props"
        
        # Update Alfresco connection settings
        sed -i "s|^alfresco.host=.*|alfresco.host=${ALFRESCO_HOST}|" "$shared_props"
        sed -i "s|^alfresco.port=.*|alfresco.port=${ALFRESCO_PORT}|" "$shared_props"
        
        # Configure secure communication
        sed -i "s|^alfresco.secureComms=.*|alfresco.secureComms=secret|" "$shared_props"
        
        # Add or update shared secret
        if grep -q "^alfresco.secureComms.secret=" "$shared_props"; then
            sed -i "s|^alfresco.secureComms.secret=.*|alfresco.secureComms.secret=${SOLR_SHARED_SECRET}|" "$shared_props"
        else
            echo "alfresco.secureComms.secret=${SOLR_SHARED_SECRET}" >> "$shared_props"
        fi
    else
        log_warn "shared.properties not found, creating..."
        mkdir -p "$(dirname "$shared_props")"
        
        cat << EOF > "$shared_props"
# Alfresco Search Services Configuration
# Generated by Alfresco installer on $(date)

# Solr host and port
solr.host=${SOLR_HOST}
solr.port=${SOLR_PORT}

# Alfresco Repository connection
alfresco.host=${ALFRESCO_HOST}
alfresco.port=${ALFRESCO_PORT}

# Secure communication using shared secret
alfresco.secureComms=secret
alfresco.secureComms.secret=${SOLR_SHARED_SECRET}
EOF
    fi
    
    # Secure the properties file
    chmod 600 "$shared_props"
    
    log_info "Solr properties configured"
}

# -----------------------------------------------------------------------------
# Create Systemd Service
# -----------------------------------------------------------------------------
create_systemd_service() {
    log_step "Creating Solr systemd service..."
    
    local service_file="/etc/systemd/system/solr.service"
    local solr_home="${ALFRESCO_HOME}/alfresco-search-services"
    
    # Check if service already exists
    if [ -f "$service_file" ]; then
        log_info "Solr service file already exists, updating..."
        backup_file "$service_file"
    fi
    
    # Calculate Solr memory (use ~25% of system memory, min 1GB, max 4GB)
    local total_mem_kb
    total_mem_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    local solr_mem_mb=$((total_mem_kb / 1024 / 4))
    
    # Enforce min/max limits
    [ $solr_mem_mb -lt 1024 ] && solr_mem_mb=1024
    [ $solr_mem_mb -gt 4096 ] && solr_mem_mb=4096
    
    log_info "Configuring Solr with ${solr_mem_mb}MB heap"
    
    cat << EOF | sudo tee "$service_file" > /dev/null
[Unit]
Description=Alfresco Search Services (Solr)
Documentation=https://docs.alfresco.com/search-services/latest/
After=network.target tomcat.service
Requires=tomcat.service

[Service]
Type=forking
User=${ALFRESCO_USER}
Group=${ALFRESCO_GROUP}

Environment="JAVA_HOME=${JAVA_HOME_PATH}"
Environment="SOLR_HOME=${solr_home}/solrhome"
Environment="SOLR_JAVA_MEM=-Xms${solr_mem_mb}m -Xmx${solr_mem_mb}m"

# Solr startup arguments
# -Dcreate.alfresco.defaults: Creates default alfresco and archive cores on first start
# -Dalfresco.secureComms: Communication method with Alfresco (none, https, secret)
# -Dalfresco.secureComms.secret: Shared secret for authentication
ExecStart=${solr_home}/solr/bin/solr start -a "\
-Dcreate.alfresco.defaults=alfresco,archive \
-Dalfresco.secureComms=secret \
-Dalfresco.secureComms.secret=${SOLR_SHARED_SECRET}"

ExecStop=${solr_home}/solr/bin/solr stop

# Restart on failure
Restart=on-failure
RestartSec=10

# Security hardening
NoNewPrivileges=true
PrivateTmp=true

# Increase file descriptor limit for Solr
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

    # Set permissions
    sudo chmod 644 "$service_file"
    
    # Reload systemd
    log_info "Reloading systemd daemon..."
    sudo systemctl daemon-reload
    
    log_info "Systemd service created"
}

# -----------------------------------------------------------------------------
# Set Permissions
# -----------------------------------------------------------------------------
set_permissions() {
    log_step "Setting file permissions..."
    
    local solr_home="${ALFRESCO_HOME}/alfresco-search-services"
    
    # Set ownership
    sudo chown -R "${ALFRESCO_USER}:${ALFRESCO_GROUP}" "$solr_home"
    
    # Make solr script executable
    chmod +x "$solr_home/solr/bin/solr"
    chmod +x "$solr_home/solr/bin/solr.in.sh" 2>/dev/null || true
    
    # Secure configuration files
    chmod 700 "$solr_home/solrhome/conf" 2>/dev/null || true
    chmod 600 "$solr_home/solrhome/conf/shared.properties" 2>/dev/null || true
    
    log_info "Permissions configured"
}

# -----------------------------------------------------------------------------
# Enable Service
# -----------------------------------------------------------------------------
enable_service() {
    log_step "Enabling Solr service..."
    
    sudo systemctl enable solr
    
    log_info "Solr service enabled on boot"
}

# -----------------------------------------------------------------------------
# Verify Installation
# -----------------------------------------------------------------------------
verify_installation() {
    log_step "Verifying Solr installation..."
    
    local solr_home="${ALFRESCO_HOME}/alfresco-search-services"
    local errors=0
    
    # Check directory exists
    if [ -d "$solr_home" ]; then
        log_info "Solr directory exists: $solr_home"
    else
        log_error "Solr directory not found: $solr_home"
        ((errors++))
    fi
    
    # Check key files exist
    local key_files=(
        "solr/bin/solr"
        "solrhome/conf/shared.properties"
        "solrhome/templates/rerank/conf/solrcore.properties"
    )
    
    for file in "${key_files[@]}"; do
        if [ -f "$solr_home/$file" ]; then
            log_info "Found: $file"
        else
            log_error "Missing: $file"
            ((errors++))
        fi
    done
    
    # Check service file
    if [ -f "/etc/systemd/system/solr.service" ]; then
        log_info "Systemd service file exists"
    else
        log_error "Systemd service file missing"
        ((errors++))
    fi
    
    # Check service is enabled
    if systemctl is-enabled --quiet solr 2>/dev/null; then
        log_info "Solr service is enabled"
    else
        log_error "Solr service is not enabled"
        ((errors++))
    fi
    
    # Check secret is configured (without revealing it)
    local shared_props="$solr_home/solrhome/conf/shared.properties"
    if [ -f "$shared_props" ] && grep -q "alfresco.secureComms.secret=" "$shared_props"; then
        log_info "Shared secret is configured"
    else
        log_warn "Shared secret may not be configured"
    fi
    
    if [ $errors -gt 0 ]; then
        log_error "Verification failed with $errors error(s)"
        exit 1
    fi
    
    log_info ""
    log_info "Solr installation summary:"
    log_info "  Solr Home:     $solr_home"
    log_info "  Solr URL:      http://${SOLR_HOST}:${SOLR_PORT}/solr"
    log_info "  Admin Console: http://${SOLR_HOST}:${SOLR_PORT}/solr/#/"
    log_info "  Cores:         alfresco, archive (created on first start)"
    log_info ""
    log_info "To test Solr connectivity (after starting):"
    log_info "  curl -H \"X-Alfresco-Search-Secret: \${SOLR_SHARED_SECRET}\" http://${SOLR_HOST}:${SOLR_PORT}/solr/alfresco/admin/ping"
    log_info ""
    log_info "All verifications passed"
}

# -----------------------------------------------------------------------------
# Run Main
# -----------------------------------------------------------------------------
main "$@"