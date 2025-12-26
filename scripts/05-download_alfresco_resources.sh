#!/bin/bash
# =============================================================================
# Alfresco Resources Download Script
# =============================================================================
# Downloads Alfresco distribution packages from Nexus repository.
#
# Components downloaded:
# - Alfresco Content Services Community Distribution (ZIP)
# - Alfresco Search Services (ZIP)
# - Alfresco Transform Core AIO (JAR)
#
# Prerequisites:
# - Run 00-generate-config.sh first to create configuration
# - Internet connectivity to nexus.alfresco.com
#
# Usage:
#   bash scripts/05-download_alfresco_resources.sh
# =============================================================================

# Load common functions and configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
NEXUS_BASE_URL="https://nexus.alfresco.com/nexus"
NEXUS_BROWSE_URL="${NEXUS_BASE_URL}/service/rest/repository/browse/releases/org/alfresco"
NEXUS_DOWNLOAD_URL="${NEXUS_BASE_URL}/repository/releases/org/alfresco"

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
    log_step "Starting Alfresco resources download..."
    
    # Pre-flight checks
    load_config
    check_prerequisites curl
    
    # Determine versions
    determine_versions
    
    # Create download directory
    create_download_directory
    
    # Download components
    download_alfresco_distribution
    download_search_services
    download_transform_core
    
    # Verify downloads
    verify_downloads
    
    log_info "All Alfresco resources downloaded successfully!"
}

# -----------------------------------------------------------------------------
# Determine Versions
# -----------------------------------------------------------------------------
determine_versions() {
    log_step "Determining component versions..."
    
    if [ "${USE_LATEST_VERSIONS:-false}" = "true" ]; then
        log_warn "USE_LATEST_VERSIONS is enabled - fetching latest versions..."
        
        ALFRESCO_VERSION_ACTUAL=$(fetch_latest_nexus_version "alfresco-content-services-community-distribution")
        ALFRESCO_SEARCH_VERSION_ACTUAL=$(fetch_latest_nexus_version "alfresco-search-services")
        ALFRESCO_TRANSFORM_VERSION_ACTUAL=$(fetch_latest_nexus_version "alfresco-transform-core-aio")
        
        # Fall back to pinned versions if fetch fails
        ALFRESCO_VERSION_ACTUAL="${ALFRESCO_VERSION_ACTUAL:-$ALFRESCO_VERSION}"
        ALFRESCO_SEARCH_VERSION_ACTUAL="${ALFRESCO_SEARCH_VERSION_ACTUAL:-$ALFRESCO_SEARCH_VERSION}"
        ALFRESCO_TRANSFORM_VERSION_ACTUAL="${ALFRESCO_TRANSFORM_VERSION_ACTUAL:-$ALFRESCO_TRANSFORM_VERSION}"
    else
        ALFRESCO_VERSION_ACTUAL="$ALFRESCO_VERSION"
        ALFRESCO_SEARCH_VERSION_ACTUAL="$ALFRESCO_SEARCH_VERSION"
        ALFRESCO_TRANSFORM_VERSION_ACTUAL="$ALFRESCO_TRANSFORM_VERSION"
    fi
    
    log_info "Alfresco Content Services: ${ALFRESCO_VERSION_ACTUAL}"
    log_info "Alfresco Search Services:  ${ALFRESCO_SEARCH_VERSION_ACTUAL}"
    log_info "Alfresco Transform Core:   ${ALFRESCO_TRANSFORM_VERSION_ACTUAL}"
}

# -----------------------------------------------------------------------------
# Fetch Latest Version from Nexus
# -----------------------------------------------------------------------------
fetch_latest_nexus_version() {
    local artifact=$1
    local browse_url="${NEXUS_BROWSE_URL}/${artifact}/"
    
    curl -s "$browse_url" \
        | sed -n 's/.*<a href="\(.*\)\/">.*/\1/p' \
        | grep -E '^[0-9]+(\.[0-9]+)*$' \
        | sort -V \
        | tail -n 1
}

