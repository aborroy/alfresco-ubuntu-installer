#!/bin/bash
# =============================================================================
# Alfresco Add-on Installation Script
# =============================================================================
# Installs and manages Alfresco add-ons (AMPs and JARs).
#
# Prerequisites:
# - Run 00-generate-config.sh first to create configuration
# - Run 06-install_alfresco.sh to install Alfresco
# - Alfresco services should be stopped during installation
#
# Usage:
#   bash scripts/15-install_addons.sh [--amp <file>] [--jar <file>] [--target <repo|share>]
#
# Examples:
#   # Install a platform AMP
#   bash scripts/15-install_addons.sh --amp ootbee-support-tools-repo-1.2.3.0.amp --target repo
#
#   # Install a Share AMP
#   bash scripts/15-install_addons.sh --amp ootbee-support-tools-share-1.2.3.0.amp --target share
#
#   # Install a platform JAR
#   bash scripts/15-install_addons.sh --jar alfresco-script-root-object-2.0.0.jar --target repo
#
#   # List installed add-ons
#   bash scripts/15-install_addons.sh --list
#
#   # Install from URL
#   bash scripts/15-install_addons.sh --url https://github.com/.../addon.amp --target repo
# =============================================================================

# Load common functions and configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

# -----------------------------------------------------------------------------
# Default Configuration
# -----------------------------------------------------------------------------
ADDON_FILE=""
ADDON_URL=""
ADDON_TYPE=""  # amp or jar
TARGET=""      # repo or share
ACTION="install"

# -----------------------------------------------------------------------------
# Help Function
# -----------------------------------------------------------------------------
show_help() {
    cat << EOF
Alfresco Add-on Installation Script

Usage: $(basename "$0") [OPTIONS]

Options:
    --amp <file>        Install an AMP file
    --jar <file>        Install a JAR file
    --url <url>         Download and install from URL
    --target <target>   Target: 'repo' (platform) or 'share'
    --list              List installed add-ons
    --verify            Verify add-on installation
    -h, --help          Show this help message

Examples:
    # Install a platform AMP
    $(basename "$0") --amp support-tools-repo.amp --target repo

    # Install a Share AMP
    $(basename "$0") --amp support-tools-share.amp --target share

    # Install a platform JAR module
    $(basename "$0") --jar alfresco-script-root-object-2.0.0.jar --target repo

    # Install from URL
    $(basename "$0") --url https://github.com/.../addon.amp --target repo

    # List all installed add-ons
    $(basename "$0") --list

Add-on Types:
    AMP (Alfresco Module Package):
        - Full-featured modules with web resources
        - Applied to WAR files using Alfresco Module Management Tool (MMT)
        - Can modify web.xml, add Spring contexts, overlays
        - Stored in: ${ALFRESCO_HOME}/amps (platform) or amps_share (share)

    JAR (Simple Module):
        - Lightweight extensions (scripts, behaviors, webscripts)
        - Placed in modules directory, loaded at startup
        - No WAR modification required
        - Stored in: ${ALFRESCO_HOME}/modules/platform or modules/share

EOF
}

# -----------------------------------------------------------------------------
# Parse Arguments
# -----------------------------------------------------------------------------
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --amp)
                ADDON_FILE="$2"
                ADDON_TYPE="amp"
                shift 2
                ;;
            --jar)
                ADDON_FILE="$2"
                ADDON_TYPE="jar"
                shift 2
                ;;
            --url)
                ADDON_URL="$2"
                shift 2
                ;;
            --target)
                TARGET="$2"
                shift 2
                ;;
            --list)
                ACTION="list"
                shift
                ;;
            --verify)
                ACTION="verify"
                shift
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
    done
}

