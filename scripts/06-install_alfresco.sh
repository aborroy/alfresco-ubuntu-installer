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
    
    # Verificar que Tomcat está instalado
    if [ ! -d "/home/ubuntu/tomcat" ]; then
        log_error "Tomcat is not installed. Please run 03-install_tomcat.sh first"
        exit 1
    fi
    
    # Verificar que PostgreSQL está disponible
    if ! command_exists psql; then
        log_error "PostgreSQL is not installed. Please run 01-install_postgres.sh first"
        exit 1
    fi
    
    # Verificar que los archivos de descarga existen
    local downloads_dir="./downloads"
    if [ ! -d "$downloads_dir" ]; then
        log_error "Downloads directory not found. Please run 05-download_alfresco_resources.sh first"
        exit 1
    fi
    
    # Verificar archivos específicos
    local content_zip=$(find "$downloads_dir" -name "alfresco-content-services-community-distribution-*.zip" | head -1)
    if [ -z "$content_zip" ] || [ ! -f "$content_zip" ]; then
        log_error "Alfresco content services distribution not found in downloads directory"
        exit 1
    fi
    
    log "✓ All prerequisites verified"
    echo "$content_zip"
}

# Función para crear backup de configuraciones existentes
create_backup() {
    local backup_dir="/home/ubuntu/alfresco-backup-$(date +%Y%m%d_%H%M%S)"
    log "Creating backup of existing configurations..."
    
    mkdir -p "$backup_dir"
    
    # Backup de configuraciones existentes si existen
    [ -d "/home/ubuntu/tomcat/shared" ] && cp -r "/home/ubuntu/tomcat/shared" "$backup_dir/" 2>/dev/null || true
    [ -d "/home/ubuntu/alf_data" ] && cp -r "/home/ubuntu/alf_data" "$backup_dir/" 2>/dev/null || true
    [ -d "/home/ubuntu/keystore" ] && cp -r "/home/ubuntu/keystore" "$backup_dir/" 2>/dev/null || true
    
    log "✓ Backup created at: $backup_dir"
}

# Función para configurar directorios de Tomcat
setup_tomcat_directories() {
    log "Setting up Tomcat directories for Alfresco..."
    
    # Crear directorios necesarios
    mkdir -p /home/ubuntu/tomcat/shared/classes
    mkdir -p /home/ubuntu/tomcat/shared/lib
    mkdir -p /home/ubuntu/tomcat/conf/Catalina/localhost
    
    # Verificar y configurar catalina.properties
    local catalina_props="/home/ubuntu/tomcat/conf/catalina.properties"
    if [ -f "$catalina_props" ]; then
        # Crear backup
        cp "$catalina_props" "${catalina_props}.backup.$(date +%Y%m%d_%H%M%S)"
        
        # Configurar shared loader si no está ya configurado
        if grep -q "^shared.loader=$" "$catalina_props"; then
            sed -i 's|^shared.loader=$|shared.loader=${catalina.base}/shared/classes,${catalina.base}/shared/lib/*.jar|' "$catalina_props"
            log "✓ Configured shared.loader in catalina.properties"
        elif ! grep -q "shared.loader.*shared/classes" "$catalina_props"; then
            echo "shared.loader=\${catalina.base}/shared/classes,\${catalina.base}/shared/lib/*.jar" >> "$catalina_props"
            log "✓ Added shared.loader to catalina.properties"
        else
            log "✓ shared.loader already configured in catalina.properties"
        fi
    else
        log_error "catalina.properties not found at $catalina_props"
        exit 1
    fi
    
    # Configurar permisos
    chown -R ubuntu:ubuntu /home/ubuntu/tomcat/shared
    chown -R ubuntu:ubuntu /home/ubuntu/tomcat/conf/Catalina
    
    log "✓ Tomcat directories configured"
}

# Función para extraer y procesar el ZIP de Alfresco
extract_alfresco_distribution() {
    local content_zip="$1"
    local temp_dir="/tmp/alfresco-extract"
    
    log "Extracting Alfresco distribution..."
    
    # Limpiar directorio temporal si existe
    [ -d "$temp_dir" ] && rm -rf "$temp_dir"
    mkdir -p "$temp_dir"
    
    # Extraer el ZIP
    if ! unzip -q "$content_zip" -d "$temp_dir"; then
        log_error "Failed to extract Alfresco distribution ZIP"
        exit 1
    fi
    
    # Encontrar el directorio extraído
    local extracted_dir=$(find "$temp_dir" -type d -name "*alfresco*" | head -1)
    if [ -z "$extracted_dir" ] || [ ! -d "$extracted_dir" ]; then
        log_error "Could not find extracted Alfresco directory"
        exit 1
    fi
    
    log "✓ Alfresco distribution extracted to: $extracted_dir"
    echo "$extracted_dir"
}

