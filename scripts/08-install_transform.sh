#!/bin/bash
# =============================================================================
# Alfresco Transform Service Installation Script
# =============================================================================
# Installs and configures Alfresco Transform Core (All-In-One) for document
# transformations in Alfresco Content Services.
#
# Components installed:
# - Alfresco Transform Core AIO (JAR)
# - ImageMagick (image transformations)
# - LibreOffice (document transformations)
# - ExifTool (metadata extraction)
# - Alfresco PDF Renderer (PDF thumbnails)
#
# Prerequisites:
# - Run 00-generate-config.sh first to create configuration
# - Run 02-install_java.sh to install Java
# - Run 05-download_alfresco_resources.sh to download artifacts
# - Ubuntu 22.04 or 24.04
# - sudo privileges
#
# Usage:
#   bash scripts/08-install_transform.sh
# =============================================================================

# Load common functions and configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
DOWNLOAD_DIR="${SCRIPT_DIR}/../downloads"
NEXUS_BASE_URL="https://nexus.alfresco.com/nexus"

# -----------------------------------------------------------------------------
# Main Installation
# -----------------------------------------------------------------------------
main() {
    log_step "Starting Alfresco Transform Service installation..."
    
    # Pre-flight checks
    check_root
    check_sudo
    load_config
    check_prerequisites curl tar
    
    # Detect architecture
    detect_architecture
    
    # Verify prerequisites
    verify_prerequisites
    
    # Install system dependencies
    install_dependencies
    
    # Install PDF Renderer
    install_pdf_renderer
    
    # Install Transform Core
    install_transform_core
    
    # Create systemd service
    create_systemd_service
    
    # Set permissions
    set_permissions
    
    # Enable service
    enable_service
    
    # Verify installation
    verify_installation
    
    log_info "Alfresco Transform Service installation completed successfully!"
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
            PDF_RENDERER_ARCH="linux"
            ;;
        arm64)
            JAVA_ARCH="arm64"
            PDF_RENDERER_ARCH="linux"  # May need adjustment for ARM
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
    
    # Check transform JAR exists
    local transform_jar
    transform_jar=$(find "$DOWNLOAD_DIR" -name "alfresco-transform-core-aio-*.jar" 2>/dev/null | head -1)
    
    if [ -z "$transform_jar" ] || [ ! -f "$transform_jar" ]; then
        log_error "Transform Core JAR not found in $DOWNLOAD_DIR"
        log_error "Please run 05-download_alfresco_resources.sh first"
        ((errors++))
    else
        log_info "Found: $(basename "$transform_jar")"
    fi
    
    if [ $errors -gt 0 ]; then
        log_error "Prerequisites check failed"
        exit 1
    fi
    
    log_info "All prerequisites verified"
}

# -----------------------------------------------------------------------------
# Install System Dependencies
# -----------------------------------------------------------------------------
install_dependencies() {
    log_step "Installing Transform dependencies..."
    
    # Update package list
    log_info "Updating package list..."
    sudo apt-get update
    
    # ImageMagick for image transformations
    if command -v convert &> /dev/null; then
        log_info "ImageMagick is already installed"
    else
        log_info "Installing ImageMagick..."
        sudo apt-get install -y imagemagick
    fi
    
    # LibreOffice for document transformations
    if command -v soffice &> /dev/null; then
        log_info "LibreOffice is already installed"
    else
        log_info "Installing LibreOffice (this may take a while)..."
        sudo apt-get install -y libreoffice
    fi
    
    # ExifTool for metadata extraction
    if command -v exiftool &> /dev/null; then
        log_info "ExifTool is already installed"
    else
        log_info "Installing ExifTool..."
        sudo apt-get install -y libimage-exiftool-perl
    fi
    
    # Display installed versions
    log_info "Installed dependencies:"
    log_info "  ImageMagick: $(convert -version 2>/dev/null | head -1 | grep -oP 'ImageMagick \S+' || echo 'unknown')"
    log_info "  LibreOffice: $(soffice --version 2>/dev/null | head -1 || echo 'unknown')"
    log_info "  ExifTool: $(exiftool -ver 2>/dev/null || echo 'unknown')"
}

