#!/bin/bash
# =============================================================================
# Alfresco Content Services Installation Script
# =============================================================================
# Installs and configures Alfresco Content Services Community Edition.
#
# Prerequisites:
# - Run 00-generate-config.sh first to create configuration
# - Run 01-install_postgres.sh to install PostgreSQL
# - Run 02-install_java.sh to install Java
# - Run 03-install_tomcat.sh to install Tomcat
# - Run 05-download_alfresco_resources.sh to download artifacts
# - Ubuntu 22.04 or 24.04
# - sudo privileges
#
# Usage:
#   bash scripts/06-install_alfresco.sh
# =============================================================================

# Load common functions and configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
DOWNLOAD_DIR="${SCRIPT_DIR}/../downloads"

# IMPORTANT:
# Use a per-run, user-owned temp directory (mktemp) to avoid root ownership
# issues in CI and on developer machines.
TEMP_DIR=""
ALFRESCO_DIST_DIR=""

# -----------------------------------------------------------------------------
# Main Installation
# -----------------------------------------------------------------------------
main() {
    log_step "Starting Alfresco Content Services installation..."

    # Pre-flight checks
    check_root
    check_sudo
    load_config
    check_prerequisites unzip java

    # Verify prerequisites
    verify_prerequisites

    # Install dependencies
    install_dependencies

    # Configure Tomcat for Alfresco
    configure_tomcat_shared

    # Extract Alfresco distribution
    extract_alfresco_distribution

    # Install components
    install_jdbc_driver
    install_web_applications
    install_keystore
    create_data_directory

    # Configure Alfresco
    create_alfresco_global_properties
    configure_addon_directories
    apply_amps

    # Extract and configure WARs
    extract_war_files
    configure_logging

    # Set permissions
    set_permissions

    # Cleanup
    cleanup

    # Verify installation
    verify_installation

    log_info "Alfresco Content Services installation completed successfully!"
}

# -----------------------------------------------------------------------------
# Verify Prerequisites
# -----------------------------------------------------------------------------
verify_prerequisites() {
    log_step "Verifying prerequisites..."

    local errors=0
    local tomcat_home="${ALFRESCO_HOME}/tomcat"

    # Check Tomcat is installed
    if [ ! -d "$tomcat_home" ]; then
        log_error "Tomcat not found at $tomcat_home"
        log_error "Please run 03-install_tomcat.sh first"
        ((errors++))
    fi

    # Check downloads exist
    local dist_file
    dist_file=$(find "$DOWNLOAD_DIR" -name "alfresco-content-services-community-distribution-*.zip" 2>/dev/null | head -1)

    if [ -z "$dist_file" ] || [ ! -f "$dist_file" ]; then
        log_error "Alfresco distribution not found in $DOWNLOAD_DIR"
        log_error "Please run 05-download_alfresco_resources.sh first"
        ((errors++))
    else
        log_info "Found distribution: $(basename "$dist_file")"
    fi

    if [ $errors -gt 0 ]; then
        log_error "Prerequisites check failed"
        exit 1
    fi

    log_info "All prerequisites verified"
}

# -----------------------------------------------------------------------------
# Install Dependencies
# -----------------------------------------------------------------------------
install_dependencies() {
    log_step "Installing dependencies..."

    # Check if unzip is installed
    if ! command -v unzip &> /dev/null; then
        log_info "Installing unzip..."
        sudo apt-get update
        sudo apt-get install -y unzip
    else
        log_info "unzip is already installed"
    fi
}

