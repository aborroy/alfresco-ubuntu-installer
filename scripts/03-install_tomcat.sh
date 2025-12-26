#!/bin/bash
# =============================================================================
# Apache Tomcat Installation Script
# =============================================================================
# Installs and configures Apache Tomcat for Alfresco Content Services.
#
# Prerequisites:
# - Run 00-generate-config.sh first to create configuration
# - Run 02-install_java.sh to install Java
# - Ubuntu 22.04 or 24.04
# - sudo privileges
#
# Usage:
#   bash scripts/03-install_tomcat.sh
# =============================================================================

# Load common functions and configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

# -----------------------------------------------------------------------------
# Main Installation
# -----------------------------------------------------------------------------
main() {
    log_step "Starting Apache Tomcat installation..."
    
    # Pre-flight checks
    check_root
    check_sudo
    load_config
    check_prerequisites curl wget tar
    
    # Detect architecture for JAVA_HOME
    detect_architecture
    
    # Determine version to use
    determine_version
    
    # Download and install Tomcat
    download_tomcat
    install_tomcat
    
    # Configure Tomcat
    configure_permissions
    create_systemd_service
    
    # Enable service
    enable_service
    
    # Verify installation
    verify_installation
    
    log_info "Apache Tomcat ${TOMCAT_VERSION_ACTUAL} installation completed successfully!"
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
# Determine Tomcat Version
# -----------------------------------------------------------------------------
determine_version() {
    log_step "Determining Tomcat version..."
    
    # Extract major version for download path (e.g., "10" from "10.1.28")
    TOMCAT_MAJOR_VERSION="${TOMCAT_VERSION%%.*}"
    
    if [ "${USE_LATEST_VERSIONS:-false}" = "true" ]; then
        log_info "Fetching latest Tomcat ${TOMCAT_MAJOR_VERSION}.x version..."
        TOMCAT_VERSION_ACTUAL=$(fetch_latest_tomcat_version)
        
        if [ -z "$TOMCAT_VERSION_ACTUAL" ]; then
            log_warn "Could not fetch latest version, falling back to pinned version"
            TOMCAT_VERSION_ACTUAL="$TOMCAT_VERSION"
        else
            log_warn "Using latest Tomcat version: $TOMCAT_VERSION_ACTUAL (pinned was: $TOMCAT_VERSION)"
        fi
    else
        TOMCAT_VERSION_ACTUAL="$TOMCAT_VERSION"
        log_info "Using pinned Tomcat version: $TOMCAT_VERSION_ACTUAL"
    fi
}

# -----------------------------------------------------------------------------
# Fetch Latest Tomcat Version
# -----------------------------------------------------------------------------
fetch_latest_tomcat_version() {
    curl -s "https://dlcdn.apache.org/tomcat/tomcat-${TOMCAT_MAJOR_VERSION}/" | \
        grep -oP "v[0-9]+\.[0-9]+\.[0-9]+" | \
        sort -V | \
        tail -1 | \
        sed 's/v//'
}

# -----------------------------------------------------------------------------
# Download Tomcat
# -----------------------------------------------------------------------------
download_tomcat() {
    log_step "Downloading Apache Tomcat ${TOMCAT_VERSION_ACTUAL}..."
    
    local download_url="https://dlcdn.apache.org/tomcat/tomcat-${TOMCAT_MAJOR_VERSION}/v${TOMCAT_VERSION_ACTUAL}/bin/apache-tomcat-${TOMCAT_VERSION_ACTUAL}.tar.gz"
    local download_file="/tmp/apache-tomcat-${TOMCAT_VERSION_ACTUAL}.tar.gz"
    
    # Check if already downloaded
    if [ -f "$download_file" ]; then
        log_info "Tomcat archive already downloaded: $download_file"
        return 0
    fi
    
    log_info "Downloading from: $download_url"
    
    if ! wget -q --show-progress "$download_url" -O "$download_file"; then
        log_warn "Failed to download pinned version ${TOMCAT_VERSION_ACTUAL}"
        log_info "Attempting to fetch latest available version..."
        
        # Fetch latest version as fallback
        local latest_version
        latest_version=$(fetch_latest_tomcat_version)
        
        if [ -n "$latest_version" ] && [ "$latest_version" != "$TOMCAT_VERSION_ACTUAL" ]; then
            log_info "Found latest version: $latest_version"
            TOMCAT_VERSION_ACTUAL="$latest_version"
            download_url="https://dlcdn.apache.org/tomcat/tomcat-${TOMCAT_MAJOR_VERSION}/v${TOMCAT_VERSION_ACTUAL}/bin/apache-tomcat-${TOMCAT_VERSION_ACTUAL}.tar.gz"
            download_file="/tmp/apache-tomcat-${TOMCAT_VERSION_ACTUAL}.tar.gz"
            
            log_info "Downloading from: $download_url"
            if ! wget -q --show-progress "$download_url" -O "$download_file"; then
                log_error "Failed to download Tomcat"
                log_error "URL: $download_url"
                exit 1
            fi
        else
            log_error "Failed to download Tomcat and no alternative version found"
            log_error "URL: $download_url"
            exit 1
        fi
    fi
    
    log_info "Download completed: $download_file"
}

# -----------------------------------------------------------------------------
# Install Tomcat
# -----------------------------------------------------------------------------
install_tomcat() {
    log_step "Installing Apache Tomcat..."
    
    local tomcat_home="${ALFRESCO_HOME}/tomcat"
    local download_file="/tmp/apache-tomcat-${TOMCAT_VERSION_ACTUAL}.tar.gz"
    
    # Check if already installed
    if [ -d "$tomcat_home" ] && [ -f "$tomcat_home/bin/catalina.sh" ]; then
        # Check installed version
        local installed_version
        installed_version=$("$tomcat_home/bin/catalina.sh" version 2>/dev/null | grep "Server version" | grep -oP '\d+\.\d+\.\d+' || echo "unknown")
        
        if [ "$installed_version" = "$TOMCAT_VERSION_ACTUAL" ]; then
            log_info "Tomcat ${TOMCAT_VERSION_ACTUAL} is already installed at $tomcat_home"
            return 0
        else
            log_warn "Different Tomcat version installed: $installed_version"
            log_warn "Backing up existing installation..."
            backup_file "$tomcat_home"
            sudo mv "$tomcat_home" "${tomcat_home}.bak.$(date +%Y%m%d_%H%M%S)"
        fi
    fi
    
    # Create directory and extract
    log_info "Extracting Tomcat to $tomcat_home..."
    sudo mkdir -p "$tomcat_home"
    sudo tar xzf "$download_file" -C "$tomcat_home" --strip-components=1
    
    log_info "Tomcat extracted successfully"
}

# -----------------------------------------------------------------------------
# Configure Permissions
# -----------------------------------------------------------------------------
configure_permissions() {
    log_step "Configuring Tomcat permissions..."
    
    local tomcat_home="${ALFRESCO_HOME}/tomcat"
    
    # Set ownership
    sudo chown -R "${ALFRESCO_USER}:${ALFRESCO_GROUP}" "$tomcat_home"
    
    # Set execute permissions on scripts
    sudo chmod -R u+x "$tomcat_home/bin"
    
    # Secure conf directory
    sudo chmod 700 "$tomcat_home/conf"
    
    log_info "Permissions configured"
}

# -----------------------------------------------------------------------------
# Create Systemd Service
# -----------------------------------------------------------------------------
create_systemd_service() {
    log_step "Creating Tomcat systemd service..."
    
    local service_file="/etc/systemd/system/tomcat.service"
    local tomcat_home="${ALFRESCO_HOME}/tomcat"
    local keystore_location="${ALFRESCO_HOME}/keystore/metadata-keystore/keystore"
    
    # Calculate memory allocation
    calculate_memory_allocation
    show_memory_allocation
    
    # Check if service already exists and is identical
    if [ -f "$service_file" ]; then
        log_info "Tomcat service file already exists, updating..."
        backup_file "$service_file"
    fi
    
    cat << EOF | sudo tee "$service_file" > /dev/null
[Unit]
Description=Apache Tomcat Web Application Container
Documentation=https://tomcat.apache.org/tomcat-${TOMCAT_MAJOR_VERSION}.0-doc/index.html
After=network.target transform.service
Requires=transform.service

[Service]
Type=forking

User=${ALFRESCO_USER}
Group=${ALFRESCO_GROUP}

Environment="JAVA_HOME=${JAVA_HOME_PATH}"
Environment="CATALINA_PID=${tomcat_home}/temp/tomcat.pid"
Environment="CATALINA_HOME=${tomcat_home}"
Environment="CATALINA_BASE=${tomcat_home}"

# Memory settings - auto-calculated based on system RAM (${MEM_PROFILE} profile)
Environment="CATALINA_OPTS=-Xms${MEM_TOMCAT_XMS}m -Xmx${MEM_TOMCAT_XMX}m -server -XX:+UseG1GC -XX:+UseStringDeduplication -XX:+ParallelRefProcEnabled -XX:MaxGCPauseMillis=200"

Environment="JAVA_OPTS=-Djava.awt.headless=true -Djava.security.egd=file:/dev/./urandom -Dfile.encoding=UTF-8"
Environment="JAVA_TOOL_OPTIONS=-Dencryption.keystore.type=JCEKS -Dencryption.cipherAlgorithm=DESede/CBC/PKCS5Padding -Dencryption.keyAlgorithm=DESede -Dencryption.keystore.location=${keystore_location} -Dmetadata-keystore.password=${KEYSTORE_PASSWORD} -Dmetadata-keystore.aliases=metadata -Dmetadata-keystore.metadata.password=${KEYSTORE_METADATA_PASSWORD} -Dmetadata-keystore.metadata.algorithm=DESede"

ExecStart=${tomcat_home}/bin/startup.sh
ExecStop=${tomcat_home}/bin/shutdown.sh

# Restart on failure
Restart=on-failure
RestartSec=10

# Security hardening
NoNewPrivileges=true
PrivateTmp=true

# File descriptor limits
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

    # Secure the service file (contains passwords)
    sudo chmod 644 "$service_file"
    
    # Reload systemd
    log_info "Reloading systemd daemon..."
    sudo systemctl daemon-reload
    
    log_info "Systemd service created with heap: ${MEM_TOMCAT_XMS}m - ${MEM_TOMCAT_XMX}m"
}

# -----------------------------------------------------------------------------
# Enable Service
# -----------------------------------------------------------------------------
enable_service() {
    log_step "Enabling Tomcat service..."
    
    sudo systemctl enable tomcat
    
    log_info "Tomcat service enabled on boot"
}

# -----------------------------------------------------------------------------
# Verify Installation
# -----------------------------------------------------------------------------
verify_installation() {
    log_step "Verifying Tomcat installation..."
    
    local tomcat_home="${ALFRESCO_HOME}/tomcat"
    local errors=0
    
    # Check directory exists
    if [ -d "$tomcat_home" ]; then
        log_info "Tomcat directory exists: $tomcat_home"
    else
        log_error "Tomcat directory not found: $tomcat_home"
        ((errors++))
    fi
    
    # Check key files exist
    local key_files=(
        "bin/catalina.sh"
        "bin/startup.sh"
        "bin/shutdown.sh"
        "conf/server.xml"
        "conf/catalina.properties"
    )
    
    for file in "${key_files[@]}"; do
        if [ -f "$tomcat_home/$file" ]; then
            log_info "Found: $file"
        else
            log_error "Missing: $file"
            ((errors++))
        fi
    done
    
    # Check service file
    if [ -f "/etc/systemd/system/tomcat.service" ]; then
        log_info "Systemd service file exists"
    else
        log_error "Systemd service file missing"
        ((errors++))
    fi
    
    # Check service is enabled
    if systemctl is-enabled --quiet tomcat 2>/dev/null; then
        log_info "Tomcat service is enabled"
    else
        log_error "Tomcat service is not enabled"
        ((errors++))
    fi
    
    # Display version
    log_info "Tomcat version:"
    "$tomcat_home/bin/catalina.sh" version 2>/dev/null | grep -E "(Server version|Server built|JVM Version)" | while read -r line; do
        log_info "  $line"
    done
    
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