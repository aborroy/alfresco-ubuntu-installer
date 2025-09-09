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
    
    # Verificar que Java está instalado
    if ! command_exists java; then
        log_error "Java is not installed. Please run 02-install_java.sh first"
        exit 1
    fi
    
    # Verificar versión de Java (Transform Service requiere Java 11+)
    local java_version=$(java -version 2>&1 | head -1 | sed 's/.*version "\([0-9]*\).*/\1/')
    if [ "$java_version" -lt 11 ]; then
        log_error "Java $java_version detected. Transform Service requires Java 11 or higher"
        exit 1
    fi
    log "✓ Java $java_version detected (compatible with Transform Service)"
    
    # Verificar que ActiveMQ está instalado
    if [ ! -d "/home/ubuntu/activemq" ]; then
        log_error "ActiveMQ is not installed. Please run 04-install_activemq.sh first"
        exit 1
    fi
    
    # Verificar que los archivos de descarga existen
    local downloads_dir="./downloads"
    if [ ! -d "$downloads_dir" ]; then
        log_error "Downloads directory not found. Please run 05-download_alfresco_resources.sh first"
        exit 1
    fi
    
    # Verificar archivo específico del Transform Service
    local transform_jar=$(find "$downloads_dir" -name "alfresco-transform-core-aio-*.jar" | head -1)
    if [ -z "$transform_jar" ] || [ ! -f "$transform_jar" ]; then
        log_error "Transform Service JAR not found in downloads directory"
        exit 1
    fi
    
    # Verificar que el archivo de versiones existe para obtener la versión correcta
    local versions_file="$downloads_dir/versions.txt"
    if [ ! -f "$versions_file" ]; then
        log_error "versions.txt not found. Please run 05-download_alfresco_resources.sh first"
        exit 1
    fi
    
    log "✓ All prerequisites verified"
    echo "$transform_jar|$versions_file"
}

# Función para instalar dependencias del sistema
install_system_dependencies() {
    log "Installing Transform Service system dependencies..."
    
    # Actualizar lista de paquetes
    sudo apt-get update
    
    # Instalar ImageMagick para transformaciones de imágenes
    log "Installing ImageMagick..."
    sudo apt install -y imagemagick
    
    # Verificar instalación de ImageMagick
    if command_exists convert; then
        local imagemagick_version=$(convert -version | head -1 | grep -o 'ImageMagick [0-9\.]*' || echo "ImageMagick installed")
        log "✓ $imagemagick_version installed"
    else
        log_error "ImageMagick installation failed"
        exit 1
    fi
    
    # Instalar LibreOffice para transformaciones de documentos
    log "Installing LibreOffice..."
    sudo apt install -y libreoffice
    
    # Verificar instalación de LibreOffice
    if command_exists libreoffice; then
        local libreoffice_version=$(libreoffice --version 2>/dev/null | head -1 || echo "LibreOffice installed")
        log "✓ $libreoffice_version installed"
    else
        log_error "LibreOffice installation failed"
        exit 1
    fi
    
    # Instalar ExifTool para metadatos
    log "Installing ExifTool..."
    sudo apt install -y exiftool
    
    # Verificar instalación de ExifTool
    if command_exists exiftool; then
        local exiftool_version=$(exiftool -ver 2>/dev/null || echo "unknown")
        log "✓ ExifTool $exiftool_version installed"
    else
        log_error "ExifTool installation failed"
        exit 1
    fi
    
    log "✓ All system dependencies installed successfully"
}

