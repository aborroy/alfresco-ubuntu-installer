#!/bin/bash

set -e

# Función para logging con timestamp
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# Función para logging de errores
log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1" >&2
}

# Función para verificar si un comando existe
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Función para verificar prerrequisitos
verify_prerequisites() {
    log "Verifying prerequisites..."
    
    # Verificar que Alfresco Content App está construida
    local aca_dist_path="/home/ubuntu/alfresco-content-app/dist"
    if [ ! -d "$aca_dist_path" ]; then
        log_error "Alfresco Content App build not found. Please run 09-build_aca.sh first"
        exit 1
    fi
    
    # Verificar que contiene archivos
    if [ ! -f "$aca_dist_path/index.html" ]; then
        log_error "Alfresco Content App build appears incomplete - index.html not found"
        exit 1
    fi
    
    # Verificar que Tomcat está instalado
    if [ ! -d "/home/ubuntu/tomcat" ]; then
        log_error "Tomcat is not installed. Please run 03-install_tomcat.sh first"
        exit 1
    fi
    
    # Verificar que Alfresco está configurado
    if [ ! -f "/home/ubuntu/tomcat/shared/classes/alfresco-global.properties" ]; then
        log_error "Alfresco is not configured. Please run 06-install_alfresco.sh first"
        exit 1
    fi
    
    log "✓ All prerequisites verified"
    echo "$aca_dist_path"
}

# Función para leer configuraciones de Alfresco
read_alfresco_config() {
    local alfresco_props="/home/ubuntu/tomcat/shared/classes/alfresco-global.properties"
    
    # Valores por defecto
    local alfresco_host="localhost"
    local alfresco_port="8080"
    local share_host="localhost"
    local share_port="8080"
    
    # Leer configuraciones si existen
    if [ -f "$alfresco_props" ]; then
        alfresco_host=$(grep "^alfresco.host=" "$alfresco_props" | cut -d'=' -f2 2>/dev/null || echo "localhost")
        alfresco_port=$(grep "^alfresco.port=" "$alfresco_props" | cut -d'=' -f2 2>/dev/null || echo "8080")
        share_host=$(grep "^share.host=" "$alfresco_props" | cut -d'=' -f2 2>/dev/null || echo "localhost")
        share_port=$(grep "^share.port=" "$alfresco_props" | cut -d'=' -f2 2>/dev/null || echo "8080")
    fi
    
    log "Alfresco configuration detected:"
    log "  Alfresco: $alfresco_host:$alfresco_port"
    log "  Share: $share_host:$share_port"
    
    echo "$alfresco_host|$alfresco_port|$share_host|$share_port"
}

# Función para instalar Nginx
install_nginx() {
    log "Installing and configuring Nginx..."
    
    # Actualizar lista de paquetes
    sudo apt update
    
    # Instalar Nginx
    if ! sudo apt install -y nginx; then
        log_error "Failed to install Nginx"
        exit 1
    fi
    
    # Verificar instalación
    if ! command_exists nginx; then
        log_error "Nginx installation verification failed"
        exit 1
    fi
    
    local nginx_version=$(nginx -v 2>&1 | cut -d'/' -f2 | cut -d' ' -f1)
    log "✓ Nginx $nginx_version installed successfully"
    
    # Detener Nginx para configuración
    sudo systemctl stop nginx 2>/dev/null || true
}

# Función para crear backup de configuración existente
backup_nginx_config() {
    log "Creating backup of existing Nginx configuration..."
    
    local backup_dir="/etc/nginx/backup-$(date +%Y%m%d_%H%M%S)"
    sudo mkdir -p "$backup_dir"
    
    # Backup de configuraciones importantes
    [ -f "/etc/nginx/nginx.conf" ] && sudo cp "/etc/nginx/nginx.conf" "$backup_dir/"
    [ -d "/etc/nginx/sites-available" ] && sudo cp -r "/etc/nginx/sites-available" "$backup_dir/"
    [ -d "/etc/nginx/sites-enabled" ] && sudo cp -r "/etc/nginx/sites-enabled" "$backup_dir/"
    
    log "✓ Backup created at: $backup_dir"
}