# Función para instalar componentes de Alfresco
install_alfresco_components() {
    local alfresco_dir="$1"
    
    log "Installing Alfresco components..."
    
    # Verificar estructura del directorio extraído
    local web_server_dir="$alfresco_dir/web-server"
    if [ ! -d "$web_server_dir" ]; then
        log_error "web-server directory not found in Alfresco distribution"
        exit 1
    fi
    
    # Copiar JDBC driver de PostgreSQL
    log "Installing PostgreSQL JDBC driver..."
    local jdbc_jar=$(find "$web_server_dir/lib" -name "postgresql-*.jar" | head -1)
    if [ -n "$jdbc_jar" ] && [ -f "$jdbc_jar" ]; then
        cp "$jdbc_jar" /home/ubuntu/tomcat/shared/lib/
        log "✓ PostgreSQL JDBC driver installed"
    else
        log_error "PostgreSQL JDBC driver not found"
        exit 1
    fi
    
    # Copiar configuraciones de contexto
    log "Installing context configurations..."
    if [ -d "$web_server_dir/conf/Catalina/localhost" ]; then
        cp "$web_server_dir/conf/Catalina/localhost"/* /home/ubuntu/tomcat/conf/Catalina/localhost/ 2>/dev/null || true
        log "✓ Context configurations installed"
    fi
    
    # Instalar aplicaciones web
    log "Installing web applications..."
    if [ -d "$web_server_dir/webapps" ]; then
        cp "$web_server_dir/webapps"/* /home/ubuntu/tomcat/webapps/ 2>/dev/null || true
        log "✓ Web applications installed"
    else
        log_error "webapps directory not found"
        exit 1
    fi
    
    # Copiar configuraciones compartidas
    log "Installing shared configurations..."
    if [ -d "$web_server_dir/shared/classes" ]; then
        cp -r "$web_server_dir/shared/classes"/* /home/ubuntu/tomcat/shared/classes/ 2>/dev/null || true
        log "✓ Shared configurations installed"
    fi
    
    # Instalar keystore
    log "Installing keystore..."
    if [ -d "$alfresco_dir/keystore" ]; then
        mkdir -p /home/ubuntu/keystore
        cp -r "$alfresco_dir/keystore"/* /home/ubuntu/keystore/ 2>/dev/null || true
        chown -R ubuntu:ubuntu /home/ubuntu/keystore
        log "✓ Keystore installed"
    else
        log_error "keystore directory not found"
        exit 1
    fi
    
    # Crear directorio de datos de Alfresco
    log "Creating Alfresco data directory..."
    mkdir -p /home/ubuntu/alf_data
    chown -R ubuntu:ubuntu /home/ubuntu/alf_data
    log "✓ Alfresco data directory created"
}

# Función para obtener versiones de los componentes descargados
get_component_versions() {
    local versions_file="./downloads/versions.txt"
    
    # Valores por defecto
    local transform_version="5.1.7"
    
    # Leer del archivo de versiones si existe
    if [ -f "$versions_file" ]; then
        transform_version=$(grep "alfresco_transform_version=" "$versions_file" | cut -d'=' -f2 || echo "5.1.7")
    fi
    
    echo "$transform_version"
}

# Función para crear configuración de alfresco-global.properties
create_alfresco_global_properties() {
    local transform_version="$1"
    local props_file="/home/ubuntu/tomcat/shared/classes/alfresco-global.properties"
    
    log "Creating alfresco-global.properties..."
    
    # Crear backup si el archivo ya existe
    [ -f "$props_file" ] && cp "$props_file" "${props_file}.backup.$(date +%Y%m%d_%H%M%S)"
    
    # Detectar configuraciones del sistema
    local db_host="localhost"
    local db_port="5432"
    local db_name="alfresco"
    local db_user="alfresco"
    local db_password="alfresco"
    
    # Verificar conectividad a PostgreSQL
    if ! PGPASSWORD="$db_password" psql -h "$db_host" -p "$db_port" -U "$db_user" -d "$db_name" -c "SELECT 1;" >/dev/null 2>&1; then
        log "⚠️  Warning: Cannot connect to PostgreSQL database. Please verify database configuration."
    fi
    
    cat > "$props_file" << EOF
#
# Alfresco Global Properties Configuration
# Generated on: $(date '+%Y-%m-%d %H:%M:%S')
#

#
# Custom content and index data location
#
dir.root=/home/ubuntu/alf_data
dir.keystore=/home/ubuntu/keystore/

#
# Database connection properties
#
db.username=$db_user
db.password=$db_password
db.driver=org.postgresql.Driver
db.url=jdbc:postgresql://$db_host:$db_port/$db_name
db.pool.initial=10
db.pool.max=100
db.pool.validate.query=SELECT 1

#
# Database schema management
#
db.schema.update=true
db.schema.stopAfterSchemaBootstrap=false

#
# Solr Configuration
#
solr.secureComms=secret
solr.sharedSecret=secret
solr.host=localhost
solr.port=8983
solr.port.ssl=8984
index.subsystem.name=solr6
solr.backup.alfresco.remoteBackupLocation=\${dir.root}/solrBackup/alfresco
solr.backup.archive.remoteBackupLocation=\${dir.root}/solrBackup/archive

# 
# Transform Configuration
#
localTransform.core-aio.url=http://localhost:8090/
transform.service.enabled=true
local.transform.service.enabled=true
legacy.transform.service.enabled=false

#
# Events Configuration (ActiveMQ)
#
messaging.broker.url=failover:(nio://localhost:61616)?timeout=3000&jms.useCompression=true
messaging.subsystem.autoStart=true

#
# URL Generation Parameters
#
alfresco.context=alfresco
alfresco.host=localhost
alfresco.port=8080
alfresco.protocol=http
share.context=share
share.host=localhost
share.port=8080
share.protocol=http

#
# Content Store Configuration
#
dir.contentstore=\${dir.root}/contentstore
dir.contentstore.deleted=\${dir.root}/contentstore.deleted

#
# Audit Configuration
#
audit.enabled=true
audit.alfresco-access.enabled=true

#
# System Performance Configuration
#
system.usages.enabled=true
system.thumbnail.generate=true
content.transformer.retryOn.different.mimetype=true

#
# CSRF Configuration
#
csrf.filter.enabled=true
csrf.filter.origin=http://localhost:8080
csrf.filter.referer=http://localhost:8080/.*

#
# Email Configuration (Outbound)
#
mail.host=localhost
mail.port=25
mail.protocol=smtp
mail.encoding=UTF-8

#
# Logging Configuration
#
log4j.appender.File.File=\${catalina.base}/logs/alfresco.log

#
# Security Configuration
#
authentication.chain=alfrescoNtlm1:alfrescoNtlm
authentication.ticket.useSingleTicketPerUser=true
authentication.protection.enabled=true

#
# Cache Configuration
#
cache.cluster.type=local

#
# System Configuration
#
system.workflow.engine.jbpm.enabled=false
system.workflow.engine.activiti.enabled=true

#
# Metadata Extraction Configuration
#
content.metadataExtracter.default.timeoutMs=20000
content.transformer.timeout.default=120000

#
# Additional Security Settings
#
security.anyDenyDenies=false
security.enforce.FTP.root=false
EOF

    # Configurar permisos
    chown ubuntu:ubuntu "$props_file"
    chmod 640 "$props_file"
    
    log "✓ alfresco-global.properties created"
}

# Función para instalar AMPs (Alfresco Module Packages)
install_amps() {
    local alfresco_dir="$1"
    
    log "Installing Alfresco Module Packages (AMPs)..."
    
    # Crear directorios para AMPs
    mkdir -p /home/ubuntu/amps
    mkdir -p /home/ubuntu/bin
    
    # Copiar AMPs si existen
    if [ -d "$alfresco_dir/amps" ]; then
        cp -r "$alfresco_dir/amps"/* /home/ubuntu/amps/ 2>/dev/null || true
        log "✓ AMPs copied to /home/ubuntu/amps"
    fi
    
    # Copiar herramientas de instalación
    if [ -d "$alfresco_dir/bin" ]; then
        cp -r "$alfresco_dir/bin"/* /home/ubuntu/bin/ 2>/dev/null || true
        chmod +x /home/ubuntu/bin/* 2>/dev/null || true
        log "✓ Installation tools copied to /home/ubuntu/bin"
    fi
    
    # Verificar que existe el MMT (Module Management Tool)
    local mmt_jar="/home/ubuntu/bin/alfresco-mmt.jar"
    if [ ! -f "$mmt_jar" ]; then
        log "⚠️  Warning: alfresco-mmt.jar not found. AMPs installation skipped."
        return 0
    fi
    
    # Instalar AMPs en alfresco.war
    local alfresco_war="/home/ubuntu/tomcat/webapps/alfresco.war"
    if [ -f "$alfresco_war" ] && [ -d "/home/ubuntu/amps" ] && [ "$(ls -A /home/ubuntu/amps 2>/dev/null)" ]; then
        log "Installing AMPs into alfresco.war..."
        
        # Asegurar que Java está disponible
        if command_exists java; then
            java -jar "$mmt_jar" install /home/ubuntu/amps "$alfresco_war" -directory -force -verbose
            
            # Listar AMPs instalados
            log "Listing installed AMPs:"
            java -jar "$mmt_jar" list "$alfresco_war" || true
            
            log "✓ AMPs installed successfully"
        else
            log_error "Java not available for AMP installation"
            exit 1
        fi
    else
        log "⚠️  No AMPs to install or alfresco.war not found"
    fi
    
    # Configurar permisos
    chown -R ubuntu:ubuntu /home/ubuntu/amps
    chown -R ubuntu:ubuntu /home/ubuntu/bin
}

# Función para configurar logging
configure_logging() {
    log "Configuring application logging..."
    
    # Extraer y configurar WAR files para logging personalizado
    local webapps_dir="/home/ubuntu/tomcat/webapps"
    
    # Configurar logging para Alfresco
    if [ -f "$webapps_dir/alfresco.war" ]; then
        local alfresco_webapp_dir="$webapps_dir/alfresco"
        mkdir -p "$alfresco_webapp_dir"
        
        # Extraer WAR si el directorio no existe o está vacío
        if [ ! -d "$alfresco_webapp_dir/WEB-INF" ]; then
            log "Extracting alfresco.war for configuration..."
            unzip -q "$webapps_dir/alfresco.war" -d "$alfresco_webapp_dir"
        fi
        
        # Configurar log4j2.properties para Alfresco
        local alfresco_log_props="$alfresco_webapp_dir/WEB-INF/classes/log4j2.properties"
        if [ -f "$alfresco_log_props" ]; then
            cp "$alfresco_log_props" "${alfresco_log_props}.backup"
            sed -i 's|^appender\.rolling\.fileName=.*alfresco\.log|appender.rolling.fileName=/home/ubuntu/tomcat/logs/alfresco.log|' "$alfresco_log_props"
            log "✓ Alfresco logging configured"
        fi
    fi
    
    # Configurar logging para Share
    if [ -f "$webapps_dir/share.war" ]; then
        local share_webapp_dir="$webapps_dir/share"
        mkdir -p "$share_webapp_dir"
        
        # Extraer WAR si el directorio no existe o está vacío
        if [ ! -d "$share_webapp_dir/WEB-INF" ]; then
            log "Extracting share.war for configuration..."
            unzip -q "$webapps_dir/share.war" -d "$share_webapp_dir"
        fi
        
        # Configurar log4j2.properties para Share
        local share_log_props="$share_webapp_dir/WEB-INF/classes/log4j2.properties"
        if [ -f "$share_log_props" ]; then
            cp "$share_log_props" "${share_log_props}.backup"
            sed -i 's|^appender\.rolling\.fileName=.*share\.log|appender.rolling.fileName=/home/ubuntu/tomcat/logs/share.log|' "$share_log_props"
            log "✓ Share logging configured"
        fi
    fi
    
    # Asegurar que el directorio de logs tiene los permisos correctos
    mkdir -p /home/ubuntu/tomcat/logs
    chown -R ubuntu:ubuntu /home/ubuntu/tomcat/logs
}

# Función para configurar Share
configure_share() {
    log "Configuring Alfresco Share..."
    
    local share_config_dir="/home/ubuntu/tomcat/shared/classes/alfresco/web-extension"
    mkdir -p "$share_config_dir"
    
    # Crear share-config-custom.xml
    cat > "$share_config_dir/share-config-custom.xml" << 'EOF'
<alfresco-config>
   <!-- Global config section -->
   <config replace="true">
      <flags>
         <client-debug>false</client-debug>
         <client-debug-autologging>false</client-debug-autologging>
      </flags>
   </config>

   <config evaluator="string-compare" condition="Remote">
      <remote>
         <endpoint>
            <id>alfresco-noauth</id>
            <name>Alfresco - unauthenticated access</name>
            <description>Access to Alfresco Repository WebScripts that do not require authentication</description>
            <connector-id>alfresco</connector-id>
            <endpoint-url>http://localhost:8080/alfresco/s</endpoint-url>
            <identity>none</identity>
         </endpoint>

         <endpoint>
            <id>alfresco</id>
            <name>Alfresco - user access</name>
            <description>Access to Alfresco Repository WebScripts that require user authentication</description>
            <connector-id>alfresco</connector-id>
            <endpoint-url>http://localhost:8080/alfresco/s</endpoint-url>
            <identity>user</identity>
         </endpoint>

         <endpoint>
            <id>alfresco-feed</id>
            <name>Alfresco Feed</name>
            <description>Alfresco Feed - supports basic HTTP authentication via the EndPointProxyServlet</description>
            <connector-id>http</connector-id>
            <endpoint-url>http://localhost:8080/alfresco/s</endpoint-url>
            <basic-auth>true</basic-auth>
            <identity>user</identity>
         </endpoint>
      </remote>
   </config>
</alfresco-config>
EOF

    chown -R ubuntu:ubuntu "$share_config_dir"
    log "✓ Share configuration created"
}

# Función principal de instalación
main() {
    log "=== Starting Alfresco Installation ==="
    
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
    local content_zip
    content_zip=$(verify_prerequisites)
    
    # Crear backup de configuraciones existentes
    create_backup
    
    # Configurar directorios de Tomcat
    setup_tomcat_directories
    
    # Extraer distribución de Alfresco
    local alfresco_dir
    alfresco_dir=$(extract_alfresco_distribution "$content_zip")
    
    # Instalar componentes de Alfresco
    install_alfresco_components "$alfresco_dir"
    
    # Obtener versiones de componentes
    local transform_version
    transform_version=$(get_component_versions)
    
    # Crear configuración global de Alfresco
    create_alfresco_global_properties "$transform_version"
    
    # Instalar AMPs
    install_amps "$alfresco_dir"
    
    # Configurar logging
    configure_logging
    
    # Configurar Share
    configure_share
    
    # Configurar permisos finales
    log "Setting final permissions..."
    chown -R ubuntu:ubuntu /home/ubuntu/tomcat/shared
    chown -R ubuntu:ubuntu /home/ubuntu/tomcat/webapps
    chown -R ubuntu:ubuntu /home/ubuntu/alf_data
    chown -R ubuntu:ubuntu /home/ubuntu/keystore
    
    # Limpiar archivos temporales
    log "Cleaning up temporary files..."
    rm -rf /tmp/alfresco-extract
    
    # Mostrar resumen de instalación
    log "=== Alfresco Installation Summary ==="
    log "Installation Path: /home/ubuntu/tomcat/webapps"
    log "Data Directory: /home/ubuntu/alf_data"
    log "Keystore Directory: /home/ubuntu/keystore"
    log "Configuration: /home/ubuntu/tomcat/shared/classes/alfresco-global.properties"
    log "Share Config: /home/ubuntu/tomcat/shared/classes/alfresco/web-extension/share-config-custom.xml"
    log "Transform Version: $transform_version"
    
    log "=== Next Steps ==="
    log "1. Start PostgreSQL: sudo systemctl start postgresql"
    log "2. Start ActiveMQ: sudo systemctl start activemq"
    log "3. Start Transform Service: sudo systemctl start transform"
    log "4. Start Tomcat: sudo systemctl start tomcat"
    log "5. Access Alfresco: http://localhost:8080/alfresco"
    log "6. Access Share: http://localhost:8080/share"
    log "7. Default credentials: admin/admin"
    
    log "🎉 Alfresco installation completed successfully!"
}

# Ejecutar función principal
main "$@"