# -----------------------------------------------------------------------------
# Verify Prerequisites
# -----------------------------------------------------------------------------
verify_prerequisites() {
    log_step "Verifying prerequisites..."

    local errors=0
    local tomcat_home="${ALFRESCO_HOME}/tomcat"

    # Check Alfresco is installed
    if [ ! -d "$tomcat_home/webapps/alfresco" ]; then
        log_error "Alfresco not found at $tomcat_home/webapps/alfresco"
        log_error "Please run 06-install_alfresco.sh first"
        ((errors++))
    fi

    # Check MMT exists (for AMP installation)
    local mmt_jar="${ALFRESCO_HOME}/bin/alfresco-mmt.jar"
    if [ ! -f "$mmt_jar" ]; then
        log_warn "alfresco-mmt.jar not found at $mmt_jar"
        log_warn "AMP installation may not be available"
    fi

    # Check if services are running
    if systemctl is-active --quiet alfresco-tomcat 2>/dev/null; then
        log_warn "Alfresco Tomcat is currently running!"
        log_warn "It is recommended to stop services before installing add-ons."
        log_warn "Run: bash scripts/12-stop_services.sh"
        echo ""
        read -p "Do you want to continue anyway? (y/N): " confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            log_info "Installation cancelled. Stop services and try again."
            exit 0
        fi
    fi

    if [ $errors -gt 0 ]; then
        log_error "Prerequisites check failed"
        exit 1
    fi

    log_info "Prerequisites verified"
}

# -----------------------------------------------------------------------------
# Download Add-on from URL
# -----------------------------------------------------------------------------
download_addon() {
    local url="$1"
    local download_dir="${SCRIPT_DIR}/../downloads/addons"

    mkdir -p "$download_dir"

    local filename
    filename=$(basename "$url")

    # Remove query parameters from filename
    filename="${filename%%\?*}"

    local dest_file="$download_dir/$filename"

    log_step "Downloading add-on from $url..."

    if [ -f "$dest_file" ]; then
        log_info "File already exists: $dest_file"
        read -p "Re-download? (y/N): " confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            rm -f "$dest_file"
        else
            ADDON_FILE="$dest_file"
            return 0
        fi
    fi

    if curl -L -o "$dest_file" "$url"; then
        log_info "Downloaded: $filename"
        ADDON_FILE="$dest_file"
    else
        log_error "Failed to download from $url"
        exit 1
    fi

    # Detect addon type from extension
    if [[ "$filename" == *.amp ]]; then
        ADDON_TYPE="amp"
    elif [[ "$filename" == *.jar ]]; then
        ADDON_TYPE="jar"
    else
        log_error "Unknown file type. Expected .amp or .jar extension"
        exit 1
    fi
}

# -----------------------------------------------------------------------------
# Install AMP Add-on
# -----------------------------------------------------------------------------
install_amp() {
    local amp_file="$1"
    local target="$2"

    log_step "Installing AMP: $(basename "$amp_file") to $target..."

    local tomcat_home="${ALFRESCO_HOME}/tomcat"
    local mmt_jar="${ALFRESCO_HOME}/bin/alfresco-mmt.jar"

    # Validate file exists
    if [ ! -f "$amp_file" ]; then
        log_error "AMP file not found: $amp_file"
        exit 1
    fi

    # Validate MMT exists
    if [ ! -f "$mmt_jar" ]; then
        log_error "alfresco-mmt.jar not found at $mmt_jar"
        exit 1
    fi

    # Determine target directories and WAR
    local amps_dir
    local war_file
    local webapp_dir

    if [ "$target" = "repo" ]; then
        amps_dir="${ALFRESCO_HOME}/amps"
        war_file="$tomcat_home/webapps/alfresco.war"
        webapp_dir="$tomcat_home/webapps/alfresco"
    elif [ "$target" = "share" ]; then
        amps_dir="${ALFRESCO_HOME}/amps_share"
        war_file="$tomcat_home/webapps/share.war"
        webapp_dir="$tomcat_home/webapps/share"
    else
        log_error "Invalid target: $target. Use 'repo' or 'share'"
        exit 1
    fi

    # Create amps directory if not exists
    sudo mkdir -p "$amps_dir"

    # Copy AMP to amps directory
    local amp_name
    amp_name=$(basename "$amp_file")
    sudo cp "$amp_file" "$amps_dir/"
    sudo chown "${ALFRESCO_USER}:${ALFRESCO_GROUP}" "$amps_dir/$amp_name"
    log_info "Copied AMP to: $amps_dir/$amp_name"

    # Check if WAR file exists
    if [ ! -f "$war_file" ]; then
        log_error "WAR file not found: $war_file"
        exit 1
    fi

    # Backup WAR file
    backup_file "$war_file"

    # Ensure WAR is writable
    sudo chown "${ALFRESCO_USER}:${ALFRESCO_GROUP}" "$war_file"
    sudo chmod 664 "$war_file"

    # Apply AMP using MMT
    log_info "Applying AMP to WAR file..."
    sudo -u "${ALFRESCO_USER}" java -jar "$mmt_jar" install "$amps_dir/$amp_name" "$war_file" -force

    # List installed modules
    log_info "Installed modules in $war_file:"
    sudo -u "${ALFRESCO_USER}" java -jar "$mmt_jar" list "$war_file"

    # Remove and re-extract webapp directory to apply changes
    log_info "Re-extracting webapp to apply changes..."
    if [ -d "$webapp_dir" ]; then
        sudo rm -rf "$webapp_dir"
    fi
    sudo mkdir -p "$webapp_dir"
    sudo unzip -q "$war_file" -d "$webapp_dir"
    sudo chown -R "${ALFRESCO_USER}:${ALFRESCO_GROUP}" "$webapp_dir"

    log_info "AMP installation completed: $amp_name"
}