# Función para configurar estructura de directorios web
setup_web_directories() {
    local aca_dist_path="$1"
    
    log "Setting up web directory structure..."
    
    # Crear directorio web para ACA
    local web_root="/var/www/alfresco-content-app"
    sudo mkdir -p "$web_root"
    
    # Copiar archivos de ACA
    log "Deploying Alfresco Content App files..."
    sudo cp -r "$aca_dist_path"/* "$web_root/"
    
    # Verificar que los archivos se copiaron correctamente
    if [ ! -f "$web_root/index.html" ]; then
        log_error "Failed to copy ACA files to web directory"
        exit 1
    fi
    
    # Configurar permisos
    sudo chown -R www-data:www-data "$web_root"
    sudo chmod -R 755 "$web_root"
    
    # Crear directorio para logs personalizados
    sudo mkdir -p /var/log/nginx/alfresco
    sudo chown www-data:www-data /var/log/nginx/alfresco
    
    local file_count=$(find "$web_root" -type f | wc -l)
    local dir_size=$(du -sh "$web_root" 2>/dev/null | cut -f1)
    log "✓ Deployed $file_count files ($dir_size) to $web_root"
}

# Función para configurar Nginx principal
configure_nginx_main() {
    log "Configuring main Nginx settings..."
    
    # Crear configuración principal optimizada
    cat << 'EOF' | sudo tee /etc/nginx/nginx.conf > /dev/null
user www-data;
worker_processes auto;
pid /run/nginx.pid;
include /etc/nginx/modules-enabled/*.conf;

events {
    worker_connections 1024;
    use epoll;
    multi_accept on;
}

http {
    ##
    # Basic Settings
    ##
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    types_hash_max_size 2048;
    server_tokens off;
    
    # Server names hash bucket size
    server_names_hash_bucket_size 64;
    
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    
    ##
    # Logging Settings
    ##
    log_format main '$remote_addr - $remote_user [$time_local] "$request" '
                    '$status $body_bytes_sent "$http_referer" '
                    '"$http_user_agent" "$http_x_forwarded_for" '
                    'rt=$request_time uct="$upstream_connect_time" '
                    'uht="$upstream_header_time" urt="$upstream_response_time"';
    
    access_log /var/log/nginx/access.log main;
    error_log /var/log/nginx/error.log warn;
    
    ##
    # Gzip Settings
    ##
    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_buffers 16 8k;
    gzip_http_version 1.1;
    gzip_types
        text/plain
        text/css
        text/xml
        text/javascript
        application/json
        application/javascript
        application/xml+rss
        application/atom+xml
        image/svg+xml;
    
    ##
    # Client Upload Settings
    ##
    client_max_body_size 100M;
    client_body_buffer_size 128k;
    client_header_buffer_size 4k;
    large_client_header_buffers 4 32k;
    
    ##
    # Proxy Settings
    ##
    proxy_buffering on;
    proxy_buffer_size 4k;
    proxy_buffers 8 4k;
    proxy_busy_buffers_size 8k;
    proxy_temp_file_write_size 8k;
    proxy_connect_timeout 60s;
    proxy_send_timeout 60s;
    proxy_read_timeout 300s;
    
    ##
    # Rate Limiting
    ##
    limit_req_zone $binary_remote_addr zone=api:10m rate=10r/s;
    limit_req_zone $binary_remote_addr zone=login:10m rate=5r/m;
    
    ##
    # Security Headers
    ##
    add_header X-Frame-Options SAMEORIGIN always;
    add_header X-Content-Type-Options nosniff always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    
    ##
    # Virtual Host Configs
    ##
    include /etc/nginx/conf.d/*.conf;
    include /etc/nginx/sites-enabled/*;
}
EOF
    
    log "✓ Main Nginx configuration created"
}

# Función para crear configuración del sitio Alfresco
create_alfresco_site_config() {
    local config_data="$1"
    
    IFS='|' read -r alfresco_host alfresco_port share_host share_port <<< "$config_data"
    
    log "Creating Alfresco site configuration..."
    
    cat << EOF | sudo tee /etc/nginx/sites-available/alfresco-content-app > /dev/null
##
# Alfresco Content Services + ACA Configuration
##
upstream alfresco_backend {
    server $alfresco_host:$alfresco_port max_fails=3 fail_timeout=30s;
    keepalive 32;
}

upstream share_backend {
    server $share_host:$share_port max_fails=3 fail_timeout=30s;
    keepalive 32;
}

##
# Main Server Configuration
##
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _ localhost;
    
    # Security headers
    add_header X-Frame-Options SAMEORIGIN always;
    add_header X-Content-Type-Options nosniff always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    
    # Logging
    access_log /var/log/nginx/alfresco/access.log main;
    error_log /var/log/nginx/alfresco/error.log warn;
    
    # Root directory for ACA
    root /var/www/alfresco-content-app;
    index index.html;
    
    # Gzip compression for static files
    location ~* \.(css|js|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot)$ {
        expires 1y;
        add_header Cache-Control "public, immutable";
        add_header Vary Accept-Encoding;
        gzip_static on;
    }
    
    # Health check endpoint
    location /health {
        access_log off;
        return 200 "healthy\\n";
        add_header Content-Type text/plain;
    }
    
    # Nginx status (internal only)
    location /nginx_status {
        stub_status on;
        access_log off;
        allow 127.0.0.1;
        allow ::1;
        deny all;
    }
    
    ##
    # Alfresco Repository Proxy
    ##
    location /alfresco/ {
        # Rate limiting for API calls
        limit_req zone=api burst=20 nodelay;
        
        # Proxy headers
        proxy_set_header Host \$host:\$server_port;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-Port \$server_port;
        
        # Proxy settings
        proxy_pass http://alfresco_backend;
        proxy_redirect off;
        proxy_buffering on;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        
        # Timeouts
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 300s;
        
        # Error handling
        proxy_next_upstream error timeout invalid_header http_500 http_502 http_503 http_504;
        proxy_next_upstream_tries 3;
        proxy_next_upstream_timeout 60s;
    }
    
    ##
    # Alfresco Share Proxy
    ##
    location /share/ {
        # Rate limiting
        limit_req zone=api burst=15 nodelay;
        
        # Proxy headers
        proxy_set_header Host \$host:\$server_port;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-Port \$server_port;
        
        # Proxy settings
        proxy_pass http://share_backend;
        proxy_redirect off;
        proxy_buffering on;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        
        # Timeouts
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 300s;
        
        # Error handling
        proxy_next_upstream error timeout invalid_header http_500 http_502 http_503 http_504;
        proxy_next_upstream_tries 3;
        proxy_next_upstream_timeout 60s;
    }
    
    ##
    # Special handling for login endpoints
    ##
    location ~ ^/(alfresco|share)/.*/(login|authenticate) {
        limit_req zone=login burst=5 nodelay;
        
        proxy_set_header Host \$host:\$server_port;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        
        proxy_pass http://alfresco_backend;
        proxy_redirect off;
    }
    
    ##
    # ACA Single Page Application
    ##
    location / {
        try_files \$uri \$uri/ /index.html;
        
        # Cache policy for HTML files
        location ~* \.html$ {
            expires -1;
            add_header Cache-Control "no-cache, no-store, must-revalidate";
            add_header Pragma "no-cache";
        }
    }
    
    ##
    # Error pages
    ##
    error_page 404 /404.html;
    error_page 500 502 503 504 /50x.html;
    
    location = /404.html {
        root /var/www/alfresco-content-app;
        internal;
    }
    
    location = /50x.html {
        root /var/www/alfresco-content-app;
        internal;
    }
}

