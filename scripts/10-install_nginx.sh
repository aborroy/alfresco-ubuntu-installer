#!/bin/bash
# =============================================================================
# Nginx Installation Script
# =============================================================================
# Installs and configures Nginx as a reverse proxy for Alfresco services
# and serves the Alfresco Content App (ACA).
#
# Prerequisites:
# - Run 00-generate-config.sh first to create configuration
# - Run 09-build_aca.sh to build ACA (optional but recommended)
# - Ubuntu 22.04 or 24.04
# - sudo privileges
#
# Usage:
#   bash scripts/10-install_nginx.sh
# =============================================================================

# Load common functions and configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
NGINX_SITES_AVAILABLE="/etc/nginx/sites-available"
NGINX_SITES_ENABLED="/etc/nginx/sites-enabled"
NGINX_CONF_NAME="alfresco"
WEB_ROOT="/var/www/alfresco-content-app"

# -----------------------------------------------------------------------------
# Main Installation
# -----------------------------------------------------------------------------
main() {
    log_step "Starting Nginx installation..."
    
    # Pre-flight checks
    check_root
    check_sudo
    load_config
    
    # Install Nginx
    install_nginx
    
    # Deploy ACA files
    deploy_aca
    
    # Configure Nginx
    create_nginx_config
    enable_site
    
    # Configure systemd (optional customization)
    configure_systemd
    
    # Enable and test
    enable_service
    test_configuration
    
    # Verify installation
    verify_installation
    
    log_info "Nginx installation completed successfully!"
}

# -----------------------------------------------------------------------------
# Install Nginx
# -----------------------------------------------------------------------------
install_nginx() {
    log_step "Installing Nginx..."
    
    if command -v nginx &> /dev/null; then
        log_info "Nginx is already installed"
        log_info "  Version: $(nginx -v 2>&1)"
        return 0
    fi
    
    log_info "Updating package list..."
    sudo apt-get update
    
    log_info "Installing Nginx..."
    sudo apt-get install -y nginx
    
    log_info "Nginx installed: $(nginx -v 2>&1)"
}

