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
    
    # Verificar versión de Java (Solr requiere Java 11+)
    local java_version=$(java -version 2>&1 | head -1 | sed 's/.*version "\([0-9]*\).*/\1/')
    if [ "$java_version" -lt 11 ]; then
        log_error "Java $java_version detected. Solr requires Java 11 or higher"
        exit 1
    fi
    log "✓ Java $java_version detected (compatible with Solr)"
    
    # Verificar que Tomcat está instalado
    if [ ! -d "/home/ubuntu/tomcat" ]; then
        log_error "Tomcat is not installed. Please run 03-install_tomcat.sh first"
        exit 1
    fi
    
    # Verificar que Alfresco está instalado
    if [ ! -f "/home/ubuntu/tomcat/shared/classes/alfresco-global.properties" ]; then
        log_error "Alfresco is not installed. Please run 06-install_alfresco.sh first"
        exit 1
    fi
    
    # Verificar que los archivos de descarga existen
    local downloads_dir="./downloads"
    if [ ! -d "$downloads_dir" ]; then
        log_error "Downloads directory not found. Please run 05-download_alfresco_resources.sh first"
        exit 1
    fi
    
    # Verificar archivo específico de Solr
    local solr_zip=$(find "$downloads_dir" -name "alfresco-search-services-*.zip" | head -1)
    if [ -z "$solr_zip" ] || [ ! -f "$solr_zip" ]; then
        log_error "Alfresco Search Services distribution not found in downloads directory"
        exit 1
    fi
    
    log "✓ All prerequisites verified"
    echo "$solr_zip"
}

# Función para extraer y verificar la distribución de Solr
extract_solr_distribution() {
    local solr_zip="$1"
    local temp_dir="/tmp/solr-extract"
    
    log "Extracting Alfresco Search Services..."
    
    # Limpiar directorio temporal si existe
    [ -d "$temp_dir" ] && rm -rf "$temp_dir"
    mkdir -p "$temp_dir"
    
    # Extraer el ZIP
    if ! unzip -q "$solr_zip" -d "$temp_dir"; then
        log_error "Failed to extract Solr distribution ZIP"
        exit 1
    fi
    
    # Encontrar el directorio extraído
    local extracted_dir=$(find "$temp_dir" -type d -name "alfresco-search-services*" | head -1)
    if [ -z "$extracted_dir" ] || [ ! -d "$extracted_dir" ]; then
        log_error "Could not find extracted Solr directory"
        exit 1
    fi
    
    # Verificar que contiene los componentes esperados
    if [ ! -d "$extracted_dir/solr" ] || [ ! -d "$extracted_dir/solrhome" ]; then
        log_error "Invalid Solr distribution - missing required directories"
        exit 1
    fi
    
    log "✓ Solr distribution extracted and verified"
    echo "$extracted_dir"
}

# Función para instalar Solr
install_solr() {
    local extracted_dir="$1"
    local solr_home="/home/ubuntu/alfresco-search-services"
    
    log "Installing Alfresco Search Services..."
    
    # Crear backup si ya existe
    if [ -d "$solr_home" ]; then
        local backup_dir="${solr_home}.backup.$(date +%Y%m%d_%H%M%S)"
        log "Backing up existing installation to $backup_dir"
        mv "$solr_home" "$backup_dir"
    fi
    
    # Mover la instalación extraída
    mv "$extracted_dir" "$solr_home"
    
    # Verificar la instalación
    if [ ! -f "$solr_home/solr/bin/solr" ]; then
        log_error "Solr binary not found after installation"
        exit 1
    fi
    
    # Configurar permisos
    chown -R ubuntu:ubuntu "$solr_home"
    chmod +x "$solr_home/solr/bin/solr"
    
    log "✓ Solr installed to $solr_home"
}

# Función para configurar Solr para Alfresco
configure_solr() {
    local solr_home="/home/ubuntu/alfresco-search-services"
    
    log "Configuring Solr for Alfresco..."
    
    # Leer configuración de Alfresco
    local alfresco_props="/home/ubuntu/tomcat/shared/classes/alfresco-global.properties"
    local alfresco_host="localhost"
    local alfresco_port="8080"
    local solr_secret="secret"
    
    # Extraer configuraciones si existen
    if [ -f "$alfresco_props" ]; then
        alfresco_host=$(grep "^alfresco.host=" "$alfresco_props" | cut -d'=' -f2 || echo "localhost")
        alfresco_port=$(grep "^alfresco.port=" "$alfresco_props" | cut -d'=' -f2 || echo "8080")
        solr_secret=$(grep "^solr.sharedSecret=" "$alfresco_props" | cut -d'=' -f2 || echo "secret")
    fi
    
    log "Alfresco connection: $alfresco_host:$alfresco_port"
    log "Solr shared secret: $solr_secret"
    
    # Configurar cores de Solr
    configure_solr_cores "$solr_home" "$alfresco_host" "$alfresco_port" "$solr_secret"
    
    # Configurar logging de Solr
    configure_solr_logging "$solr_home"
    
    # Configurar solr.in.sh
    configure_solr_startup "$solr_home"
    
    log "✓ Solr configuration completed"
}

