#!/bin/bash
# =============================================================================
# Alfresco Content App (ACA) Build Script
# =============================================================================
# Builds the Alfresco Content App for deployment with Nginx.
#
# This script:
# - Installs Node.js (pinned version)
# - Clones the ACA repository
# - Checks out the specified version tag
# - Builds the production distribution
#
# Prerequisites:
# - Run 00-generate-config.sh first to create configuration
# - Internet connectivity to GitHub and npm registry
# - Ubuntu 22.04 or 24.04
# - sudo privileges
#
# Usage:
#   bash scripts/09-build_aca.sh
#
# Note: This script can be run on a separate build machine if desired.
# =============================================================================

# Load common functions and configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
ACA_REPO_URL="https://github.com/Alfresco/alfresco-content-app.git"

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
    log_step "Starting Alfresco Content App build..."
    
    # Pre-flight checks
    check_root
    check_sudo
    load_config
    
    # Install dependencies
    install_nodejs
    install_git
    
    # Clone and build ACA
    clone_repository
    checkout_version
    configure_app
    install_dependencies
    build_app
    
    # Verify build
    verify_build
    
    log_info "Alfresco Content App build completed successfully!"
}

# -----------------------------------------------------------------------------
# Install Node.js
# -----------------------------------------------------------------------------
install_nodejs() {
    log_step "Installing Node.js ${NODEJS_VERSION}..."
    
    # Check if Node.js is already installed with correct major version
    if command -v node &> /dev/null; then
        local installed_version
        installed_version=$(node -v | grep -oP '\d+' | head -1)
        
        if [ "$installed_version" = "$NODEJS_VERSION" ]; then
            log_info "Node.js ${NODEJS_VERSION}.x is already installed"
            log_info "  Node: $(node -v)"
            log_info "  npm:  $(npm -v)"
            return 0
        else
            log_warn "Node.js ${installed_version}.x is installed, but version ${NODEJS_VERSION}.x is required"
            log_info "Installing Node.js ${NODEJS_VERSION}..."
        fi
    fi
    
    # Install Node.js from NodeSource
    log_info "Adding NodeSource repository..."
    curl -fsSL "https://deb.nodesource.com/setup_${NODEJS_VERSION}.x" | sudo -E bash -
    
    log_info "Installing Node.js..."
    sudo apt-get install -y nodejs
    
    # Verify installation
    log_info "Node.js installed:"
    log_info "  Node: $(node -v)"
    log_info "  npm:  $(npm -v)"
}

# -----------------------------------------------------------------------------
# Install Git
# -----------------------------------------------------------------------------
install_git() {
    log_step "Checking Git installation..."
    
    if command -v git &> /dev/null; then
        log_info "Git is already installed: $(git --version)"
        return 0
    fi
    
    log_info "Installing Git..."
    sudo apt-get install -y git
    
    log_info "Git installed: $(git --version)"
}

# -----------------------------------------------------------------------------
# Clone Repository
# -----------------------------------------------------------------------------
clone_repository() {
    log_step "Cloning Alfresco Content App repository..."
    
    ACA_DIR="${ALFRESCO_HOME}/alfresco-content-app"
    
    if [ -d "$ACA_DIR" ] && [ -d "$ACA_DIR/.git" ]; then
        log_info "Repository already cloned at $ACA_DIR"
        
        # Fetch latest changes
        log_info "Fetching latest changes..."
        cd "$ACA_DIR" || { log_error "Failed to cd to $ACA_DIR"; exit 1; }
        git fetch --tags --force
        
        return 0
    fi
    
    # Clone fresh
    log_info "Cloning from $ACA_REPO_URL..."
    git clone "$ACA_REPO_URL" "$ACA_DIR"
    
    cd "$ACA_DIR" || { log_error "Failed to cd to $ACA_DIR"; exit 1; }
    log_info "Repository cloned to $ACA_DIR"
}

# -----------------------------------------------------------------------------
# Checkout Version
# -----------------------------------------------------------------------------
checkout_version() {
    log_step "Checking out ACA version..."
    
    cd "$ACA_DIR" || { log_error "Failed to cd to $ACA_DIR"; exit 1; }
    
    # Determine version to use
    local target_version
    
    if [ "${USE_LATEST_VERSIONS:-false}" = "true" ]; then
        log_info "Fetching latest version tag..."
        target_version=$(git ls-remote --tags --sort="v:refname" "$ACA_REPO_URL" \
            | grep -oP 'refs/tags/\K[0-9]+\.[0-9]+\.[0-9]+$' \
            | tail -n 1)
        
        if [ -z "$target_version" ]; then
            log_warn "Could not fetch latest version, using pinned version"
            target_version="$ACA_VERSION"
        else
            log_warn "Using latest ACA version: $target_version (pinned was: $ACA_VERSION)"
        fi
    else
        target_version="$ACA_VERSION"
        log_info "Using pinned ACA version: $target_version"
    fi
    
    # Check if already on correct version
    local current_tag
    current_tag=$(git describe --tags --exact-match 2>/dev/null || echo "none")
    
    if [ "$current_tag" = "$target_version" ]; then
        log_info "Already on version $target_version"
        return 0
    fi
    
    # Clean up any local changes
    log_info "Cleaning working directory..."
    git reset --hard HEAD
    git clean -fd
    
    # Checkout the target version
    log_info "Checking out version $target_version..."
    
    # Delete branch if it exists (from previous runs)
    git branch -D "$target_version" 2>/dev/null || true
    
    # Checkout tag
    git checkout "tags/$target_version" -b "$target_version"
    
    log_info "Checked out version $target_version"
}

