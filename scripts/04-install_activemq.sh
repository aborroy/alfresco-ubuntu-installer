#!/bin/bash
# =============================================================================
# Apache ActiveMQ Installation Script
# =============================================================================
# Installs and configures Apache ActiveMQ for Alfresco Content Services.
#
# Prerequisites:
# - Run 00-generate-config.sh first to create configuration
# - Run 02-install_java.sh to install Java
# - Ubuntu 22.04 or 24.04
# - sudo privileges
#
# Usage:
#   bash scripts/04-install_activemq.sh
# =============================================================================

# Load common functions and configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# -----------------------------------------------------------------------------
# Main Installation
# -----------------------------------------------------------------------------
main() {
    log_step "Starting Apache ActiveMQ installation..."
    
    # Pre-flight checks
    check_root
    check_sudo
    load_config
    check_prerequisites curl wget tar
    
    # Detect architecture for JAVA_HOME
    detect_architecture
    
    # Determine version to use
    determine_version
    
    # Download and install ActiveMQ
    download_activemq
    install_activemq
    
    # Configure ActiveMQ
    configure_permissions
    configure_credentials
    create_systemd_service
    
    # Enable service
    enable_service
    
    # Verify installation
    verify_installation
    
    log_info "Apache ActiveMQ ${ACTIVEMQ_VERSION_ACTUAL} installation completed successfully!"
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
# Determine ActiveMQ Version
# -----------------------------------------------------------------------------
determine_version() {
    log_step "Determining ActiveMQ version..."
    
    # Extract major version (e.g., "6" from "6.1.2")
    ACTIVEMQ_MAJOR_VERSION="${ACTIVEMQ_VERSION%%.*}"
    
    if [ "${USE_LATEST_VERSIONS:-false}" = "true" ]; then
        log_info "Fetching latest ActiveMQ version..."
        
        # Fetch latest version matching major version
        ACTIVEMQ_VERSION_ACTUAL=$(curl -s "https://dlcdn.apache.org/activemq/" | \
            grep -oP "${ACTIVEMQ_MAJOR_VERSION}\.[0-9]+\.[0-9]+" | \
            sort -V | \
            tail -1)
        
        if [ -z "$ACTIVEMQ_VERSION_ACTUAL" ]; then
            log_warn "Could not fetch latest version, falling back to pinned version"
            ACTIVEMQ_VERSION_ACTUAL="$ACTIVEMQ_VERSION"
        else
            log_warn "Using latest ActiveMQ version: $ACTIVEMQ_VERSION_ACTUAL (pinned was: $ACTIVEMQ_VERSION)"
        fi
    else
        ACTIVEMQ_VERSION_ACTUAL="$ACTIVEMQ_VERSION"
        log_info "Using pinned ActiveMQ version: $ACTIVEMQ_VERSION_ACTUAL"
    fi
}

# -----------------------------------------------------------------------------
# Download ActiveMQ
# -----------------------------------------------------------------------------
download_activemq() {
    log_step "Downloading Apache ActiveMQ ${ACTIVEMQ_VERSION_ACTUAL}..."
    
    local download_url="https://dlcdn.apache.org/activemq/${ACTIVEMQ_VERSION_ACTUAL}/apache-activemq-${ACTIVEMQ_VERSION_ACTUAL}-bin.tar.gz"
    local download_file="/tmp/apache-activemq-${ACTIVEMQ_VERSION_ACTUAL}-bin.tar.gz"
    
    # Check if already downloaded
    if [ -f "$download_file" ]; then
        log_info "ActiveMQ archive already downloaded: $download_file"
        return 0
    fi
    
    log_info "Downloading from: $download_url"
    
    if ! wget -q --show-progress "$download_url" -O "$download_file"; then
        log_error "Failed to download ActiveMQ"
        log_error "URL: $download_url"
        exit 1
    fi
    
    log_info "Download completed: $download_file"
}

# -----------------------------------------------------------------------------
# Install ActiveMQ
# -----------------------------------------------------------------------------
install_activemq() {
    log_step "Installing Apache ActiveMQ..."
    
    local activemq_home="${ALFRESCO_HOME}/activemq"
    local download_file="/tmp/apache-activemq-${ACTIVEMQ_VERSION_ACTUAL}-bin.tar.gz"
    
    # Check if already installed
    if [ -d "$activemq_home" ] && [ -f "$activemq_home/bin/activemq" ]; then
        # Check installed version
        local installed_version
        installed_version=$("$activemq_home/bin/activemq" --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1 || echo "unknown")
        
        if [ "$installed_version" = "$ACTIVEMQ_VERSION_ACTUAL" ]; then
            log_info "ActiveMQ ${ACTIVEMQ_VERSION_ACTUAL} is already installed at $activemq_home"
            return 0
        else
            log_warn "Different ActiveMQ version installed: $installed_version"
            log_warn "Backing up existing installation..."
            sudo mv "$activemq_home" "${activemq_home}.bak.$(date +%Y%m%d_%H%M%S)"
        fi
    fi
    
    # Create directory and extract
    log_info "Extracting ActiveMQ to $activemq_home..."
    sudo mkdir -p "$activemq_home"
    sudo tar xzf "$download_file" -C "$activemq_home" --strip-components=1
    
    log_info "ActiveMQ extracted successfully"
}

# -----------------------------------------------------------------------------
# Configure Permissions
# -----------------------------------------------------------------------------
configure_permissions() {
    log_step "Configuring ActiveMQ permissions..."
    
    local activemq_home="${ALFRESCO_HOME}/activemq"
    
    # Set ownership
    sudo chown -R "${ALFRESCO_USER}:${ALFRESCO_GROUP}" "$activemq_home"
    
    # Set permissions
    sudo chmod -R 755 "$activemq_home"
    
    # Secure conf directory
    sudo chmod 700 "$activemq_home/conf"
    
    log_info "Permissions configured"
}

# -----------------------------------------------------------------------------
# Configure Admin Credentials
# -----------------------------------------------------------------------------
configure_credentials() {
    log_step "Configuring ActiveMQ credentials..."
    
    local activemq_home="${ALFRESCO_HOME}/activemq"
    local users_file="$activemq_home/conf/users.properties"
    local groups_file="$activemq_home/conf/groups.properties"
    local jetty_users_file="$activemq_home/conf/jetty-realm.properties"
    
    # Backup original files
    backup_file "$users_file"
    backup_file "$groups_file"
    backup_file "$jetty_users_file"
    
    # Configure users.properties (for broker authentication)
    log_info "Configuring broker users..."
    cat << EOF | sudo tee "$users_file" > /dev/null
# ActiveMQ Users Configuration
# Generated by Alfresco installer on $(date)
# Format: username=password

${ACTIVEMQ_ADMIN_USER}=${ACTIVEMQ_ADMIN_PASSWORD}
EOF
    
    # Configure groups.properties
    log_info "Configuring broker groups..."
    cat << EOF | sudo tee "$groups_file" > /dev/null
# ActiveMQ Groups Configuration
# Generated by Alfresco installer on $(date)
# Format: groupname=user1,user2,...

admins=${ACTIVEMQ_ADMIN_USER}
EOF
    
    # Configure jetty-realm.properties (for web console authentication)
    log_info "Configuring web console users..."
    cat << EOF | sudo tee "$jetty_users_file" > /dev/null
# Jetty Realm Configuration for ActiveMQ Web Console
# Generated by Alfresco installer on $(date)
# Format: username: password, role

${ACTIVEMQ_ADMIN_USER}: ${ACTIVEMQ_ADMIN_PASSWORD}, admin
EOF
    
    # Secure credential files
    sudo chmod 600 "$users_file" "$groups_file" "$jetty_users_file"
    sudo chown "${ALFRESCO_USER}:${ALFRESCO_GROUP}" "$users_file" "$groups_file" "$jetty_users_file"
    
    log_info "Credentials configured"
}

# -----------------------------------------------------------------------------
# Create Systemd Service
# -----------------------------------------------------------------------------
create_systemd_service() {
    log_step "Creating ActiveMQ systemd service..."
    
    local service_file="/etc/systemd/system/activemq.service"
    local activemq_home="${ALFRESCO_HOME}/activemq"
    
    # Calculate memory allocation
    calculate_memory_allocation
    
    # Check if service already exists
    if [ -f "$service_file" ]; then
        log_info "ActiveMQ service file already exists, updating..."
        backup_file "$service_file"
    fi
    
    cat << EOF | sudo tee "$service_file" > /dev/null
[Unit]
Description=Apache ActiveMQ Message Broker
Documentation=https://activemq.apache.org/
After=network.target postgresql.service
Requires=postgresql.service

[Service]
Type=forking

User=${ALFRESCO_USER}
Group=${ALFRESCO_GROUP}

Environment="JAVA_HOME=${JAVA_HOME_PATH}"
Environment="ACTIVEMQ_HOME=${activemq_home}"
Environment="ACTIVEMQ_BASE=${activemq_home}"
Environment="ACTIVEMQ_CONF=${activemq_home}/conf"
Environment="ACTIVEMQ_DATA=${activemq_home}/data"

# Memory settings - auto-calculated based on system RAM (${MEM_PROFILE} profile)
Environment="ACTIVEMQ_OPTS=-Xms${MEM_ACTIVEMQ}m -Xmx${MEM_ACTIVEMQ}m -Djava.util.logging.config.file=logging.properties -Djava.security.auth.login.config=${activemq_home}/conf/login.config"

ExecStart=${activemq_home}/bin/activemq start
ExecStop=${activemq_home}/bin/activemq stop

# Restart on failure
Restart=on-failure
RestartSec=10

# Security hardening
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

    # Set permissions
    sudo chmod 644 "$service_file"
    
    # Reload systemd
    log_info "Reloading systemd daemon..."
    sudo systemctl daemon-reload
    
    log_info "Systemd service created with heap: ${MEM_ACTIVEMQ}m"
}

# -----------------------------------------------------------------------------
# Enable Service
# -----------------------------------------------------------------------------
enable_service() {
    log_step "Enabling ActiveMQ service..."
    
    sudo systemctl enable activemq
    
    log_info "ActiveMQ service enabled on boot"
}

# -----------------------------------------------------------------------------
# Verify Installation
# -----------------------------------------------------------------------------
verify_installation() {
    log_step "Verifying ActiveMQ installation..."
    
    local activemq_home="${ALFRESCO_HOME}/activemq"
    local errors=0
    
    # Check directory exists
    if [ -d "$activemq_home" ]; then
        log_info "ActiveMQ directory exists: $activemq_home"
    else
        log_error "ActiveMQ directory not found: $activemq_home"
        ((errors++))
    fi
    
    # Check key files exist
    local key_files=(
        "bin/activemq"
        "conf/activemq.xml"
        "conf/users.properties"
        "conf/groups.properties"
        "conf/jetty-realm.properties"
    )
    
    for file in "${key_files[@]}"; do
        if [ -f "$activemq_home/$file" ]; then
            log_info "Found: $file"
        else
            log_error "Missing: $file"
            ((errors++))
        fi
    done
    
    # Check service file
    if [ -f "/etc/systemd/system/activemq.service" ]; then
        log_info "Systemd service file exists"
    else
        log_error "Systemd service file missing"
        ((errors++))
    fi
    
    # Check service is enabled
    if systemctl is-enabled --quiet activemq 2>/dev/null; then
        log_info "ActiveMQ service is enabled"
    else
        log_error "ActiveMQ service is not enabled"
        ((errors++))
    fi
    
    # Check credential file permissions
    local cred_files=("conf/users.properties" "conf/groups.properties" "conf/jetty-realm.properties")
    for file in "${cred_files[@]}"; do
        local perms
        perms=$(stat -c "%a" "$activemq_home/$file" 2>/dev/null)
        if [ "$perms" = "600" ]; then
            log_info "Secure permissions on $file"
        else
            log_warn "Permissions on $file are $perms (should be 600)"
        fi
    done
    
    # Display version
    log_info "ActiveMQ version:"
    "$activemq_home/bin/activemq" --version 2>/dev/null | head -3 | while read -r line; do
        log_info "  $line"
    done
    
    # Display connection info
    log_info ""
    log_info "ActiveMQ connection details:"
    log_info "  OpenWire: tcp://${ACTIVEMQ_HOST}:${ACTIVEMQ_PORT}"
    log_info "  Web Console: http://${ACTIVEMQ_HOST}:${ACTIVEMQ_WEBCONSOLE_PORT}"
    log_info "  Admin User: ${ACTIVEMQ_ADMIN_USER}"
    
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