# -----------------------------------------------------------------------------
# Install Alfresco PDF Renderer
# -----------------------------------------------------------------------------
install_pdf_renderer() {
    log_step "Installing Alfresco PDF Renderer..."
    
    # Check if already installed
    if command -v alfresco-pdf-renderer &> /dev/null; then
        log_info "Alfresco PDF Renderer is already installed"
        log_info "  Version: $(alfresco-pdf-renderer --version 2>&1 | head -1 || echo 'unknown')"
        return 0
    fi
    
    # Determine version to use
    local pdf_renderer_version
    
    if [ "${USE_LATEST_VERSIONS:-false}" = "true" ]; then
        log_info "Fetching latest PDF Renderer version..."
        pdf_renderer_version=$(curl -s "${NEXUS_BASE_URL}/service/rest/repository/browse/releases/org/alfresco/alfresco-pdf-renderer/" \
            | sed -n 's/.*<a href="\(.*\)\/">.*/\1/p' \
            | grep -E '^[0-9]+(\.[0-9]+)*$' \
            | sort -V \
            | tail -n 1)
    fi
    
    # Fall back to pinned version
    pdf_renderer_version="${pdf_renderer_version:-$ALFRESCO_PDF_RENDERER_VERSION}"
    
    log_info "Using PDF Renderer version: $pdf_renderer_version"
    
    # Download
    local download_url="${NEXUS_BASE_URL}/repository/releases/org/alfresco/alfresco-pdf-renderer/${pdf_renderer_version}/alfresco-pdf-renderer-${pdf_renderer_version}-${PDF_RENDERER_ARCH}.tgz"
    local download_file="/tmp/alfresco-pdf-renderer-${pdf_renderer_version}-${PDF_RENDERER_ARCH}.tgz"
    
    log_info "Downloading from: $download_url"
    
    if ! curl -L -o "$download_file" "$download_url"; then
        log_error "Failed to download PDF Renderer"
        exit 1
    fi
    
    # Extract to /usr/bin
    log_info "Installing PDF Renderer to /usr/bin..."
    sudo tar xf "$download_file" -C /usr/bin
    
    # Verify installation
    if command -v alfresco-pdf-renderer &> /dev/null; then
        log_info "PDF Renderer installed successfully"
    else
        log_warn "PDF Renderer may not be in PATH"
    fi
    
    # Cleanup
    rm -f "$download_file"
}

# -----------------------------------------------------------------------------
# Install Transform Core
# -----------------------------------------------------------------------------
install_transform_core() {
    log_step "Installing Alfresco Transform Core..."
    
    local transform_home="${ALFRESCO_HOME}/transform"
    local transform_jar
    transform_jar=$(find "$DOWNLOAD_DIR" -name "alfresco-transform-core-aio-*.jar" | head -1)
    local jar_filename
    jar_filename=$(basename "$transform_jar")
    
    # Create transform directory
    mkdir -p "$transform_home"
    
    # Copy JAR if not already present
    if [ -f "$transform_home/$jar_filename" ]; then
        log_info "Transform Core JAR already installed: $jar_filename"
    else
        log_info "Copying $jar_filename..."
        cp "$transform_jar" "$transform_home/"
    fi
    
    # Create symlink for version-independent reference
    # This is the key fix - we use a symlink so the systemd service doesn't need updating
    local symlink_name="alfresco-transform-core-aio.jar"
    
    log_info "Creating symlink: $symlink_name -> $jar_filename"
    ln -sf "$jar_filename" "$transform_home/$symlink_name"
    
    log_info "Transform Core installed to: $transform_home"
}

# -----------------------------------------------------------------------------
# Create Systemd Service
# -----------------------------------------------------------------------------
create_systemd_service() {
    log_step "Creating Transform systemd service..."
    
    local service_file="/etc/systemd/system/transform.service"
    local transform_home="${ALFRESCO_HOME}/transform"
    local transform_jar="$transform_home/alfresco-transform-core-aio.jar"
    
    # Calculate memory allocation
    calculate_memory_allocation
    
    # Find LibreOffice home
    local libreoffice_home="/usr/lib/libreoffice"
    if [ ! -d "$libreoffice_home" ]; then
        libreoffice_home=$(dirname "$(which soffice 2>/dev/null)" 2>/dev/null | sed 's|/program$||')
    fi
    
    # Check if service already exists
    if [ -f "$service_file" ]; then
        log_info "Transform service file already exists, updating..."
        backup_file "$service_file"
    fi
    
    # Calculate min heap (50% of max)
    local transform_xms=$((MEM_TRANSFORM / 2))
    [ $transform_xms -lt 256 ] && transform_xms=256
    
    cat << EOF | sudo tee "$service_file" > /dev/null
[Unit]
Description=Alfresco Transform Core (All-In-One)
Documentation=https://docs.alfresco.com/transform-service/latest/
After=network.target activemq.service
Requires=activemq.service

[Service]
Type=simple
User=${ALFRESCO_USER}
Group=${ALFRESCO_GROUP}

# Java and application environment
Environment="JAVA_HOME=${JAVA_HOME_PATH}"
Environment="LIBREOFFICE_HOME=${libreoffice_home}"

# Transform service configuration
Environment="TRANSFORM_PORT=${TRANSFORM_PORT}"

# ExecStart uses the symlink, not the versioned JAR
# This allows upgrading the JAR without modifying the service file
# Memory settings - auto-calculated based on system RAM (${MEM_PROFILE} profile)
ExecStart=${JAVA_HOME_PATH}/bin/java \\
    -Xms${transform_xms}m -Xmx${MEM_TRANSFORM}m \\
    -XX:+UseG1GC \\
    -DLIBREOFFICE_HOME=${libreoffice_home} \\
    -Dpdfrenderer.exe=/usr/bin/alfresco-pdf-renderer \\
    -jar ${transform_jar} \\
    --server.port=${TRANSFORM_PORT}

ExecStop=/bin/kill -15 \$MAINPID

# Restart on failure
Restart=on-failure
RestartSec=10

# Security hardening
NoNewPrivileges=true
PrivateTmp=true

# Allow time for LibreOffice to initialize
TimeoutStartSec=120

[Install]
WantedBy=multi-user.target
EOF

    # Set permissions
    sudo chmod 644 "$service_file"
    
    # Reload systemd
    log_info "Reloading systemd daemon..."
    sudo systemctl daemon-reload
    
    log_info "Systemd service created with heap: ${transform_xms}m - ${MEM_TRANSFORM}m"
}