# Función para instalar PDF Renderer
install_pdf_renderer() {
    log "Installing Alfresco PDF Renderer..."
    
    # Obtener la última versión de PDF Renderer
    local pdf_renderer_version
    pdf_renderer_version=$(curl -s --connect-timeout 15 --max-time 30 \
        "https://nexus.alfresco.com/nexus/service/rest/repository/browse/releases/org/alfresco/alfresco-pdf-renderer/" 2>/dev/null | \
        sed -n 's/.*<a href="\([0-9]\+\.[0-9]\+\.[0-9]\+\)\/">.*/\1/p' | \
        sort -V | tail -n 1) || pdf_renderer_version="1.1"
    
    log "Using PDF Renderer version: $pdf_renderer_version"
    
    # Descargar PDF Renderer
    local pdf_renderer_url="https://nexus.alfresco.com/nexus/repository/releases/org/alfresco/alfresco-pdf-renderer/$pdf_renderer_version/alfresco-pdf-renderer-$pdf_renderer_version-linux.tgz"
    local temp_file="/tmp/alfresco-pdf-renderer-$pdf_renderer_version-linux.tgz"
    
    log "Downloading PDF Renderer..."
    if curl -L --connect-timeout 30 --max-time 120 -o "$temp_file" "$pdf_renderer_url"; then
        # Verificar que el archivo descargado no está vacío
        local file_size=$(stat -c%s "$temp_file" 2>/dev/null || stat -f%z "$temp_file" 2>/dev/null || echo "0")
        if [ "$file_size" -gt 1048576 ]; then  # > 1MB
            log "✓ PDF Renderer downloaded successfully ($file_size bytes)"
        else
            log_error "PDF Renderer download failed or file is too small"
            exit 1
        fi
    else
        log_error "Failed to download PDF Renderer"
        exit 1
    fi
    
    # Extraer PDF Renderer a /usr/bin
    log "Installing PDF Renderer to /usr/bin..."
    if sudo tar xf "$temp_file" -C /usr/bin; then
        log "✓ PDF Renderer extracted successfully"
    else
        log_error "Failed to extract PDF Renderer"
        exit 1
    fi
    
    # Verificar instalación
    if [ -f "/usr/bin/alfresco-pdf-renderer" ]; then
        sudo chmod +x /usr/bin/alfresco-pdf-renderer
        log "✓ PDF Renderer installed and configured"
    else
        log_error "PDF Renderer binary not found after installation"
        exit 1
    fi
    
    # Limpiar archivo temporal
    rm -f "$temp_file"
}