# -----------------------------------------------------------------------------
# Install JAR Add-on
# -----------------------------------------------------------------------------
install_jar() {
    local jar_file="$1"
    local target="$2"

    log_step "Installing JAR: $(basename "$jar_file") to $target..."

    # Validate file exists
    if [ ! -f "$jar_file" ]; then
        log_error "JAR file not found: $jar_file"
        exit 1
    fi

    # Determine target directory
    local modules_dir

    if [ "$target" = "repo" ]; then
        modules_dir="${ALFRESCO_HOME}/modules/platform"
    elif [ "$target" = "share" ]; then
        modules_dir="${ALFRESCO_HOME}/modules/share"
    else
        log_error "Invalid target: $target. Use 'repo' or 'share'"
        exit 1
    fi

    # Create modules directory if not exists
    sudo mkdir -p "$modules_dir"

    # Copy JAR to modules directory
    local jar_name
    jar_name=$(basename "$jar_file")
    sudo cp "$jar_file" "$modules_dir/"
    sudo chown "${ALFRESCO_USER}:${ALFRESCO_GROUP}" "$modules_dir/$jar_name"
    sudo chmod 644 "$modules_dir/$jar_name"

    log_info "Installed JAR to: $modules_dir/$jar_name"
    log_info "JAR installation completed: $jar_name"
}