##
# Optional HTTPS Configuration (commented out)
##
# server {
#     listen 443 ssl http2;
#     listen [::]:443 ssl http2;
#     server_name localhost;
#     
#     ssl_certificate /etc/nginx/ssl/nginx.crt;
#     ssl_certificate_key /etc/nginx/ssl/nginx.key;
#     ssl_protocols TLSv1.2 TLSv1.3;
#     ssl_ciphers ECDHE-RSA-AES256-GCM-SHA512:DHE-RSA-AES256-GCM-SHA512:ECDHE-RSA-AES256-GCM-SHA384:DHE-RSA-AES256-GCM-SHA384;
#     ssl_prefer_server_ciphers off;
#     
#     # Include the same location blocks as HTTP server
# }
EOF
    
    log "✓ Alfresco site configuration created"
}

# Función para habilitar el sitio y configurar Nginx
enable_site_and_configure() {
    log "Enabling Alfresco site and configuring Nginx..."
    
    # Deshabilitar sitio por defecto
    sudo rm -f /etc/nginx/sites-enabled/default
    
    # Habilitar sitio de Alfresco
    sudo ln -sf /etc/nginx/sites-available/alfresco-content-app /etc/nginx/sites-enabled/
    
    # Crear directorio para includes personalizados
    sudo mkdir -p /etc/nginx/conf.d
    
    # Verificar configuración de Nginx
    log "Testing Nginx configuration..."
    if ! sudo nginx -t; then
        log_error "Nginx configuration test failed"
        exit 1
    fi
    
    log "✓ Nginx configuration test passed"
}