# Función para obtener la versión del Transform Service
get_transform_version() {
    local versions_file="$1"
    local transform_jar="$2"
    
    # Intentar obtener versión desde versions.txt
    local version=""
    if [ -f "$versions_file" ]; then
        version=$(grep "alfresco_transform_version=" "$versions_file" | cut -d'=' -f2 2>/dev/null || echo "")
    fi
    
    # Si no se encuentra en versions.txt, extraer del nombre del JAR
    if [ -z "$version" ]; then
        version=$(basename "$transform_jar" | sed 's/alfresco-transform-core-aio-\(.*\)\.jar/\1/')
    fi
    
    # Fallback a versión conocida
    if [ -z "$version" ] || [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        version="5.1.7"
        log "⚠️  Could not determine Transform version, using fallback: $version"
    else
        log "✓ Transform Service version: $version"
    fi
    
    echo "$version"
}

# Función para configurar el Transform Service
setup_transform_service() {
    local transform_jar="$1"
    local transform_version="$2"
    local transform_home="/home/ubuntu/transform"
    
    log "Setting up Transform Service..."
    
    # Crear directorio de instalación
    mkdir -p "$transform_home"
    
    # Crear backup si ya existe una instalación
    local jar_name="alfresco-transform-core-aio-$transform_version.jar"
    local target_jar="$transform_home/$jar_name"
    
    if [ -f "$target_jar" ]; then
        local backup_jar="${target_jar}.backup.$(date +%Y%m%d_%H%M%S)"
        log "Backing up existing Transform Service JAR to $(basename "$backup_jar")"
        mv "$target_jar" "$backup_jar"
    fi
    
    # Copiar JAR del Transform Service
    log "Installing Transform Service JAR..."
    cp "$transform_jar" "$target_jar"
    
    # Verificar que el JAR es válido
    if ! file "$target_jar" | grep -q "Java archive"; then
        log_error "Transform Service JAR appears to be invalid"
        exit 1
    fi
    
    # Configurar permisos
    chown -R ubuntu:ubuntu "$transform_home"
    chmod 644 "$target_jar"
    
    log "✓ Transform Service installed to $target_jar"
    echo "$target_jar"
}

# Función para crear configuración de aplicación
create_application_config() {
    local transform_home="/home/ubuntu/transform"
    local config_file="$transform_home/application.yml"
    
    log "Creating Transform Service configuration..."
    
    cat > "$config_file" << 'EOF'
# Transform Service Configuration
server:
  port: 8090
  
logging:
  level:
    org.alfresco.transform: INFO
    org.springframework: WARN
    org.apache.pdfbox: WARN
  pattern:
    file: "%d{yyyy-MM-dd HH:mm:ss} [%thread] %-5level %logger{36} - %msg%n"
  file:
    name: /home/ubuntu/transform/transform.log
    max-size: 100MB
    max-history: 10

management:
  endpoints:
    web:
      exposure:
        include: health,info,metrics,loggers
  endpoint:
    health:
      show-details: always

transform:
  core:
    aio:
      # ImageMagick configuration
      imagemagick:
        root: /usr/bin
        dyn: /usr/lib
        exe: convert
        coders: /usr/lib/ImageMagick-*/modules-Q16/coders
        config: /etc/ImageMagick-*
      
      # LibreOffice configuration  
      libreoffice:
        path: /usr/bin/libreoffice
        home: /usr/lib/libreoffice
        
      # PDF Renderer configuration
      pdfrenderer:
        exe: /usr/bin/alfresco-pdf-renderer
        
      # ExifTool configuration
      exiftool:
        exe: /usr/bin/exiftool

spring:
  application:
    name: transform-core-aio
    
# JVM configuration
server:
  tomcat:
    threads:
      max: 200
      min-spare: 10
EOF

    chown ubuntu:ubuntu "$config_file"
    log "✓ Transform Service configuration created"
}

# Función para crear el servicio systemd
create_systemd_service() {
    local transform_jar="$1"
    local transform_home="/home/ubuntu/transform"
    
    log "Creating Transform Service systemd service..."
    
    # Detectar JAVA_HOME
    local java_home="${JAVA_HOME:-$(dirname $(dirname $(readlink -f $(which java))))}"
    
    cat > /tmp/transform.service << EOF
[Unit]
Description=Alfresco Transform Service (Core AIO)
Documentation=https://docs.alfresco.com/transform-service/latest/
After=network.target activemq.service
Requires=activemq.service
Before=tomcat.service

[Service]
Type=simple
User=ubuntu
Group=ubuntu
RestartSec=15
Restart=always
RestartPreventExitStatus=0

WorkingDirectory=$transform_home

Environment="JAVA_HOME=$java_home"
Environment="LIBREOFFICE_HOME=/usr/lib/libreoffice"
Environment="IMAGEMAGICK_ROOT=/usr/bin"
Environment="IMAGEMAGICK_DYN=/usr/lib"
Environment="PDFRENDERER_EXE=/usr/bin/alfresco-pdf-renderer"
Environment="EXIFTOOL_EXE=/usr/bin/exiftool"

# JVM Memory settings
Environment="JAVA_OPTS=-Xms1024m -Xmx2048m -XX:+UseG1GC -XX:+UseStringDeduplication"

# Security settings  
Environment="JAVA_OPTS=\$JAVA_OPTS -Djava.awt.headless=true -Djava.security.egd=file:/dev/./urandom"

# Application configuration
Environment="JAVA_OPTS=\$JAVA_OPTS -Dspring.config.location=$transform_home/application.yml"
Environment="JAVA_OPTS=\$JAVA_OPTS -Dlogging.config=$transform_home/application.yml"

ExecStart=$java_home/bin/java \$JAVA_OPTS -jar $transform_jar
ExecStop=/bin/kill -15 \$MAINPID

StandardOutput=journal
StandardError=journal

# Security restrictions
PrivateTmp=yes
ProtectSystem=strict
ReadWritePaths=$transform_home /tmp
NoNewPrivileges=yes
ProtectKernelTunables=yes
ProtectControlGroups=yes
RestrictRealtime=yes

# Resource limits
LimitNOFILE=65536
LimitNPROC=32768

[Install]
WantedBy=multi-user.target
EOF

    sudo mv /tmp/transform.service /etc/systemd/system/transform.service
    sudo systemctl daemon-reload
    sudo systemctl enable transform
    
    log "✓ Transform Service systemd service created and enabled"
}

# Función para configurar logrotate
setup_logrotate() {
    local transform_home="/home/ubuntu/transform"
    
    log "Setting up log rotation for Transform Service..."
    
    cat << EOF | sudo tee /etc/logrotate.d/transform
$transform_home/*.log {
    daily
    missingok
    rotate 30
    compress
    delaycompress
    notifempty
    create 644 ubuntu ubuntu
    postrotate
        systemctl reload transform || true
    endscript
}
EOF
    
    log "✓ Transform Service log rotation configured"
}

# Función para verificar la instalación
verify_installation() {
    local transform_jar="$1"
    local transform_home="/home/ubuntu/transform"
    
    log "Verifying Transform Service installation..."
    
    # Verificar archivos críticos
    local critical_files=(
        "$transform_jar"
        "$transform_home/application.yml"
        "/usr/bin/convert"
        "/usr/bin/libreoffice"
        "/usr/bin/exiftool"
        "/usr/bin/alfresco-pdf-renderer"
    )
    
    for file in "${critical_files[@]}"; do
        if [ ! -f "$file" ] && [ ! -x "$file" ]; then
            log_error "Critical file missing or not executable: $file"
            exit 1
        fi
    done
    
    # Verificar que el JAR es ejecutable por Java
    if ! java -jar "$transform_jar" --help >/dev/null 2>&1; then
        # Algunos JAR no soportan --help, intentar versión
        if ! timeout 10 java -jar "$transform_jar" --version >/dev/null 2>&1; then
            log "⚠️  Could not verify JAR executability (this may be normal)"
        fi
    fi
    
    # Verificar permisos del directorio
    local owner=$(stat -c '%U' "$transform_home" 2>/dev/null || stat -f '%Su' "$transform_home" 2>/dev/null)
    if [ "$owner" != "ubuntu" ]; then
        log_error "Incorrect ownership of Transform directory"
        exit 1
    fi
    
    log "✓ Transform Service installation verified"
}

# Función principal
main() {
    log "=== Starting Alfresco Transform Service Installation ==="
    
    # Verificar que el usuario actual puede escribir en /home/ubuntu
    if [ ! -w "/home/ubuntu" ]; then
        log_error "Cannot write to /home/ubuntu directory. Please check permissions."
        exit 1
    fi
    
    # Verificar prerrequisitos y obtener información de archivos
    local prereq_info
    prereq_info=$(verify_prerequisites)
    local transform_jar=$(echo "$prereq_info" | cut -d'|' -f1)
    local versions_file=$(echo "$prereq_info" | cut -d'|' -f2)
    
    # Instalar dependencias del sistema
    install_system_dependencies
    
    # Instalar PDF Renderer
    install_pdf_renderer
    
    # Obtener versión del Transform Service
    local transform_version
    transform_version=$(get_transform_version "$versions_file" "$transform_jar")
    
    # Configurar Transform Service
    local installed_jar
    installed_jar=$(setup_transform_service "$transform_jar" "$transform_version")
    
    # Crear configuración de aplicación
    create_application_config
    
    # Crear servicio systemd
    create_systemd_service "$installed_jar"
    
    # Configurar logrotate
    setup_logrotate
    
    # Verificar instalación
    verify_installation "$installed_jar"
    
    # Mostrar resumen de instalación
    log "=== Transform Service Installation Summary ==="
    log "Transform Version: $transform_version"
    log "Installation Path: /home/ubuntu/transform"
    log "JAR File: $(basename "$installed_jar")"
    log "Configuration: /home/ubuntu/transform/application.yml"
    log "Service File: /etc/systemd/system/transform.service"
    log "Log File: /home/ubuntu/transform/transform.log"
    log "Port: 8090"
    
    log "=== System Dependencies ==="
    log "ImageMagick: $(which convert)"
    log "LibreOffice: $(which libreoffice)"
    log "ExifTool: $(which exiftool)"
    log "PDF Renderer: /usr/bin/alfresco-pdf-renderer"
    
    log "=== Service Management ==="
    log "Start Transform: sudo systemctl start transform"
    log "Stop Transform:  sudo systemctl stop transform"
    log "Status:          sudo systemctl status transform"
    log "Logs:            sudo journalctl -u transform -f"
    log "App Log:         tail -f /home/ubuntu/transform/transform.log"
    
    log "=== Access URLs ==="
    log "Health Check: http://localhost:8090/actuator/health"
    log "Metrics: http://localhost:8090/actuator/metrics"
    log "Transform API: http://localhost:8090/"
    
    log "=== Important Notes ==="
    log "• Transform Service is configured for Alfresco integration"
    log "• Memory settings: -Xms1024m -Xmx2048m (adjust if needed)"
    log "• All required transformation tools are installed"
    log "• Log rotation is configured to manage log file sizes"
    log "• Service will auto-start on boot after ActiveMQ"
    log "• PDF Renderer version: $(basename /usr/bin/alfresco-pdf-renderer 2>/dev/null || echo 'installed')"
    
    log "🎉 Alfresco Transform Service installation completed successfully!"
    
    # Test del servicio
    log "Testing Transform Service configuration..."
    if sudo systemctl start transform; then
        sleep 30
        if sudo systemctl is-active --quiet transform; then
            log "✅ Transform Service test successful"
            
            # Test de conectividad al health endpoint
            if command_exists curl; then
                log "Testing Transform Service health endpoint..."
                local health_check=0
                for i in {1..6}; do
                    if curl -f -s --connect-timeout 5 --max-time 10 "http://localhost:8090/actuator/health" >/dev/null 2>&1; then
                        log "✅ Transform Service health endpoint is accessible"
                        health_check=1
                        break
                    else
                        log "Attempt $i/6: Health endpoint not ready, waiting 10 seconds..."
                        sleep 10
                    fi
                done
                
                if [ $health_check -eq 0 ]; then
                    log "⚠️  Transform Service health endpoint test failed - may need more time to start"
                fi
            fi
            
            sudo systemctl stop transform
            log "Service stopped for final configuration"
        else
            log "⚠️  Transform Service test failed - check configuration"
            sudo systemctl status transform --no-pager || true
        fi
    else
        log "⚠️  Could not start Transform Service - will need troubleshooting"
    fi
}

# Ejecutar función principal
main "$@"