# -----------------------------------------------------------------------------
# Configure Tomcat Shared Loader
# -----------------------------------------------------------------------------
configure_tomcat_shared() {
    log_step "Configuring Tomcat shared loader..."

    local tomcat_home="${ALFRESCO_HOME}/tomcat"
    local catalina_props="$tomcat_home/conf/catalina.properties"
    local shared_classes="$tomcat_home/shared/classes"
    local shared_lib="$tomcat_home/shared/lib"

    # Create shared directories
    sudo mkdir -p "$shared_classes" "$shared_lib"

    # Check if already configured
    if sudo grep -q 'shared.loader=.*shared/classes' "$catalina_props" 2>/dev/null; then
        log_info "Tomcat shared loader already configured"
        return 0
    fi

    # Backup original
    backup_file "$catalina_props"

    # Configure shared.loader
    # Note: ${catalina.base} is a Tomcat variable, not a shell variable
    log_info "Updating catalina.properties..."
    # shellcheck disable=SC2016
    sudo sed -i 's|^shared.loader=$|shared.loader=${catalina.base}/shared/classes,${catalina.base}/shared/lib/*.jar|' "$catalina_props"

    log_info "Tomcat shared loader configured"
}

# -----------------------------------------------------------------------------
# Extract Alfresco Distribution
# -----------------------------------------------------------------------------
extract_alfresco_distribution() {
    log_step "Extracting Alfresco distribution..."

    local dist_file
    dist_file=$(find "$DOWNLOAD_DIR" -name "alfresco-content-services-community-distribution-*.zip" | head -1)

    if [ -z "$dist_file" ] || [ ! -f "$dist_file" ]; then
        log_error "Alfresco distribution not found in $DOWNLOAD_DIR"
        log_error "Please run 05-download_alfresco_resources.sh first"
        exit 1
    fi

    # Create a unique, user-owned temp directory to avoid sudo ownership problems
    TEMP_DIR="$(mktemp -d -t alfresco-install-XXXXXX)"
    log_info "Using temp directory: $TEMP_DIR"

    log_info "Extracting $(basename "$dist_file")..."
    unzip -q "$dist_file" -d "$TEMP_DIR"

    # Find the extracted directory (may have version in name)
    ALFRESCO_DIST_DIR=$(find "$TEMP_DIR" -maxdepth 1 -type d -name "alfresco-content-*" | head -1)

    if [ -z "$ALFRESCO_DIST_DIR" ]; then
        # Files might be directly in TEMP_DIR
        ALFRESCO_DIST_DIR="$TEMP_DIR"
    fi

    log_info "Distribution extracted to: $ALFRESCO_DIST_DIR"
}

# -----------------------------------------------------------------------------
# Install JDBC Driver
# -----------------------------------------------------------------------------
install_jdbc_driver() {
    log_step "Installing PostgreSQL JDBC driver..."

    local tomcat_home="${ALFRESCO_HOME}/tomcat"
    local jdbc_source
    jdbc_source=$(find "$ALFRESCO_DIST_DIR" -name "postgresql-*.jar" | head -1)

    if [ -z "$jdbc_source" ]; then
        log_error "PostgreSQL JDBC driver not found in distribution"
        exit 1
    fi

    local jdbc_dest
    jdbc_dest="$tomcat_home/shared/lib/$(basename "$jdbc_source")"

    if [ -f "$jdbc_dest" ]; then
        log_info "JDBC driver already installed: $(basename "$jdbc_source")"
    else
        sudo cp "$jdbc_source" "$tomcat_home/shared/lib/"
        log_info "Installed JDBC driver: $(basename "$jdbc_source")"
    fi
}