# -----------------------------------------------------------------------------
# Create Download Directory
# -----------------------------------------------------------------------------
create_download_directory() {
    log_step "Creating download directory..."
    
    DOWNLOAD_DIR="${SCRIPT_DIR}/../downloads"
    
    if [ ! -d "$DOWNLOAD_DIR" ]; then
        mkdir -p "$DOWNLOAD_DIR"
        log_info "Created directory: $DOWNLOAD_DIR"
    else
        log_info "Download directory exists: $DOWNLOAD_DIR"
    fi
}

# -----------------------------------------------------------------------------
# Download File with Progress
# -----------------------------------------------------------------------------
download_file() {
    local url=$1
    local dest_file=$2
    local description=$3
    
    local filename
    filename=$(basename "$dest_file")
    
    # Check if file already exists and is valid
    if [ -f "$dest_file" ] && [ -s "$dest_file" ]; then
        log_info "Already downloaded: $filename"
        return 0
    fi
    
    log_info "Downloading $description..."
    log_info "  URL: $url"
    log_info "  Destination: $dest_file"
    
    # Download with progress bar
    local http_code
    http_code=$(curl -L \
        --progress-bar \
        --output "$dest_file" \
        --write-out "%{http_code}" \
        "$url")
    
    # Check HTTP status
    if [ "$http_code" -ne 200 ]; then
        log_error "Download failed with HTTP status: $http_code"
        rm -f "$dest_file"
        return 1
    fi
    
    # Verify file is not empty
    if [ ! -s "$dest_file" ]; then
        log_error "Downloaded file is empty: $filename"
        rm -f "$dest_file"
        return 1
    fi
    
    # Display file size
    local file_size
    file_size=$(du -h "$dest_file" | cut -f1)
    log_info "Downloaded: $filename ($file_size)"
    
    return 0
}

# -----------------------------------------------------------------------------
# Download Alfresco Content Services Distribution
# -----------------------------------------------------------------------------
download_alfresco_distribution() {
    log_step "Downloading Alfresco Content Services Community Distribution..."
    
    local artifact="alfresco-content-services-community-distribution"
    local version="$ALFRESCO_VERSION_ACTUAL"
    local filename="${artifact}-${version}.zip"
    local url="${NEXUS_DOWNLOAD_URL}/${artifact}/${version}/${filename}"
    local dest_file="${DOWNLOAD_DIR}/${filename}"
    
    if ! download_file "$url" "$dest_file" "Alfresco Content Services ${version}"; then
        log_error "Failed to download Alfresco Content Services"
        exit 1
    fi
    
    # Store filename for later use
    ALFRESCO_DISTRIBUTION_FILE="$dest_file"
}

# -----------------------------------------------------------------------------
# Download Alfresco Search Services
# -----------------------------------------------------------------------------
download_search_services() {
    log_step "Downloading Alfresco Search Services..."
    
    local artifact="alfresco-search-services"
    local version="$ALFRESCO_SEARCH_VERSION_ACTUAL"
    local filename="${artifact}-${version}.zip"
    local url="${NEXUS_DOWNLOAD_URL}/${artifact}/${version}/${filename}"
    local dest_file="${DOWNLOAD_DIR}/${filename}"
    
    if ! download_file "$url" "$dest_file" "Alfresco Search Services ${version}"; then
        log_error "Failed to download Alfresco Search Services"
        exit 1
    fi
    
    # Store filename for later use
    ALFRESCO_SEARCH_FILE="$dest_file"
}

# -----------------------------------------------------------------------------
# Download Alfresco Transform Core
# -----------------------------------------------------------------------------
download_transform_core() {
    log_step "Downloading Alfresco Transform Core..."
    
    local artifact="alfresco-transform-core-aio"
    local version="$ALFRESCO_TRANSFORM_VERSION_ACTUAL"
    local filename="${artifact}-${version}.jar"
    local url="${NEXUS_DOWNLOAD_URL}/${artifact}/${version}/${filename}"
    local dest_file="${DOWNLOAD_DIR}/${filename}"
    
    if ! download_file "$url" "$dest_file" "Alfresco Transform Core ${version}"; then
        log_error "Failed to download Alfresco Transform Core"
        exit 1
    fi
    
    # Store filename for later use
    ALFRESCO_TRANSFORM_FILE="$dest_file"
}

