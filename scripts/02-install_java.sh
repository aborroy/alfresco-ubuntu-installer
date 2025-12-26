#!/bin/bash
# =============================================================================
# Java JDK Installation Script
# =============================================================================
# Installs and configures Java JDK for Alfresco Content Services.
#
# Prerequisites:
# - Run 00-generate-config.sh first to create configuration
# - Ubuntu 22.04 or 24.04
# - sudo privileges
#
# Usage:
#   bash scripts/02-install_java.sh
# =============================================================================

# Load common functions and configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

# -----------------------------------------------------------------------------
# Main Installation
# -----------------------------------------------------------------------------
main() {
    log_step "Starting Java JDK installation..."
    
    # Pre-flight checks
    check_root
    check_sudo
    load_config
    
    # Detect architecture
    detect_architecture
    
    # Install Java
    install_java
    
    # Configure alternatives
    configure_java_alternatives
    
    # Set JAVA_HOME
    configure_java_home
    
    # Verify installation
    verify_installation
    
    log_info "Java JDK ${JAVA_VERSION} installation completed successfully!"
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
    
    log_info "Detected architecture: $ARCH"
    
    # Set JAVA_HOME path based on architecture
    JAVA_HOME_PATH="/usr/lib/jvm/java-${JAVA_VERSION}-openjdk-${JAVA_ARCH}"
}

# -----------------------------------------------------------------------------
# Install Java JDK
# -----------------------------------------------------------------------------
install_java() {
    log_step "Installing Java JDK ${JAVA_VERSION}..."
    
    local java_package="openjdk-${JAVA_VERSION}-jdk"
    
    # Check if Java is already installed with correct version
    if command -v java &> /dev/null; then
        local installed_version
        installed_version=$(java -version 2>&1 | head -1 | grep -oP '\d+' | head -1)
        
        if [ "$installed_version" = "$JAVA_VERSION" ]; then
            log_info "Java ${JAVA_VERSION} is already installed"
            return 0
        else
            log_warn "Java ${installed_version} is installed, but version ${JAVA_VERSION} is required"
            log_info "Installing Java ${JAVA_VERSION} alongside existing version..."
        fi
    fi
    
    # Update package list
    log_info "Updating package list..."
    sudo apt-get update
    
    # Install Java JDK
    log_info "Installing ${java_package}..."
    sudo apt-get install -y "$java_package"
    
    log_info "Java JDK ${JAVA_VERSION} installed successfully"
}

# -----------------------------------------------------------------------------
# Configure Java Alternatives
# -----------------------------------------------------------------------------
configure_java_alternatives() {
    log_step "Configuring Java alternatives..."
    
    local java_bin="${JAVA_HOME_PATH}/bin/java"
    local javac_bin="${JAVA_HOME_PATH}/bin/javac"
    
    # Verify binaries exist
    if [ ! -f "$java_bin" ]; then
        log_error "Java binary not found at: $java_bin"
        exit 1
    fi
    
    if [ ! -f "$javac_bin" ]; then
        log_error "Javac binary not found at: $javac_bin"
        exit 1
    fi
    
    # Register alternatives (idempotent - update-alternatives handles duplicates)
    log_info "Registering Java alternatives..."
    sudo update-alternatives --install /usr/bin/java java "$java_bin" 1
    sudo update-alternatives --install /usr/bin/javac javac "$javac_bin" 1
    
    # Set as default
    log_info "Setting Java ${JAVA_VERSION} as default..."
    sudo update-alternatives --set java "$java_bin"
    sudo update-alternatives --set javac "$javac_bin"
    
    log_info "Java alternatives configured"
}

# -----------------------------------------------------------------------------
# Configure JAVA_HOME
# -----------------------------------------------------------------------------
configure_java_home() {
    log_step "Configuring JAVA_HOME..."
    
    local profile_file="/etc/profile.d/java.sh"
    
    # Check if already configured
    if [ -f "$profile_file" ]; then
        if grep -q "JAVA_HOME=${JAVA_HOME_PATH}" "$profile_file"; then
            log_info "JAVA_HOME already configured in $profile_file"
            return 0
        fi
        # Backup existing file
        backup_file "$profile_file"
    fi
    
    # Create/update profile file
    log_info "Creating $profile_file..."
    cat << EOF | sudo tee "$profile_file" > /dev/null
# Java Environment Configuration
# Generated by Alfresco installer on $(date)

export JAVA_HOME="${JAVA_HOME_PATH}"
export PATH="\${JAVA_HOME}/bin:\${PATH}"
EOF
    
    sudo chmod 644 "$profile_file"
    
    # Export for current session
    export JAVA_HOME="${JAVA_HOME_PATH}"
    export PATH="${JAVA_HOME}/bin:${PATH}"
    
    log_info "JAVA_HOME configured: ${JAVA_HOME_PATH}"
}

# -----------------------------------------------------------------------------
# Verify Installation
# -----------------------------------------------------------------------------
verify_installation() {
    log_step "Verifying Java installation..."
    
    local errors=0
    
    # Check java command
    if command -v java &> /dev/null; then
        log_info "java command is available"
    else
        log_error "java command not found"
        ((errors++))
    fi
    
    # Check javac command
    if command -v javac &> /dev/null; then
        log_info "javac command is available"
    else
        log_error "javac command not found"
        ((errors++))
    fi
    
    # Check version matches
    local installed_version
    installed_version=$(java -version 2>&1 | head -1 | grep -oP '\d+' | head -1)
    
    if [ "$installed_version" = "$JAVA_VERSION" ]; then
        log_info "Java version is ${JAVA_VERSION}"
    else
        log_error "Java version mismatch: expected ${JAVA_VERSION}, got ${installed_version}"
        ((errors++))
    fi
    
    # Check JAVA_HOME
    if [ -d "${JAVA_HOME_PATH}" ]; then
        log_info "JAVA_HOME directory exists: ${JAVA_HOME_PATH}"
    else
        log_error "JAVA_HOME directory not found: ${JAVA_HOME_PATH}"
        ((errors++))
    fi
    
    # Display version info
    log_info "Java version details:"
    java -version 2>&1 | while read -r line; do
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