# -----------------------------------------------------------------------------
# Deploy ACA Files
# -----------------------------------------------------------------------------
deploy_aca() {
    log_step "Deploying Alfresco Content App..."
    
    local aca_dist="${ALFRESCO_HOME}/alfresco-content-app/dist/content-ce"
    
    # Create web root directory
    sudo mkdir -p "$WEB_ROOT"
    
    # Check if ACA build exists
    if [ -d "$aca_dist" ] && [ -f "$aca_dist/index.html" ]; then
        log_info "Copying ACA files from $aca_dist..."
        
        # Copy files (preserve permissions)
        sudo cp -r "$aca_dist/"* "$WEB_ROOT/"
        
        # Set ownership
        sudo chown -R www-data:www-data "$WEB_ROOT"
        
        log_info "ACA deployed to $WEB_ROOT"
        
        # Show version if available
        if [ -f "$WEB_ROOT/.version" ]; then
            log_info "  Version: $(cat "$WEB_ROOT/.version")"
        fi
    else
        log_warn "ACA build not found at $aca_dist"
        log_warn "Run 09-build_aca.sh first to build ACA"
        log_warn "Creating placeholder index.html..."
        
        # Create a placeholder page
        cat << 'EOF' | sudo tee "$WEB_ROOT/index.html" > /dev/null
<!DOCTYPE html>
<html>
<head>
    <title>Alfresco Content App</title>
    <style>
        body { font-family: Arial, sans-serif; text-align: center; padding: 50px; }
        h1 { color: #333; }
        p { color: #666; }
        a { color: #2196F3; }
    </style>
</head>
<body>
    <h1>Alfresco Content App</h1>
    <p>ACA is not yet deployed. Please run <code>09-build_aca.sh</code> and then re-run <code>10-install_nginx.sh</code>.</p>
    <p>In the meantime, you can access:</p>
    <ul style="list-style: none;">
        <li><a href="/alfresco/">Alfresco Repository</a></li>
        <li><a href="/share/">Alfresco Share</a></li>
    </ul>
</body>
</html>
EOF
        sudo chown www-data:www-data "$WEB_ROOT/index.html"
    fi
}

# -----------------------------------------------------------------------------
# Create Nginx Configuration
# -----------------------------------------------------------------------------
create_nginx_config() {
    log_step "Creating Nginx configuration..."
    
    local config_file="${NGINX_SITES_AVAILABLE}/${NGINX_CONF_NAME}"
    
    # Backup existing config
    if [ -f "$config_file" ]; then
        backup_file "$config_file"
    fi
    
    # Determine backend URL
    local backend_url="http://${ALFRESCO_HOST}:${TOMCAT_HTTP_PORT}"
    
    log_info "Creating Nginx site configuration..."
    log_info "  Server name: ${NGINX_SERVER_NAME}"
    log_info "  Listen port: ${NGINX_HTTP_PORT}"
    log_info "  Backend URL: ${backend_url}"
    
    cat << EOF | sudo tee "$config_file" > /dev/null
# =============================================================================
# Alfresco Nginx Configuration
# =============================================================================
# Generated by Alfresco installer on $(date)
#
# This configuration:
# - Serves ACA static files from ${WEB_ROOT}
# - Proxies /alfresco/ to Alfresco Repository
# - Proxies /share/ to Alfresco Share
# - Supports WebSocket connections
# - Allows unlimited file uploads
# =============================================================================

# Upstream definitions for load balancing (future use)
upstream alfresco_backend {
    server ${ALFRESCO_HOST}:${TOMCAT_HTTP_PORT};
    keepalive 32;
}

server {
    listen ${NGINX_HTTP_PORT};
    server_name ${NGINX_SERVER_NAME};

    # ---------------------------------------------------------------------
    # General Settings
    # ---------------------------------------------------------------------
    
    # Disable upload size limit (Alfresco handles its own limits)
    client_max_body_size 0;
    
    # Increase timeouts for large file operations
    proxy_connect_timeout 300;
    proxy_send_timeout 300;
    proxy_read_timeout 300;
    send_timeout 300;
    
    # Gzip compression for better performance
    gzip on;
    gzip_types text/plain text/css application/json application/javascript text/xml application/xml;
    gzip_min_length 1000;

    # ---------------------------------------------------------------------
    # Logging
    # ---------------------------------------------------------------------
    access_log /var/log/nginx/alfresco_access.log;
    error_log /var/log/nginx/alfresco_error.log;

    # ---------------------------------------------------------------------
    # Proxy Settings (applied to all proxy locations)
    # ---------------------------------------------------------------------
    proxy_http_version 1.1;
    proxy_set_header Host \$host:\$server_port;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header X-Forwarded-Host \$host;
    proxy_set_header X-Forwarded-Port \$server_port;
    
    # WebSocket support
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "upgrade";
    
    # Cookie handling
    proxy_pass_request_headers on;
    proxy_pass_header Set-Cookie;
    
    # Buffering settings
    proxy_buffering off;
    proxy_request_buffering off;
    
    # Error handling
    proxy_next_upstream error timeout invalid_header http_500 http_502 http_503 http_504;

    # ---------------------------------------------------------------------
    # Static Files - Alfresco Content App
    # ---------------------------------------------------------------------
    root ${WEB_ROOT};
    index index.html;

    location / {
        # Try to serve static files, fall back to index.html for SPA routing
        try_files \$uri \$uri/ /index.html;
        
        # Cache static assets
        location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot)$ {
            expires 1y;
            add_header Cache-Control "public, immutable";
        }
    }

    # ---------------------------------------------------------------------
    # Alfresco Repository Proxy
    # ---------------------------------------------------------------------
    location /alfresco/ {
        proxy_pass http://alfresco_backend;
        
        # CORS headers (if needed for API access)
        add_header Access-Control-Allow-Origin * always;
        add_header Access-Control-Allow-Methods "GET, POST, PUT, DELETE, OPTIONS" always;
        add_header Access-Control-Allow-Headers "Authorization, Content-Type, X-Requested-With" always;
        
        # Handle OPTIONS preflight requests
        if (\$request_method = 'OPTIONS') {
            add_header Access-Control-Allow-Origin *;
            add_header Access-Control-Allow-Methods "GET, POST, PUT, DELETE, OPTIONS";
            add_header Access-Control-Allow-Headers "Authorization, Content-Type, X-Requested-With";
            add_header Content-Length 0;
            add_header Content-Type text/plain;
            return 204;
        }
    }

    # ---------------------------------------------------------------------
    # Alfresco Share Proxy
    # ---------------------------------------------------------------------
    location /share/ {
        proxy_pass http://alfresco_backend;
    }

    # ---------------------------------------------------------------------
    # WebDAV Support (optional)
    # ---------------------------------------------------------------------
    location /webdav/ {
        proxy_pass http://alfresco_backend;
        
        # WebDAV-specific settings
        proxy_set_header Destination \$http_destination;
        proxy_pass_request_body on;
    }

    # ---------------------------------------------------------------------
    # Health Check Endpoint
    # ---------------------------------------------------------------------
    location /nginx-health {
        access_log off;
        return 200 "healthy\\n";
        add_header Content-Type text/plain;
    }
}
EOF

    log_info "Nginx configuration created: $config_file"
}

# -----------------------------------------------------------------------------
# Enable Site
# -----------------------------------------------------------------------------
enable_site() {
    log_step "Enabling Nginx site..."
    
    local config_file="${NGINX_SITES_AVAILABLE}/${NGINX_CONF_NAME}"
    local enabled_link="${NGINX_SITES_ENABLED}/${NGINX_CONF_NAME}"
    local default_site="${NGINX_SITES_ENABLED}/default"
    
    # Remove default site if it exists (conflicts with our config)
    if [ -L "$default_site" ] || [ -f "$default_site" ]; then
        log_info "Removing default site..."
        sudo rm -f "$default_site"
    fi
    
    # Create symlink if not exists
    if [ -L "$enabled_link" ]; then
        log_info "Site already enabled"
    else
        log_info "Creating symlink..."
        sudo ln -sf "$config_file" "$enabled_link"
    fi
    
    log_info "Site enabled: $NGINX_CONF_NAME"
}

# -----------------------------------------------------------------------------
# Configure Systemd
# -----------------------------------------------------------------------------
configure_systemd() {
    log_step "Configuring Nginx systemd service..."
    
    # The default Nginx systemd service is usually fine
    # We only customize if we need specific dependencies
    
    local override_dir="/etc/systemd/system/nginx.service.d"
    local override_file="$override_dir/alfresco.conf"
    
    sudo mkdir -p "$override_dir"
    
    cat << EOF | sudo tee "$override_file" > /dev/null
# Alfresco-specific Nginx overrides
[Unit]
# Start after Solr to ensure all backend services are ready
After=network.target solr.service
# Don't hard-require Solr (Nginx can start without it)
Wants=solr.service

[Service]
# Increase file descriptor limit
LimitNOFILE=65536
EOF

    sudo chmod 644 "$override_file"
    
    # Reload systemd
    log_info "Reloading systemd daemon..."
    sudo systemctl daemon-reload
    
    log_info "Systemd configuration updated"
}

# -----------------------------------------------------------------------------
# Enable Service
# -----------------------------------------------------------------------------
enable_service() {
    log_step "Enabling Nginx service..."
    
    sudo systemctl enable nginx
    
    log_info "Nginx service enabled on boot"
}

# -----------------------------------------------------------------------------
# Test Configuration
# -----------------------------------------------------------------------------
test_configuration() {
    log_step "Testing Nginx configuration..."
    
    if sudo nginx -t; then
        log_info "Nginx configuration is valid"
    else
        log_error "Nginx configuration test failed"
        exit 1
    fi
}

# -----------------------------------------------------------------------------
# Verify Installation
# -----------------------------------------------------------------------------
verify_installation() {
    log_step "Verifying Nginx installation..."
    
    local errors=0
    
    # Check Nginx is installed
    if command -v nginx &> /dev/null; then
        log_info "Nginx is installed"
    else
        log_error "Nginx is not installed"
        ((errors++))
    fi
    
    # Check configuration file exists
    if [ -f "${NGINX_SITES_AVAILABLE}/${NGINX_CONF_NAME}" ]; then
        log_info "Site configuration exists"
    else
        log_error "Site configuration missing"
        ((errors++))
    fi
    
    # Check site is enabled
    if [ -L "${NGINX_SITES_ENABLED}/${NGINX_CONF_NAME}" ]; then
        log_info "Site is enabled"
    else
        log_error "Site is not enabled"
        ((errors++))
    fi
    
    # Check web root exists
    if [ -d "$WEB_ROOT" ]; then
        log_info "Web root exists: $WEB_ROOT"
    else
        log_error "Web root missing: $WEB_ROOT"
        ((errors++))
    fi
    
    # Check ACA is deployed
    if [ -f "$WEB_ROOT/index.html" ]; then
        log_info "index.html exists"
    else
        log_error "index.html missing"
        ((errors++))
    fi
    
    # Check service is enabled
    if systemctl is-enabled --quiet nginx 2>/dev/null; then
        log_info "Nginx service is enabled"
    else
        log_error "Nginx service is not enabled"
        ((errors++))
    fi
    
    if [ $errors -gt 0 ]; then
        log_error "Verification failed with $errors error(s)"
        exit 1
    fi
    
    log_info ""
    log_info "Nginx installation summary:"
    log_info "  Config file:  ${NGINX_SITES_AVAILABLE}/${NGINX_CONF_NAME}"
    log_info "  Web root:     ${WEB_ROOT}"
    log_info "  Listen port:  ${NGINX_HTTP_PORT}"
    log_info "  Server name:  ${NGINX_SERVER_NAME}"
    log_info ""
    log_info "URLs (after starting all services):"
    log_info "  ACA:       http://${NGINX_SERVER_NAME}:${NGINX_HTTP_PORT}/"
    log_info "  Alfresco:  http://${NGINX_SERVER_NAME}:${NGINX_HTTP_PORT}/alfresco/"
    log_info "  Share:     http://${NGINX_SERVER_NAME}:${NGINX_HTTP_PORT}/share/"
    log_info "  Health:    http://${NGINX_SERVER_NAME}:${NGINX_HTTP_PORT}/nginx-health"
    log_info ""
    log_info "All verifications passed"
}

# -----------------------------------------------------------------------------
# Run Main
# -----------------------------------------------------------------------------
main "$@"