# -----------------------------------------------------------------------------
# Set Permissions
# -----------------------------------------------------------------------------
set_permissions() {
    log_step "Setting file permissions..."
    
    local transform_home="${ALFRESCO_HOME}/transform"
    
    # Set ownership
    sudo chown -R "${ALFRESCO_USER}:${ALFRESCO_GROUP}" "$transform_home"
    
    # Set permissions
    chmod 755 "$transform_home"
    chmod 644 "$transform_home"/*.jar
    
    log_info "Permissions configured"
}

# -----------------------------------------------------------------------------
# Enable Service
# -----------------------------------------------------------------------------
enable_service() {
    log_step "Enabling Transform service..."
    
    sudo systemctl enable transform
    
    log_info "Transform service enabled on boot"
}

# -----------------------------------------------------------------------------
# Verify Installation
# -----------------------------------------------------------------------------
verify_installation() {
    log_step "Verifying Transform installation..."
    
    local transform_home="${ALFRESCO_HOME}/transform"
    local errors=0
    
    # Check directory exists
    if [ -d "$transform_home" ]; then
        log_info "Transform directory exists: $transform_home"
    else
        log_error "Transform directory not found: $transform_home"
        ((errors++))
    fi
    
    # Check JAR exists (via symlink)
    if [ -f "$transform_home/alfresco-transform-core-aio.jar" ]; then
        log_info "Transform Core JAR exists (via symlink)"
        
        # Show what the symlink points to
        local real_jar
        real_jar=$(readlink -f "$transform_home/alfresco-transform-core-aio.jar")
        log_info "  -> $(basename "$real_jar")"
    else
        log_error "Transform Core JAR not found"
        ((errors++))
    fi
    
    # Check dependencies
    local deps=(
        "convert:ImageMagick"
        "soffice:LibreOffice"
        "exiftool:ExifTool"
        "alfresco-pdf-renderer:PDF Renderer"
    )
    
    for dep in "${deps[@]}"; do
        local cmd="${dep%%:*}"
        local name="${dep##*:}"
        
        if command -v "$cmd" &> /dev/null; then
            log_info "$name is available"
        else
            log_error "$name is not available"
            ((errors++))
        fi
    done
    
    # Check service file
    if [ -f "/etc/systemd/system/transform.service" ]; then
        log_info "Systemd service file exists"
    else
        log_error "Systemd service file missing"
        ((errors++))
    fi
    
    # Check service is enabled
    if systemctl is-enabled --quiet transform 2>/dev/null; then
        log_info "Transform service is enabled"
    else
        log_error "Transform service is not enabled"
        ((errors++))
    fi
    
    if [ $errors -gt 0 ]; then
        log_error "Verification failed with $errors error(s)"
        exit 1
    fi
    
    log_info ""
    log_info "Transform Service installation summary:"
    log_info "  Transform Home: $transform_home"
    log_info "  Service URL:    http://${TRANSFORM_HOST}:${TRANSFORM_PORT}"
    log_info "  Health Check:   http://${TRANSFORM_HOST}:${TRANSFORM_PORT}/actuator/health"
    log_info "  Logs URL:       http://${TRANSFORM_HOST}:${TRANSFORM_PORT}/log"
    log_info ""
    log_info "All verifications passed"
}

# -----------------------------------------------------------------------------
# Run Main
# -----------------------------------------------------------------------------
main "$@"