# -----------------------------------------------------------------------------
# List Installed Add-ons
# -----------------------------------------------------------------------------
list_addons() {
    log_step "Listing installed add-ons..."

    local tomcat_home="${ALFRESCO_HOME}/tomcat"
    local mmt_jar="${ALFRESCO_HOME}/bin/alfresco-mmt.jar"

    echo ""
    echo "=============================================="
    echo "INSTALLED AMP MODULES"
    echo "=============================================="

    # List platform AMPs
    echo ""
    echo "Platform AMPs (in alfresco.war):"
    echo "--------------------------------"
    if [ -f "$mmt_jar" ] && [ -f "$tomcat_home/webapps/alfresco.war" ]; then
        sudo -u "${ALFRESCO_USER}" java -jar "$mmt_jar" list "$tomcat_home/webapps/alfresco.war" 2>/dev/null || echo "  Unable to list modules"
    else
        echo "  alfresco.war or MMT not found"
    fi

    # List share AMPs
    echo ""
    echo "Share AMPs (in share.war):"
    echo "--------------------------"
    if [ -f "$mmt_jar" ] && [ -f "$tomcat_home/webapps/share.war" ]; then
        sudo -u "${ALFRESCO_USER}" java -jar "$mmt_jar" list "$tomcat_home/webapps/share.war" 2>/dev/null || echo "  Unable to list modules"
    else
        echo "  share.war or MMT not found"
    fi

    echo ""
    echo "=============================================="
    echo "AMP FILES"
    echo "=============================================="

    echo ""
    echo "Platform AMPs (${ALFRESCO_HOME}/amps):"
    echo "--------------------------------------"
    if [ -d "${ALFRESCO_HOME}/amps" ]; then
        ls -la "${ALFRESCO_HOME}/amps"/*.amp 2>/dev/null || echo "  No AMP files found"
    else
        echo "  Directory not found"
    fi

    echo ""
    echo "Share AMPs (${ALFRESCO_HOME}/amps_share):"
    echo "------------------------------------------"
    if [ -d "${ALFRESCO_HOME}/amps_share" ]; then
        ls -la "${ALFRESCO_HOME}/amps_share"/*.amp 2>/dev/null || echo "  No AMP files found"
    else
        echo "  Directory not found"
    fi

    echo ""
    echo "=============================================="
    echo "INSTALLED JAR MODULES"
    echo "=============================================="

    echo ""
    echo "Platform JARs (${ALFRESCO_HOME}/modules/platform):"
    echo "---------------------------------------------------"
    if [ -d "${ALFRESCO_HOME}/modules/platform" ]; then
        ls -la "${ALFRESCO_HOME}/modules/platform"/*.jar 2>/dev/null || echo "  No JAR files found"
    else
        echo "  Directory not found"
    fi

    echo ""
    echo "Share JARs (${ALFRESCO_HOME}/modules/share):"
    echo "---------------------------------------------"
    if [ -d "${ALFRESCO_HOME}/modules/share" ]; then
        ls -la "${ALFRESCO_HOME}/modules/share"/*.jar 2>/dev/null || echo "  No JAR files found"
    else
        echo "  Directory not found"
    fi

    echo ""
}

# -----------------------------------------------------------------------------
# Verify Add-on Installation
# -----------------------------------------------------------------------------
verify_installation() {
    log_step "Verifying add-on installation..."

    local tomcat_home="${ALFRESCO_HOME}/tomcat"
    local errors=0

    # Check directory structure
    local dirs=(
        "${ALFRESCO_HOME}/amps"
        "${ALFRESCO_HOME}/amps_share"
        "${ALFRESCO_HOME}/modules/platform"
        "${ALFRESCO_HOME}/modules/share"
    )

    for dir in "${dirs[@]}"; do
        if [ -d "$dir" ]; then
            log_info "Directory exists: $dir"
        else
            log_warn "Directory missing: $dir"
        fi
    done

    # Check webapp permissions
    for webapp in alfresco share; do
        local webapp_dir="$tomcat_home/webapps/$webapp"
        if [ -d "$webapp_dir" ]; then
            local owner
            owner=$(stat -c '%U:%G' "$webapp_dir" 2>/dev/null)
            if [ "$owner" = "${ALFRESCO_USER}:${ALFRESCO_GROUP}" ]; then
                log_info "Correct ownership for $webapp: $owner"
            else
                log_warn "Unexpected ownership for $webapp: $owner (expected ${ALFRESCO_USER}:${ALFRESCO_GROUP})"
            fi
        fi
    done

    if [ $errors -gt 0 ]; then
        log_error "Verification found $errors issue(s)"
        return 1
    fi

    log_info "Verification completed"
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
    parse_arguments "$@"

    # Load configuration
    check_root
    check_sudo
    load_config

    case "$ACTION" in
        install)
            verify_prerequisites

            # Download if URL provided
            if [ -n "$ADDON_URL" ]; then
                download_addon "$ADDON_URL"
            fi

            # Validate required arguments
            if [ -z "$ADDON_FILE" ]; then
                log_error "No add-on file specified. Use --amp, --jar, or --url"
                show_help
                exit 1
            fi

            if [ -z "$TARGET" ]; then
                log_error "No target specified. Use --target repo or --target share"
                show_help
                exit 1
            fi

            # Detect addon type from extension if not set
            if [ -z "$ADDON_TYPE" ]; then
                if [[ "$ADDON_FILE" == *.amp ]]; then
                    ADDON_TYPE="amp"
                elif [[ "$ADDON_FILE" == *.jar ]]; then
                    ADDON_TYPE="jar"
                else
                    log_error "Cannot determine add-on type. Use --amp or --jar explicitly"
                    exit 1
                fi
            fi

            # Install based on type
            case "$ADDON_TYPE" in
                amp)
                    install_amp "$ADDON_FILE" "$TARGET"
                    ;;
                jar)
                    install_jar "$ADDON_FILE" "$TARGET"
                    ;;
                *)
                    log_error "Unknown add-on type: $ADDON_TYPE"
                    exit 1
                    ;;
            esac

            echo ""
            log_info "=============================================="
            log_info "Add-on installation completed!"
            log_info "=============================================="
            log_info ""
            log_info "Next steps:"
            log_info "  1. Start Alfresco services: bash scripts/11-start_services.sh"
            log_info "  2. Check logs for any errors: tail -f ${ALFRESCO_HOME}/tomcat/logs/catalina.out"
            log_info "  3. Verify add-on is working in Alfresco"
            log_info ""
            ;;
        list)
            list_addons
            ;;
        verify)
            verify_installation
            ;;
        *)
            log_error "Unknown action: $ACTION"
            exit 1
            ;;
    esac
}

# Run main
main "$@"