# Función para crear servicio systemd personalizado
create_custom_systemd_service() {
    log "Creating custom Nginx systemd service..."
    
    cat << 'EOF' | sudo tee /etc/systemd/system/nginx.service > /dev/null
[Unit]
Description=A high performance web server and a reverse proxy server
Documentation=man:nginx(8)
After=network.target remote-fs.target nss-lookup.target solr.service
Requires=solr.service
Wants=tomcat.service

[Service]
Type=forking
PIDFile=/run/nginx.pid
ExecStartPre=/usr/sbin/nginx -t -q -g 'daemon on; master_process on;'
ExecStart=/usr/sbin/nginx -g 'daemon on; master_process on;'
ExecReload=/usr/sbin/nginx -g 'daemon on; master_process on;' -s reload
ExecStop=/bin/kill -s QUIT $MAINPID
PrivateTmp=true
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
    
    sudo systemctl daemon-reload
    sudo systemctl enable nginx
    
    log "✓ Custom Nginx systemd service created and enabled"
}

# Función para configurar logrotate
setup_logrotate() {
    log "Setting up log rotation for Nginx..."
    
    cat << 'EOF' | sudo tee /etc/logrotate.d/nginx > /dev/null
/var/log/nginx/*.log
/var/log/nginx/alfresco/*.log {
    daily
    missingok
    rotate 52
    compress
    delaycompress
    notifempty
    create 644 www-data adm
    sharedscripts
    prerotate
        if [ -d /etc/logrotate.d/httpd-prerotate ]; then \
            run-parts /etc/logrotate.d/httpd-prerotate; \
        fi
    endscript
    postrotate
        invoke-rc.d nginx rotate >/dev/null 2>&1 || true
    endscript
}
EOF
    
    log "✓ Nginx log rotation configured"
}

# Función para configurar firewall básico
configure_firewall() {
    log "Configuring basic firewall rules..."
    
    # Verificar si ufw está disponible
    if command_exists ufw; then
        # Permitir HTTP y HTTPS
        sudo ufw allow 80/tcp comment 'Nginx HTTP'
        sudo ufw allow 443/tcp comment 'Nginx HTTPS'
        
        log "✓ Firewall rules configured (ports 80, 443 allowed)"
    else
        log "⚠️  UFW not available, skipping firewall configuration"
    fi
}

# Función para verificar la instalación
verify_installation() {
    log "Verifying Nginx installation and configuration..."
    
    # Verificar archivos críticos
    local critical_files=(
        "/etc/nginx/nginx.conf"
        "/etc/nginx/sites-available/alfresco-content-app"
        "/etc/nginx/sites-enabled/alfresco-content-app"
        "/var/www/alfresco-content-app/index.html"
    )
    
    for file in "${critical_files[@]}"; do
        if [ ! -f "$file" ]; then
            log_error "Critical file missing: $file"
            exit 1
        fi
    done
    
    # Verificar configuración de Nginx
    if ! sudo nginx -t >/dev/null 2>&1; then
        log_error "Nginx configuration is invalid"
        exit 1
    fi
    
    # Verificar permisos
    if [ ! -r "/var/www/alfresco-content-app/index.html" ]; then
        log_error "Web files are not readable"
        exit 1
    fi
    
    log "✓ Nginx installation verified"
}

# Función principal
main() {
    log "=== Starting Nginx Installation and Configuration ==="
    
    # Verificar que el usuario actual tiene permisos sudo
    if ! sudo -n true 2>/dev/null; then
        log_error "This script requires sudo privileges"
        exit 1
    fi
    
    # Verificar prerrequisitos
    local aca_dist_path
    aca_dist_path=$(verify_prerequisites)
    
    # Leer configuración de Alfresco
    local config_data
    config_data=$(read_alfresco_config)
    
    # Instalar Nginx
    install_nginx
    
    # Crear backup de configuración existente
    backup_nginx_config
    
    # Configurar estructura de directorios web
    setup_web_directories "$aca_dist_path"
    
    # Configurar Nginx principal
    configure_nginx_main
    
    # Crear configuración del sitio
    create_alfresco_site_config "$config_data"
    
    # Habilitar sitio y configurar
    enable_site_and_configure
    
    # Crear servicio systemd personalizado
    create_custom_systemd_service
    
    # Configurar logrotate
    setup_logrotate
    
    # Configurar firewall básico
    configure_firewall
    
    # Verificar instalación
    verify_installation
    
    # Mostrar resumen de instalación
    log "=== Nginx Installation Summary ==="
    log "Document Root: /var/www/alfresco-content-app"
    log "Configuration: /etc/nginx/sites-available/alfresco-content-app"
    log "Log Directory: /var/log/nginx/alfresco/"
    log "Service File: /etc/systemd/system/nginx.service"
    
    log "=== URL Mappings ==="
    log "ACA Frontend: http://localhost/"
    log "Alfresco Repository: http://localhost/alfresco/"
    log "Alfresco Share: http://localhost/share/"
    log "Health Check: http://localhost/health"
    log "Nginx Status: http://localhost/nginx_status (localhost only)"
    
    log "=== Service Management ==="
    log "Start Nginx: sudo systemctl start nginx"
    log "Stop Nginx:  sudo systemctl stop nginx"
    log "Reload:      sudo systemctl reload nginx"
    log "Status:      sudo systemctl status nginx"
    log "Test Config: sudo nginx -t"
    log "Logs:        sudo tail -f /var/log/nginx/alfresco/access.log"
    
    log "=== Important Notes ==="
    log "• Nginx is configured as reverse proxy for Alfresco and Share"
    log "• ACA is served as static files with SPA routing support"
    log "• Rate limiting is enabled for API and login endpoints"
    log "• Log rotation is configured for all Nginx logs"
    log "• Service dependencies ensure proper startup order"
    log "• Security headers are configured for enhanced protection"
    
    log "🎉 Nginx installation and configuration completed successfully!"
    
    # Test del servicio
    log "Testing Nginx service configuration..."
    if sudo systemctl start nginx; then
        sleep 5
        if sudo systemctl is-active --quiet nginx; then
            log "✅ Nginx service test successful"
            
            # Test de conectividad básico
            if command_exists curl; then
                log "Testing web server connectivity..."
                if curl -f -s --connect-timeout 5 --max-time 10 "http://localhost/health" >/dev/null 2>&1; then
                    log "✅ Web server health check successful"
                else
                    log "⚠️  Web server connectivity test failed - may need backend services"
                fi
                
                # Test del frontend
                if curl -f -s --connect-timeout 5 --max-time 10 "http://localhost/" >/dev/null 2>&1; then
                    log "✅ Frontend (ACA) is accessible"
                else
                    log "⚠️  Frontend accessibility test failed"
                fi
            fi
            
            sudo systemctl stop nginx
            log "Service stopped for final configuration"
        else
            log "⚠️  Nginx service test failed - check configuration"
            sudo systemctl status nginx --no-pager || true
        fi
    else
        log "⚠️  Could not start Nginx service - will need troubleshooting"
    fi
}

# Ejecutar función principal
main "$@"