# -----------------------------------------------------------------------------
# Configure App
# -----------------------------------------------------------------------------
configure_app() {
    log_step "Configuring ACA for Alfresco backend..."
    
    cd "$ACA_DIR" || { log_error "Failed to cd to $ACA_DIR"; exit 1; }
    
    # The app.config.json is typically in src/assets or dist after build
    # For build-time configuration, we modify the proxy or environment
    
    local proxy_config="$ACA_DIR/proxy.conf.js"
    
    if [ -f "$proxy_config" ]; then
        log_info "Updating proxy configuration..."
        backup_file "$proxy_config"
        
        # Update proxy target to use configured Alfresco URL
        # This is used during development; production uses Nginx proxy
        sed -i "s|http://localhost:8080|${ALFRESCO_PROTOCOL}://${ALFRESCO_HOST}:${ALFRESCO_PORT}|g" "$proxy_config" 2>/dev/null || true
    fi
    
    # Create environment configuration for production build
    local env_file="$ACA_DIR/src/environments/environment.prod.ts"
    
    if [ -f "$env_file" ]; then
        log_info "Environment file exists, using defaults"
    fi
    
    log_info "Configuration complete"
}

# -----------------------------------------------------------------------------
# Install Dependencies
# -----------------------------------------------------------------------------
install_dependencies() {
    log_step "Installing npm dependencies..."
    
    cd "$ACA_DIR" || { log_error "Failed to cd to $ACA_DIR"; exit 1; }
    
    # Check if node_modules exists and package-lock.json hasn't changed
    if [ -d "node_modules" ] && [ -f "node_modules/.package-lock.json" ]; then
        local lock_hash
        local cached_hash
        
        lock_hash=$(md5sum package-lock.json 2>/dev/null | cut -d' ' -f1)
        cached_hash=$(cat node_modules/.package-lock-hash 2>/dev/null || echo "none")
        
        if [ "$lock_hash" = "$cached_hash" ]; then
            log_info "Dependencies already installed (cache hit)"
            return 0
        fi
    fi
    
    log_info "Installing dependencies (this may take several minutes)..."
    
    # Use npm ci for faster, more reliable installs when package-lock.json exists
    if [ -f "package-lock.json" ]; then
        npm ci --legacy-peer-deps
    else
        npm install --legacy-peer-deps
    fi
    
    # Cache the package-lock hash
    md5sum package-lock.json | cut -d' ' -f1 > node_modules/.package-lock-hash
    
    log_info "Dependencies installed"
}

# -----------------------------------------------------------------------------
# Build App
# -----------------------------------------------------------------------------
build_app() {
    log_step "Building ACA for production..."
    
    cd "$ACA_DIR" || { log_error "Failed to cd to $ACA_DIR"; exit 1; }
    
    # Check if build already exists for this version
    local version_file="$ACA_DIR/dist/content-ce/.version"
    local current_version
    current_version=$(git describe --tags --exact-match 2>/dev/null || echo "unknown")
    
    if [ -f "$version_file" ]; then
        local built_version
        built_version=$(cat "$version_file")
        
        if [ "$built_version" = "$current_version" ]; then
            log_info "Build already exists for version $current_version"
            return 0
        fi
    fi
    
    log_info "Running production build..."
    log_info "This may take 5-10 minutes depending on your system..."
    
    # Build the application
    # The build output goes to dist/content-ce/
    npm run build
    
    # Save version info
    echo "$current_version" > "$ACA_DIR/dist/content-ce/.version"
    
    log_info "Build completed"
}

# -----------------------------------------------------------------------------
# Verify Build
# -----------------------------------------------------------------------------
verify_build() {
    log_step "Verifying ACA build..."
    
    local dist_dir="$ACA_DIR/dist/content-ce"
    local errors=0
    
    # Check dist directory exists
    if [ -d "$dist_dir" ]; then
        log_info "Distribution directory exists: $dist_dir"
    else
        log_error "Distribution directory not found: $dist_dir"
        ((errors++))
    fi
    
    # Check key files
    local key_files=(
        "index.html"
        "main.js"
        "styles.css"
    )
    
    for file in "${key_files[@]}"; do
        # Files may have hash suffixes, so use glob pattern
        # shellcheck disable=SC2086
        if ls "$dist_dir"/${file%.*}*.${file##*.} 1>/dev/null 2>&1 || [ -f "$dist_dir/$file" ]; then
            log_info "Found: $file"
        else
            log_error "Missing: $file"
            ((errors++))
        fi
    done
    
    # Check build size
    if [ -d "$dist_dir" ]; then
        local size
        size=$(du -sh "$dist_dir" | cut -f1)
        log_info "  Build size: $size"
    fi
    
    # Check version file
    if [ -f "$dist_dir/.version" ]; then
        log_info "  Version: $(cat "$dist_dir/.version")"
    fi
    
    if [ $errors -gt 0 ]; then
        log_error "Verification failed with $errors error(s)"
        exit 1
    fi
    
    log_info ""
    log_info "ACA build summary:"
    log_info "  Source:      $ACA_DIR"
    log_info "  Output:      $dist_dir"
    log_info "  Version:     $(cat "$dist_dir/.version" 2>/dev/null || echo 'unknown')"
    log_info ""
    log_info "Next steps:"
    log_info "  1. Run 10-install_nginx.sh to deploy ACA with Nginx"
    log_info "  2. Access ACA at http://${NGINX_SERVER_NAME}/"
    log_info ""
    log_info "All verifications passed"
}

# -----------------------------------------------------------------------------
# Run Main
# -----------------------------------------------------------------------------
main "$@"