# -----------------------------------------------------------------------------
# Verify Downloads
# -----------------------------------------------------------------------------
verify_downloads() {
    log_step "Verifying downloaded files..."
    
    local errors=0
    
    # Define expected files
    local expected_files=(
        "${DOWNLOAD_DIR}/alfresco-content-services-community-distribution-${ALFRESCO_VERSION_ACTUAL}.zip"
        "${DOWNLOAD_DIR}/alfresco-search-services-${ALFRESCO_SEARCH_VERSION_ACTUAL}.zip"
        "${DOWNLOAD_DIR}/alfresco-transform-core-aio-${ALFRESCO_TRANSFORM_VERSION_ACTUAL}.jar"
    )
    
    for file in "${expected_files[@]}"; do
        if [ -f "$file" ] && [ -s "$file" ]; then
            local file_size
            file_size=$(du -h "$file" | cut -f1)
            log_info "$(basename "$file") ($file_size)"
        else
            log_error "Missing or empty: $(basename "$file")"
            ((errors++))
        fi
    done
    
    # Verify ZIP files are valid
    log_info ""
    log_info "Validating archive integrity..."
    
    for file in "${DOWNLOAD_DIR}"/*.zip; do
        if [ -f "$file" ]; then
            if unzip -t "$file" > /dev/null 2>&1; then
                log_info "Valid ZIP: $(basename "$file")"
            else
                log_error "Corrupt ZIP: $(basename "$file")"
                ((errors++))
            fi
        fi
    done
    
    # Verify JAR file is valid
    for file in "${DOWNLOAD_DIR}"/*.jar; do
        if [ -f "$file" ]; then
            if unzip -t "$file" > /dev/null 2>&1; then
                log_info "Valid JAR: $(basename "$file")"
            else
                log_error "Corrupt JAR: $(basename "$file")"
                ((errors++))
            fi
        fi
    done
    
    if [ $errors -gt 0 ]; then
        log_error "Verification failed with $errors error(s)"
        log_error "Try deleting the corrupt files and running this script again"
        exit 1
    fi
    
    # Create a manifest file for reference
    create_manifest
    
    log_info ""
    log_info "All downloads verified successfully"
}

# -----------------------------------------------------------------------------
# Create Download Manifest
# -----------------------------------------------------------------------------
create_manifest() {
    local manifest_file="${DOWNLOAD_DIR}/MANIFEST.txt"
    
    cat << EOF > "$manifest_file"
# Alfresco Resources Download Manifest
# Generated: $(date)
# 
# This file documents the versions of Alfresco components downloaded.
# Keep this file for reference during troubleshooting.

Alfresco Content Services: ${ALFRESCO_VERSION_ACTUAL}
Alfresco Search Services:  ${ALFRESCO_SEARCH_VERSION_ACTUAL}
Alfresco Transform Core:   ${ALFRESCO_TRANSFORM_VERSION_ACTUAL}

Files:
$(find "${DOWNLOAD_DIR}" -maxdepth 1 \( -name "*.zip" -o -name "*.jar" \) -exec ls -lh {} \; 2>/dev/null | awk '{print "  " $NF " (" $5 ")"}')

Pinned versions from config/versions.conf:
  ALFRESCO_VERSION=${ALFRESCO_VERSION}
  ALFRESCO_SEARCH_VERSION=${ALFRESCO_SEARCH_VERSION}
  ALFRESCO_TRANSFORM_VERSION=${ALFRESCO_TRANSFORM_VERSION}
  USE_LATEST_VERSIONS=${USE_LATEST_VERSIONS:-false}
EOF
    
    log_info "Created manifest: $manifest_file"
}

# -----------------------------------------------------------------------------
# Run Main
# -----------------------------------------------------------------------------
main "$@"