# Función para configurar los cores de Solr
configure_solr_cores() {
    local solr_home="$1"
    local alfresco_host="$2"
    local alfresco_port="$3"
    local solr_secret="$4"
    
    log "Configuring Solr cores..."
    
    # Configurar core alfresco
    local alfresco_core_props="$solr_home/solrhome/alfresco/conf/solrcore.properties"
    if [ -f "$alfresco_core_props" ]; then
        cp "$alfresco_core_props" "${alfresco_core_props}.backup"
        
        # Actualizar configuraciones
        sed -i "s|^alfresco.host=.*|alfresco.host=$alfresco_host|" "$alfresco_core_props"
        sed -i "s|^alfresco.port=.*|alfresco.port=$alfresco_port|" "$alfresco_core_props"
        sed -i "s|^alfresco.secureComms=.*|alfresco.secureComms=secret|" "$alfresco_core_props"
        
        # Añadir configuraciones si no existen
        if ! grep -q "^alfresco.secureComms.secret=" "$alfresco_core_props"; then
            echo "alfresco.secureComms.secret=$solr_secret" >> "$alfresco_core_props"
        else
            sed -i "s|^alfresco.secureComms.secret=.*|alfresco.secureComms.secret=$solr_secret|" "$alfresco_core_props"
        fi
        
        log "✓ Alfresco core configured"
    else
        log_error "Alfresco core properties file not found"
        exit 1
    fi
    
    # Configurar core archive
    local archive_core_props="$solr_home/solrhome/archive/conf/solrcore.properties"
    if [ -f "$archive_core_props" ]; then
        cp "$archive_core_props" "${archive_core_props}.backup"
        
        # Actualizar configuraciones
        sed -i "s|^alfresco.host=.*|alfresco.host=$alfresco_host|" "$archive_core_props"
        sed -i "s|^alfresco.port=.*|alfresco.port=$alfresco_port|" "$archive_core_props"
        sed -i "s|^alfresco.secureComms=.*|alfresco.secureComms=secret|" "$archive_core_props"
        
        # Añadir configuraciones si no existen
        if ! grep -q "^alfresco.secureComms.secret=" "$archive_core_props"; then
            echo "alfresco.secureComms.secret=$solr_secret" >> "$archive_core_props"
        else
            sed -i "s|^alfresco.secureComms.secret=.*|alfresco.secureComms.secret=$solr_secret|" "$archive_core_props"
        fi
        
        log "✓ Archive core configured"
    else
        log_error "Archive core properties file not found"
        exit 1
    fi
    
    # Configurar templates si existen
    for template_dir in "$solr_home/solrhome/templates"/*; do
        if [ -d "$template_dir" ]; then
            local template_props="$template_dir/conf/solrcore.properties"
            if [ -f "$template_props" ]; then
                cp "$template_props" "${template_props}.backup"
                sed -i "s|^alfresco.host=.*|alfresco.host=$alfresco_host|" "$template_props"
                sed -i "s|^alfresco.port=.*|alfresco.port=$alfresco_port|" "$template_props"
                sed -i "s|^alfresco.secureComms=.*|alfresco.secureComms=secret|" "$template_props"
                
                if ! grep -q "^alfresco.secureComms.secret=" "$template_props"; then
                    echo "alfresco.secureComms.secret=$solr_secret" >> "$template_props"
                else
                    sed -i "s|^alfresco.secureComms.secret=.*|alfresco.secureComms.secret=$solr_secret|" "$template_props"
                fi
                
                log "✓ Template $(basename "$template_dir") configured"
            fi
        fi
    done
}

# Función para configurar logging de Solr
configure_solr_logging() {
    local solr_home="$1"
    local log_config="$solr_home/logs/log4j2.xml"
    
    log "Configuring Solr logging..."
    
    # Crear directorio de logs si no existe
    mkdir -p "$solr_home/logs"
    
    # Crear configuración de logging si no existe
    if [ ! -f "$log_config" ]; then
        cat > "$log_config" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<Configuration>
  <Appenders>
    <Console name="STDOUT" target="SYSTEM_OUT">
      <PatternLayout>
        <Pattern>%d{yyyy-MM-dd HH:mm:ss.SSS} %-5p (%t) [%c{1.}] %m%n</Pattern>
      </PatternLayout>
    </Console>
    
    <RollingFile name="RollingFile" fileName="${sys:solr.log.dir}/solr.log"
                 filePattern="${sys:solr.log.dir}/solr.log.%i">
      <PatternLayout>
        <Pattern>%d{yyyy-MM-dd HH:mm:ss.SSS} %-5p (%t) [%c{1.}] %m%n</Pattern>
      </PatternLayout>
      <Policies>
        <SizeBasedTriggeringPolicy size="100 MB"/>
      </Policies>
      <DefaultRolloverStrategy max="10"/>
    </RollingFile>
  </Appenders>
  
  <Loggers>
    <Logger name="org.apache.solr" level="WARN"/>
    <Logger name="org.eclipse.jetty" level="WARN"/>
    <Logger name="org.alfresco.solr" level="INFO"/>
    
    <Root level="WARN">
      <AppenderRef ref="RollingFile"/>
      <AppenderRef ref="STDOUT"/>
    </Root>
  </Loggers>
</Configuration>
EOF
        log "✓ Solr logging configuration created"
    fi
    
    chown -R ubuntu:ubuntu "$solr_home/logs"
}

# Función para configurar el script de inicio de Solr
configure_solr_startup() {
    local solr_home="$1"
    local solr_in_sh="$solr_home/solr/bin/solr.in.sh"
    
    log "Configuring Solr startup script..."
    
    # Crear backup del archivo original
    if [ -f "$solr_in_sh" ]; then
        cp "$solr_in_sh" "${solr_in_sh}.backup"
    fi
    
    # Configurar solr.in.sh
    cat > "$solr_in_sh" << 'EOF'
#!/usr/bin/env bash

# Increase Java heap as needed to support your indexing / query needs
SOLR_HEAP="2g"

# Set the ZooKeeper connection string if using SolrCloud
#ZK_HOST=""

# Set the ZooKeeper client timeout (for SolrCloud mode)
#ZK_CLIENT_TIMEOUT="15000"

# By default the start script uses UTC; override the timezone if needed
#SOLR_TIMEZONE="UTC"

# Set to true to activate the JMX RMI connector to allow remote JMX client applications
# to monitor the JVM hosting Solr; set to "false" to disable that behavior
# (false is recommended in production environments)
ENABLE_REMOTE_JMX_OPTS="false"

# The script will use SOLR_PORT+10000 for the RMI_PORT or you can set it here
#RMI_PORT=18983

# Anything you add to the SOLR_OPTS variable will be included in the java
# start command line as JVM parameters
# For example, to add -Dcom.sun.management.jmxremote.port=18983 you could use:
SOLR_OPTS="$SOLR_OPTS -Dsolr.autoSoftCommit.maxTime=10000"
SOLR_OPTS="$SOLR_OPTS -Dsolr.autoCommit.maxTime=15000"
SOLR_OPTS="$SOLR_OPTS -Dsolr.log.dir=$SOLR_HOME/../logs"

# Location where the bin/solr script will save PID files for running instances
# If not set, the script will create PID files in $SOLR_TIP/bin
SOLR_PID_DIR="$SOLR_HOME/../logs"

# Path to a directory for Solr to store cores and their data. By default, Solr will use server/solr
# If solr.xml is not stored in ZooKeeper, this directory needs to contain solr.xml
SOLR_HOME="$SOLR_HOME/../solrhome"

# Solr provides a default Log4J configuration properties file in server/resources
# however, you may want to customize the log settings and file appender location
# so you can point the script to use a different log4j2.xml file
LOG4J_PROPS="$SOLR_HOME/../logs/log4j2.xml"

# Changes the logging level. Valid values: ALL, TRACE, DEBUG, INFO, WARN, ERROR, FATAL, OFF. Default is INFO
# This is an alternative to changing the rootLogger in log4j2.xml
SOLR_LOG_LEVEL="WARN"

# Enables/disables Solr log rotation before starting Solr. Default is false
#SOLR_LOG_PRESTART_ROTATION=false

# Location where Solr should write logs to. Absolute or relative to solr start dir
SOLR_LOGS_DIR="$SOLR_HOME/../logs"

# Enables jetty request log for all requests
#SOLR_REQUESTLOG_ENABLED=false

# Sets the port Solr binds to, default is 8983
SOLR_PORT="8983"

# Restrict access to solr admin functionality to a specific host
#SOLR_JETTY_HOST="127.0.0.1"

# Alfresco specific configurations
SOLR_OPTS="$SOLR_OPTS -Dalfresco.secureComms=secret"
SOLR_OPTS="$SOLR_OPTS -Dalfresco.secureComms.secret=secret"
SOLR_OPTS="$SOLR_OPTS -Dcreate.alfresco.defaults=alfresco,archive"

# Security configurations
SOLR_OPTS="$SOLR_OPTS -Djava.security.manager=default"
SOLR_OPTS="$SOLR_OPTS -Djava.security.policy=$SOLR_HOME/../solr/server/etc/security.policy"

# GC tuning for Alfresco
GC_TUNE="-XX:+UseG1GC -XX:+PerfDisableSharedMem -XX:+ParallelRefProcEnabled -XX:MaxGCPauseMillis=250 -XX:+UseLargePages -XX:+AlwaysPreTouch"

# Set the ZooKeeper chroot path under which all Solr nodes will live in ZooKeeper
#ZK_CHROOT="/solr"

# GC Logging
# GC_LOG_OPTS="-Xlog:gc*:gc.log:time,tags"

# Expert: JVM startup flags
#SOLR_JAVA_MEM="-Xms2g -Xmx2g"
EOF

    chmod +x "$solr_in_sh"
    chown ubuntu:ubuntu "$solr_in_sh"
    
    log "✓ Solr startup script configured"
}

# Función para crear el servicio systemd
create_systemd_service() {
    local solr_home="/home/ubuntu/alfresco-search-services"
    
    log "Creating Solr systemd service..."
    
    # Detectar JAVA_HOME
    local java_home="${JAVA_HOME:-$(dirname $(dirname $(readlink -f $(which java))))}"
    
    cat > /tmp/solr.service << EOF
[Unit]
Description=Apache Solr Search Services for Alfresco
Documentation=https://docs.alfresco.com/search-services/latest/
After=network.target tomcat.service
Requires=tomcat.service
Before=nginx.service

[Service]
Type=forking
User=ubuntu
Group=ubuntu
RestartSec=10
Restart=always

Environment="JAVA_HOME=$java_home"
Environment="SOLR_PID_DIR=$solr_home/logs"
Environment="SOLR_HOME=$solr_home/solrhome"

# Solr startup command with Alfresco-specific parameters
ExecStart=$solr_home/solr/bin/solr start -a "-Dcreate.alfresco.defaults=alfresco,archive -Dalfresco.secureComms=secret -Dalfresco.secureComms.secret=secret"
ExecStop=$solr_home/solr/bin/solr stop

# PID file location
PIDFile=$solr_home/logs/solr-8983.pid

# Security settings
PrivateTmp=yes
ProtectSystem=strict
ReadWritePaths=$solr_home /home/ubuntu/alf_data
NoNewPrivileges=yes
ProtectKernelTunables=yes
ProtectControlGroups=yes
RestrictRealtime=yes

# Resource limits
LimitNOFILE=65536
LimitNPROC=65536

[Install]
WantedBy=multi-user.target
EOF

    sudo mv /tmp/solr.service /etc/systemd/system/solr.service
    sudo systemctl daemon-reload
    sudo systemctl enable solr
    
    log "✓ Solr systemd service created and enabled"
}

# Función para configurar logrotate
setup_logrotate() {
    local solr_home="/home/ubuntu/alfresco-search-services"
    
    log "Setting up log rotation for Solr..."
    
    cat << EOF | sudo tee /etc/logrotate.d/solr
$solr_home/logs/*.log {
    daily
    missingok
    rotate 30
    compress
    delaycompress
    notifempty
    create 644 ubuntu ubuntu
    postrotate
        systemctl reload solr || true
    endscript
}
EOF
    
    log "✓ Solr log rotation configured"
}

# Función para verificar la instalación
verify_installation() {
    local solr_home="/home/ubuntu/alfresco-search-services"
    
    log "Verifying Solr installation..."
    
    # Verificar archivos críticos
    local critical_files=(
        "$solr_home/solr/bin/solr"
        "$solr_home/solrhome/alfresco/conf/solrcore.properties"
        "$solr_home/solrhome/archive/conf/solrcore.properties"
        "$solr_home/solr/bin/solr.in.sh"
    )
    
    for file in "${critical_files[@]}"; do
        if [ ! -f "$file" ]; then
            log_error "Critical file missing: $file"
            exit 1
        fi
    done
    
    # Verificar permisos
    if [ ! -x "$solr_home/solr/bin/solr" ]; then
        log_error "Solr binary is not executable"
        exit 1
    fi
    
    # Verificar que el usuario ubuntu es propietario
    local owner=$(stat -c '%U' "$solr_home" 2>/dev/null || stat -f '%Su' "$solr_home" 2>/dev/null)
    if [ "$owner" != "ubuntu" ]; then
        log_error "Incorrect ownership of Solr directory"
        exit 1
    fi
    
    log "✓ Solr installation verified"
}

# Función principal
main() {
    log "=== Starting Alfresco Search Services (Solr) Installation ==="
    
    # Verificar que el usuario actual puede escribir en /home/ubuntu
    if [ ! -w "/home/ubuntu" ]; then
        log_error "Cannot write to /home/ubuntu directory. Please check permissions."
        exit 1
    fi
    
    # Instalar unzip si no está disponible
    if ! command_exists unzip; then
        log "Installing unzip..."
        sudo apt update && sudo apt install -y unzip
    fi
    
    # Verificar prerrequisitos y obtener ruta del ZIP
    local solr_zip
    solr_zip=$(verify_prerequisites)
    
    # Extraer distribución de Solr
    local extracted_dir
    extracted_dir=$(extract_solr_distribution "$solr_zip")
    
    # Instalar Solr
    install_solr "$extracted_dir"
    
    # Configurar Solr
    configure_solr
    
    # Crear servicio systemd
    create_systemd_service
    
    # Configurar logrotate
    setup_logrotate
    
    # Verificar instalación
    verify_installation
    
    # Limpiar archivos temporales
    log "Cleaning up temporary files..."
    rm -rf /tmp/solr-extract
    
    # Mostrar resumen de instalación
    log "=== Solr Installation Summary ==="
    log "Installation Path: /home/ubuntu/alfresco-search-services"
    log "Solr Home: /home/ubuntu/alfresco-search-services/solrhome"
    log "Service File: /etc/systemd/system/solr.service"
    log "Logs Directory: /home/ubuntu/alfresco-search-services/logs"
    log "Cores: alfresco, archive"
    log "Port: 8983"
    
    log "=== Service Management ==="
    log "Start Solr: sudo systemctl start solr"
    log "Stop Solr:  sudo systemctl stop solr"
    log "Status:     sudo systemctl status solr"
    log "Logs:       sudo journalctl -u solr -f"
    log "Solr Log:   tail -f /home/ubuntu/alfresco-search-services/logs/solr.log"
    
    log "=== Access URLs ==="
    log "Solr Admin: http://localhost:8983/solr/"
    log "Alfresco Core: http://localhost:8983/solr/alfresco/"
    log "Archive Core: http://localhost:8983/solr/archive/"
    
    log "=== Important Notes ==="
    log "• Solr is configured with secure communications (secret-based)"
    log "• Cores are configured to connect to Alfresco on localhost:8080"
    log "• Log rotation is configured to manage log file sizes"
    log "• Service will auto-start on boot after Tomcat"
    log "• Memory setting: 2GB heap (adjust in solr.in.sh if needed)"
    
    log "🎉 Alfresco Search Services (Solr) installation completed successfully!"
    
    # Test del servicio
    log "Testing Solr service configuration..."
    if sudo systemctl start solr; then
        sleep 20
        if sudo systemctl is-active --quiet solr; then
            log "✅ Solr service test successful"
            
            # Test de conectividad a la interfaz admin
            if command_exists curl; then
                log "Testing Solr admin interface..."
                if curl -f -s --connect-timeout 10 --max-time 10 "http://localhost:8983/solr/" >/dev/null 2>&1; then
                    log "✅ Solr admin interface is accessible"
                else
                    log "⚠️  Solr admin interface test failed - may need more time to start"
                fi
            fi
            
            sudo systemctl stop solr
            log "Service stopped for final configuration"
        else
            log "⚠️  Solr service test failed - check configuration"
            sudo systemctl status solr --no-pager || true
        fi
    else
        log "⚠️  Could not start Solr service - will need troubleshooting"
    fi
}

# Ejecutar función principal
main "$@"