# -----------------------------------------------------------------------------
# Install Web Applications
# -----------------------------------------------------------------------------
install_web_applications() {
    log_step "Installing web applications..."

    local tomcat_home="${ALFRESCO_HOME}/tomcat"
    local webapps_source="$ALFRESCO_DIST_DIR/web-server/webapps"
    local webapps_dest="$tomcat_home/webapps"

    # Copy WAR files
    for war in "$webapps_source"/*.war; do
        if [ -f "$war" ]; then
            local war_name
            war_name=$(basename "$war")

            if [ -f "$webapps_dest/$war_name" ]; then
                log_info "WAR already exists: $war_name (backing up)"
                backup_file "$webapps_dest/$war_name"
            fi

            sudo cp "$war" "$webapps_dest/"
            log_info "Installed: $war_name"
        fi
    done

    # Copy shared classes
    if [ -d "$ALFRESCO_DIST_DIR/web-server/shared/classes" ]; then
        log_info "Copying shared classes..."
        sudo cp -r "$ALFRESCO_DIST_DIR/web-server/shared/classes/"* "$tomcat_home/shared/classes/"
    fi

    # Copy context files
    local catalina_conf="$tomcat_home/conf/Catalina/localhost"
    sudo mkdir -p "$catalina_conf"

    if [ -d "$ALFRESCO_DIST_DIR/web-server/conf/Catalina/localhost" ]; then
        log_info "Copying Catalina context files..."
        sudo cp "$ALFRESCO_DIST_DIR/web-server/conf/Catalina/localhost/"* "$catalina_conf/"
    fi
}

# -----------------------------------------------------------------------------
# Install Keystore
# -----------------------------------------------------------------------------
install_keystore() {
    log_step "Installing keystore..."

    local keystore_dest="${ALFRESCO_HOME}/keystore"

    if [ -d "$keystore_dest" ] && [ -f "$keystore_dest/metadata-keystore/keystore" ]; then
        log_info "Keystore already installed"
        return 0
    fi

    sudo mkdir -p "$keystore_dest"

    if [ -d "$ALFRESCO_DIST_DIR/keystore" ]; then
        sudo cp -r "$ALFRESCO_DIST_DIR/keystore/"* "$keystore_dest/"
        log_info "Keystore installed to: $keystore_dest"
    else
        log_warn "Keystore not found in distribution"
    fi

    # Secure keystore
    sudo chmod 700 "$keystore_dest"
    sudo find "$keystore_dest" -type f -exec chmod 600 {} \;
}

# -----------------------------------------------------------------------------
# Create Data Directory
# -----------------------------------------------------------------------------
create_data_directory() {
    log_step "Creating Alfresco data directory..."

    local alf_data="${ALFRESCO_HOME}/alf_data"

    if [ -d "$alf_data" ]; then
        log_info "Data directory already exists: $alf_data"
    else
        sudo mkdir -p "$alf_data"
        log_info "Created data directory: $alf_data"
    fi

    # Create subdirectories
    sudo mkdir -p "$alf_data/contentstore"
    sudo mkdir -p "$alf_data/contentstore.deleted"
}

# -----------------------------------------------------------------------------
# Create alfresco-global.properties
# -----------------------------------------------------------------------------
create_alfresco_global_properties() {
    log_step "Creating alfresco-global.properties..."

    local tomcat_home="${ALFRESCO_HOME}/tomcat"
    local props_file="$tomcat_home/shared/classes/alfresco-global.properties"

    # Backup if exists
    if sudo test -f "$props_file"; then
        backup_file "$props_file"
    fi

    sudo tee "$props_file" > /dev/null << EOF
# =============================================================================
# Alfresco Global Properties
# =============================================================================
# Generated by Alfresco installer on $(date)
#
# WARNING: This file contains sensitive information.
# Ensure proper file permissions are set.
# =============================================================================

# -----------------------------------------------------------------------------
# Content and Index Data Location
# -----------------------------------------------------------------------------
dir.root=${ALFRESCO_HOME}/alf_data
dir.keystore=${ALFRESCO_HOME}/keystore

# -----------------------------------------------------------------------------
# Database Connection
# -----------------------------------------------------------------------------
db.driver=org.postgresql.Driver
db.url=jdbc:postgresql://${ALFRESCO_DB_HOST}:${ALFRESCO_DB_PORT}/${ALFRESCO_DB_NAME}
db.username=${ALFRESCO_DB_USER}
db.password=${ALFRESCO_DB_PASSWORD}

# Connection pool settings
db.pool.initial=10
db.pool.max=100
db.pool.validate.query=SELECT 1

# -----------------------------------------------------------------------------
# Solr Configuration
# -----------------------------------------------------------------------------
index.subsystem.name=solr6
solr.secureComms=secret
solr.sharedSecret=${SOLR_SHARED_SECRET}
solr.host=${SOLR_HOST}
solr.port=${SOLR_PORT}

# -----------------------------------------------------------------------------
# Transform Service Configuration
# -----------------------------------------------------------------------------
localTransform.core-aio.url=http://${TRANSFORM_HOST}:${TRANSFORM_PORT}/

# Legacy transform settings (disabled when using Transform Service)
local.transform.service.enabled=true
legacy.transform.service.enabled=false

# -----------------------------------------------------------------------------
# ActiveMQ / Messaging Configuration
# -----------------------------------------------------------------------------
messaging.broker.url=failover:(nio://${ACTIVEMQ_HOST}:${ACTIVEMQ_PORT})?timeout=3000&jms.useCompression=true

# -----------------------------------------------------------------------------
# Alfresco URL Generation
# -----------------------------------------------------------------------------
alfresco.context=alfresco
alfresco.host=${ALFRESCO_HOST}
alfresco.port=${ALFRESCO_PORT}
alfresco.protocol=${ALFRESCO_PROTOCOL}

# -----------------------------------------------------------------------------
# Share URL Generation
# -----------------------------------------------------------------------------
share.context=share
share.host=${SHARE_HOST}
share.port=${SHARE_PORT}
share.protocol=${SHARE_PROTOCOL}

# -----------------------------------------------------------------------------
# CSRF Filter Configuration
# -----------------------------------------------------------------------------
csrf.filter.enabled=true
csrf.filter.referer=.*
csrf.filter.origin=.*

# -----------------------------------------------------------------------------
# Security Settings
# -----------------------------------------------------------------------------
# Disable SSO by default (enable if using external auth)
authentication.chain=alfrescoNtlm1:alfrescoNtlm

# Session timeout (in seconds) - 1 hour
server.session.timeout=3600

# -----------------------------------------------------------------------------
# Performance Tuning
# -----------------------------------------------------------------------------
# Content caching
system.content.caching.maxUsageMB=4096
system.content.caching.minFileAgeMillis=0

# Thumbnail generation
system.thumbnail.generate=true

# -----------------------------------------------------------------------------
# Smart Folders (disabled by default)
# -----------------------------------------------------------------------------
smart.folders.enabled=false
EOF

    # Secure the properties file
    sudo chmod 600 "$props_file"
    sudo chown "${ALFRESCO_USER}:${ALFRESCO_GROUP}" "$props_file"

    log_info "Created alfresco-global.properties"
}

# -----------------------------------------------------------------------------
# Configure Addon Directories
# -----------------------------------------------------------------------------
configure_addon_directories() {
    log_step "Configuring addon directories..."

    local modules_platform="${ALFRESCO_HOME}/modules/platform"
    local modules_share="${ALFRESCO_HOME}/modules/share"
    local amps_dir="${ALFRESCO_HOME}/amps"
    local amps_share_dir="${ALFRESCO_HOME}/amps_share"
    local bin_dir="${ALFRESCO_HOME}/bin"

    # Create directories
    sudo mkdir -p "$modules_platform" "$modules_share" "$amps_dir" "$amps_share_dir" "$bin_dir"

    # Copy AMPs from distribution
    if [ -d "$ALFRESCO_DIST_DIR/amps" ]; then
        log_info "Copying platform AMPs..."
        sudo cp -r "$ALFRESCO_DIST_DIR/amps/"* "$amps_dir/" 2>/dev/null || true
    fi

    if [ -d "$ALFRESCO_DIST_DIR/amps_share" ]; then
        log_info "Copying Share AMPs..."
        sudo cp -r "$ALFRESCO_DIST_DIR/amps_share/"* "$amps_share_dir/" 2>/dev/null || true
    fi

    # Copy bin utilities (including alfresco-mmt.jar)
    if [ -d "$ALFRESCO_DIST_DIR/bin" ]; then
        log_info "Copying bin utilities..."
        sudo cp -r "$ALFRESCO_DIST_DIR/bin/"* "$bin_dir/"
    fi

    log_info "Addon directories configured"
}

# -----------------------------------------------------------------------------
# Apply AMPs
# -----------------------------------------------------------------------------
apply_amps() {
    log_step "Applying AMPs to WAR files..."

    local tomcat_home="${ALFRESCO_HOME}/tomcat"
    local mmt_jar="${ALFRESCO_HOME}/bin/alfresco-mmt.jar"
    local alfresco_war="$tomcat_home/webapps/alfresco.war"
    local share_war="$tomcat_home/webapps/share.war"
    local amps_dir="${ALFRESCO_HOME}/amps"
    local amps_share_dir="${ALFRESCO_HOME}/amps_share"

    # Check if MMT exists
    if [ ! -f "$mmt_jar" ]; then
        log_warn "alfresco-mmt.jar not found, skipping AMP installation"
        return 0
    fi

    # Apply platform AMPs
    if [ -d "$amps_dir" ] && [ "$(ls -A "$amps_dir" 2>/dev/null)" ]; then
        log_info "Applying platform AMPs..."
        java -jar "$mmt_jar" install "$amps_dir" "$alfresco_war" -directory -force

        log_info "Installed platform AMPs:"
        java -jar "$mmt_jar" list "$alfresco_war"
    else
        log_info "No platform AMPs to install"
    fi

    # Apply Share AMPs
    if [ -d "$amps_share_dir" ] && [ "$(ls -A "$amps_share_dir" 2>/dev/null)" ]; then
        log_info "Applying Share AMPs..."
        java -jar "$mmt_jar" install "$amps_share_dir" "$share_war" -directory -force

        log_info "Installed Share AMPs:"
        java -jar "$mmt_jar" list "$share_war"
    else
        log_info "No Share AMPs to install"
    fi
}

# -----------------------------------------------------------------------------
# Extract WAR Files
# -----------------------------------------------------------------------------
extract_war_files() {
    log_step "Extracting WAR files..."

    local tomcat_home="${ALFRESCO_HOME}/tomcat"

    # Extract alfresco.war
    local alfresco_dir="$tomcat_home/webapps/alfresco"
    if [ -d "$alfresco_dir" ]; then
        log_info "Alfresco WAR already extracted"
    else
        log_info "Extracting alfresco.war..."
        sudo mkdir -p "$alfresco_dir"
        unzip -q "$tomcat_home/webapps/alfresco.war" -d "$alfresco_dir"
    fi

    # Extract share.war
    local share_dir="$tomcat_home/webapps/share"
    if [ -d "$share_dir" ]; then
        log_info "Share WAR already extracted"
    else
        log_info "Extracting share.war..."
        sudo mkdir -p "$share_dir"
        unzip -q "$tomcat_home/webapps/share.war" -d "$share_dir"
    fi
}

# -----------------------------------------------------------------------------
# Configure Logging
# -----------------------------------------------------------------------------
configure_logging() {
    log_step "Configuring logging..."

    local tomcat_home="${ALFRESCO_HOME}/tomcat"
    local logs_dir="$tomcat_home/logs"

    # Ensure logs directory exists
    sudo mkdir -p "$logs_dir"

    # Configure Alfresco logging
    local alfresco_log4j="$tomcat_home/webapps/alfresco/WEB-INF/classes/log4j2.properties"
    if [ -f "$alfresco_log4j" ]; then
        backup_file "$alfresco_log4j"
        sudo sed -i "s|^appender\.rolling\.fileName=alfresco\.log|appender.rolling.fileName=$logs_dir/alfresco.log|" "$alfresco_log4j"
        sudo sed -i "s|^appender\.rolling\.filePattern=alfresco\.log|appender.rolling.filePattern=$logs_dir/alfresco.log|" "$alfresco_log4j"
        log_info "Configured Alfresco logging: $logs_dir/alfresco.log"
    fi

    # Configure Share logging
    local share_log4j="$tomcat_home/webapps/share/WEB-INF/classes/log4j2.properties"
    if [ -f "$share_log4j" ]; then
        backup_file "$share_log4j"
        sudo sed -i "s|^appender\.rolling\.fileName=share\.log|appender.rolling.fileName=$logs_dir/share.log|" "$share_log4j"
        sudo sed -i "s|^appender\.rolling\.filePattern=share\.log|appender.rolling.filePattern=$logs_dir/share.log|" "$share_log4j"
        log_info "Configured Share logging: $logs_dir/share.log"
    fi
}

# -----------------------------------------------------------------------------
# Set Permissions
# -----------------------------------------------------------------------------
set_permissions() {
    log_step "Setting file permissions..."

    local tomcat_home="${ALFRESCO_HOME}/tomcat"

    # Set ownership for Alfresco directories
    local dirs=(
        "$tomcat_home"
        "${ALFRESCO_HOME}/alf_data"
        "${ALFRESCO_HOME}/keystore"
        "${ALFRESCO_HOME}/modules"
        "${ALFRESCO_HOME}/amps"
        "${ALFRESCO_HOME}/amps_share"
        "${ALFRESCO_HOME}/bin"
    )

    for dir in "${dirs[@]}"; do
        if [ -d "$dir" ]; then
            sudo chown -R "${ALFRESCO_USER}:${ALFRESCO_GROUP}" "$dir"
        fi
    done

    # Secure sensitive files
    sudo chmod 600 "$tomcat_home/shared/classes/alfresco-global.properties"
    sudo chmod 700 "${ALFRESCO_HOME}/keystore"

    log_info "Permissions configured"
}

# -----------------------------------------------------------------------------
# Cleanup
# -----------------------------------------------------------------------------
cleanup() {
    log_step "Cleaning up temporary files..."

    if [ -n "$TEMP_DIR" ] && [ -d "$TEMP_DIR" ]; then
        rm -rf "$TEMP_DIR"
        log_info "Removed temporary directory: $TEMP_DIR"
        TEMP_DIR=""
    fi
}

# -----------------------------------------------------------------------------
# Verify Installation
# -----------------------------------------------------------------------------
verify_installation() {
    log_step "Verifying Alfresco installation..."

    local tomcat_home="${ALFRESCO_HOME}/tomcat"
    local errors=0

    # Check key directories
    local dirs=(
        "$tomcat_home/webapps/alfresco"
        "$tomcat_home/webapps/share"
        "${ALFRESCO_HOME}/alf_data"
        "${ALFRESCO_HOME}/keystore"
    )

    for dir in "${dirs[@]}"; do
        if sudo test -d "$dir"; then
            log_info "Directory exists: $dir"
        else
            log_error "Directory missing: $dir"
            ((errors++))
        fi
    done

    # Check key files
    local files=(
        "$tomcat_home/shared/classes/alfresco-global.properties"
        "$tomcat_home/shared/lib/postgresql-"*".jar"
        "$tomcat_home/webapps/alfresco/WEB-INF/web.xml"
        "$tomcat_home/webapps/share/WEB-INF/web.xml"
    )

    for file_pattern in "${files[@]}"; do
        # Use sudo ls to expand glob patterns (SC2086 intentionally ignored for glob expansion)
        # shellcheck disable=SC2086
        if sudo ls $file_pattern 1> /dev/null 2>&1; then
            log_info "File exists: $file_pattern"
        else
            log_error "File missing: $file_pattern"
            ((errors++))
        fi
    done

    # Check configuration file permissions
    local props_perms
    props_perms=$(sudo stat -c "%a" "$tomcat_home/shared/classes/alfresco-global.properties" 2>/dev/null)
    if [ "$props_perms" = "600" ]; then
        log_info "alfresco-global.properties has secure permissions (600)"
    else
        log_warn "alfresco-global.properties permissions are $props_perms (should be 600)"
    fi

    if [ $errors -gt 0 ]; then
        log_error "Verification failed with $errors error(s)"
        exit 1
    fi

    log_info ""
    log_info "Alfresco installation summary:"
    log_info "  Alfresco URL: ${ALFRESCO_PROTOCOL}://${ALFRESCO_HOST}:${ALFRESCO_PORT}/alfresco"
    log_info "  Share URL:    ${SHARE_PROTOCOL}://${SHARE_HOST}:${SHARE_PORT}/share"
    log_info "  Data Dir:     ${ALFRESCO_HOME}/alf_data"
    log_info "  Logs Dir:     $tomcat_home/logs"
    log_info ""
    log_info "All verifications passed"
}

# -----------------------------------------------------------------------------
# Run Main
# -----------------------------------------------------------------------------
main "$@"
