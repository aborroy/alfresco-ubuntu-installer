#!/bin/bash

set -e

# Función para logging
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# Función para verificar si un comando existe
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Función para obtener la última versión de Tomcat con fallback
fetch_latest_tomcat_version() {
    local base_url="https://dlcdn.apache.org/tomcat/tomcat-10/"
    local fallback_version="10.1.30"  # Versión conocida estable
    
    log "Fetching latest Tomcat version from Apache mirror..."
    
    # Intentar obtener la versión más reciente con timeout
    local latest_version=""
    if command_exists curl; then
        latest_version=$(curl --connect-timeout 10 --max-time 30 -s "$base_url" 2>/dev/null | \
                        grep -oP 'v[0-9]+\.[0-9]+\.[0-9]+' | \
                        sort -V | \
                        tail -1 | \
                        sed 's/v//') || true
    fi
    
    # Verificar que la versión obtenida es válida
    if [[ "$latest_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        log "✓ Latest Tomcat version found: $latest_version"
        echo "$latest_version"
    else
        log "⚠️  Could not fetch latest version, using fallback: $fallback_version"
        echo "$fallback_version"
    fi
}

# Función para verificar si Java está instalado y configurado
verify_java_installation() {
    log "Verifying Java installation..."
    
    if ! command_exists java; then
        log "ERROR: Java is not installed. Please run 02-install_java.sh first"
        exit 1
    fi
    
    local java_version=$(java -version 2>&1 | head -1 | sed 's/.*version "\([0-9]*\).*/\1/')
    log "✓ Java version detected: $java_version"
    
    # Verificar JAVA_HOME
    local java_home="${JAVA_HOME:-$(dirname $(dirname $(readlink -f $(which java))))}"
    if [ ! -d "$java_home" ]; then
        log "ERROR: JAVA_HOME is not properly set: $java_home"
        exit 1
    fi
    
    log "✓ JAVA_HOME verified: $java_home"
    export JAVA_HOME="$java_home"
}

# Función para descargar Tomcat con reintentos
download_tomcat() {
    local version=$1
    local download_url="https://dlcdn.apache.org/tomcat/tomcat-10/v$version/bin/apache-tomcat-$version.tar.gz"
    local temp_file="/tmp/apache-tomcat-$version.tar.gz"
    local max_retries=3
    local retry=0
    
    log "Downloading Apache Tomcat $version..."
    
    while [ $retry -lt $max_retries ]; do
        log "Download attempt $((retry + 1))/$max_retries..."
        
        if wget --timeout=60 --tries=3 -O "$temp_file" "$download_url"; then
            # Verificar que el archivo descargado no está vacío
            local file_size=$(stat -c%s "$temp_file" 2>/dev/null || stat -f%z "$temp_file" 2>/dev/null)
            if [ "$file_size" -gt 1048576 ]; then  # > 1MB
                log "✓ Tomcat downloaded successfully ($file_size bytes)"
                echo "$temp_file"
                return 0
            else
                log "✗ Downloaded file is too small ($file_size bytes)"
            fi
        else
            log "✗ Download failed"
        fi
        
        retry=$((retry + 1))
        if [ $retry -lt $max_retries ]; then
            log "Retrying in 10 seconds..."
            sleep 10
        fi
    done
    
    log "ERROR: Failed to download Tomcat after $max_retries attempts"
    return 1
}

# Función para crear usuario del sistema si no existe
create_tomcat_user() {
    local user="$1"
    local group="$2"
    
    log "Setting up Tomcat user and group..."
    
    # Crear grupo si no existe
    if ! getent group "$group" >/dev/null 2>&1; then
        log "Creating group: $group"
        sudo groupadd "$group"
    else
        log "✓ Group $group already exists"
    fi
    
    # Crear usuario si no existe
    if ! id "$user" >/dev/null 2>&1; then
        log "Creating user: $user"
        sudo useradd -r -s /bin/bash -g "$group" -d /home/$user -m "$user"
    else
        log "✓ User $user already exists"
    fi
    
    # Asegurar que el usuario está en el grupo correcto
    sudo usermod -g "$group" "$user"
    log "✓ User $user configured with group $group"
}

# Variables
TOMCAT_USER="ubuntu"
TOMCAT_GROUP="ubuntu"
TOMCAT_HOME="/home/ubuntu/tomcat"

log "Starting Apache Tomcat installation..."

# Verificar prerrequisitos
verify_java_installation

# Actualizar lista de paquetes
log "Updating package list..."
sudo apt update

# Instalar dependencias necesarias
log "Installing required dependencies..."
sudo apt install -y wget curl tar

# Obtener la versión más reciente de Tomcat
TOMCAT_VERSION=$(fetch_latest_tomcat_version)

# Configurar usuario y grupo
create_tomcat_user "$TOMCAT_USER" "$TOMCAT_GROUP"

# Descargar Tomcat
TOMCAT_ARCHIVE=$(download_tomcat "$TOMCAT_VERSION")
if [ ! -f "$TOMCAT_ARCHIVE" ]; then
    log "ERROR: Failed to download Tomcat"
    exit 1
fi

# Crear directorio de instalación
log "Creating Tomcat installation directory..."
sudo mkdir -p "$TOMCAT_HOME"

# Extraer Tomcat
log "Extracting Tomcat to $TOMCAT_HOME..."
sudo tar xzf "$TOMCAT_ARCHIVE" -C "$TOMCAT_HOME" --strip-components=1

# Configurar permisos
log "Setting up Tomcat permissions..."
sudo chown -R "$TOMCAT_USER:$TOMCAT_GROUP" "$TOMCAT_HOME"
sudo chmod -R u+x "$TOMCAT_HOME/bin"

# Crear directorios adicionales necesarios para Alfresco
log "Creating additional directories for Alfresco..."
sudo mkdir -p "$TOMCAT_HOME/shared/classes"
sudo mkdir -p "$TOMCAT_HOME/shared/lib"
sudo mkdir -p "$TOMCAT_HOME/temp"
sudo mkdir -p "$TOMCAT_HOME/work"
sudo mkdir -p "$TOMCAT_HOME/logs"
sudo chown -R "$TOMCAT_USER:$TOMCAT_GROUP" "$TOMCAT_HOME/shared" "$TOMCAT_HOME/temp" "$TOMCAT_HOME/work" "$TOMCAT_HOME/logs"

# Configurar catalina.properties para el directorio shared
log "Configuring catalina.properties for shared loader..."
sudo sed -i 's|^shared.loader=$|shared.loader=${catalina.base}/shared/classes,${catalina.base}/shared/lib/*.jar|' "$TOMCAT_HOME/conf/catalina.properties"

# Configurar server.xml con optimizaciones para Alfresco
log "Optimizing Tomcat server.xml configuration..."
sudo cp "$TOMCAT_HOME/conf/server.xml" "$TOMCAT_HOME/conf/server.xml.backup"

# Configurar conectores HTTP y AJP optimizados
cat << 'EOF' | sudo tee "$TOMCAT_HOME/conf/server.xml.alfresco" > /dev/null
<?xml version="1.0" encoding="UTF-8"?>
<Server port="8005" shutdown="SHUTDOWN">
  <Listener className="org.apache.catalina.startup.VersionLoggerListener" />
  <Listener className="org.apache.catalina.core.AprLifecycleListener" SSLEngine="on" />
  <Listener className="org.apache.catalina.core.JreMemoryLeakPreventionListener" />
  <Listener className="org.apache.catalina.mbeans.GlobalResourcesLifecycleListener" />
  <Listener className="org.apache.catalina.core.ThreadLocalLeakPreventionListener" />

  <GlobalNamingResources>
    <Resource name="UserDatabase" auth="Container"
              type="org.apache.catalina.UserDatabase"
              description="User database that can be updated and saved"
              factory="org.apache.catalina.users.MemoryUserDatabaseFactory"
              pathname="conf/tomcat-users.xml" />
  </GlobalNamingResources>

  <Service name="Catalina">
    <Connector port="8080" protocol="HTTP/1.1"
               connectionTimeout="20000"
               redirectPort="8443"
               maxThreads="200"
               minSpareThreads="10"
               maxSpareThreads="75"
               enableLookups="false"
               acceptCount="100"
               maxPostSize="104857600"
               compression="on"
               compressionMinSize="2048"
               noCompressionUserAgents="gozilla, traviata"
               compressableMimeType="text/html,text/xml,text/plain,text/css,text/javascript,application/javascript,application/json" />

    <Engine name="Catalina" defaultHost="localhost">
      <Realm className="org.apache.catalina.realm.LockOutRealm">
        <Realm className="org.apache.catalina.realm.UserDatabaseRealm"
               resourceName="UserDatabase"/>
      </Realm>

      <Host name="localhost"  appBase="webapps"
            unpackWARs="true" autoDeploy="false"
            deployOnStartup="true">
        <Valve className="org.apache.catalina.valves.AccessLogValve" directory="logs"
               prefix="localhost_access_log" suffix=".txt"
               pattern="%h %l %u %t &quot;%r&quot; %s %b" />
      </Host>
    </Engine>
  </Service>
</Server>
EOF

sudo mv "$TOMCAT_HOME/conf/server.xml.alfresco" "$TOMCAT_HOME/conf/server.xml"
sudo chown "$TOMCAT_USER:$TOMCAT_GROUP" "$TOMCAT_HOME/conf/server.xml"

# Obtener la ruta correcta de JAVA_HOME
DETECTED_JAVA_HOME="${JAVA_HOME:-$(dirname $(dirname $(readlink -f $(which java))))}"

# Crear archivo de servicio systemd optimizado para Alfresco
log "Creating Tomcat systemd service file..."
cat <<EOF | sudo tee /etc/systemd/system/tomcat.service
[Unit]
Description=Apache Tomcat Web Application Container
Documentation=https://tomcat.apache.org/tomcat-10.1-doc/index.html
After=network.target transform.service
Requires=transform.service
Wants=postgresql.service activemq.service

[Service]
Type=forking
User=$TOMCAT_USER
Group=$TOMCAT_GROUP
RestartSec=10
Restart=always

Environment="JAVA_HOME=$DETECTED_JAVA_HOME"
Environment="CATALINA_PID=$TOMCAT_HOME/temp/tomcat.pid"
Environment="CATALINA_HOME=$TOMCAT_HOME"
Environment="CATALINA_BASE=$TOMCAT_HOME"

# Optimizaciones de memoria para Alfresco
Environment="CATALINA_OPTS=-Xms2048M -Xmx4096M -server -XX:+UseG1GC -XX:+UseStringDeduplication -XX:MinRAMPercentage=50 -XX:MaxRAMPercentage=80"

# Configuraciones de seguridad y sistema
Environment="JAVA_OPTS=-Djava.awt.headless=true -Djava.security.egd=file:/dev/./urandom -Dfile.encoding=UTF-8 -Duser.timezone=UTC"

# Configuraciones específicas para Alfresco (encryption keystore)
Environment="JAVA_TOOL_OPTIONS=-Dencryption.keystore.type=JCEKS -Dencryption.cipherAlgorithm=DESede/CBC/PKCS5Padding -Dencryption.keyAlgorithm=DESede -Dencryption.keystore.location=/home/ubuntu/keystore/metadata-keystore/keystore -Dmetadata-keystore.password=mp6yc0UD9e -Dmetadata-keystore.aliases=metadata -Dmetadata-keystore.metadata.password=oKIWzVdEdA -Dmetadata-keystore.metadata.algorithm=DESede"

ExecStart=$TOMCAT_HOME/bin/startup.sh
ExecStop=$TOMCAT_HOME/bin/shutdown.sh

# Security settings
PrivateTmp=yes
ProtectSystem=strict
ReadWritePaths=$TOMCAT_HOME /home/ubuntu/alf_data /home/ubuntu/keystore
NoNewPrivileges=yes
ProtectKernelTunables=yes
ProtectControlGroups=yes
RestrictRealtime=yes

[Install]
WantedBy=multi-user.target
EOF

# Configurar logrotate para los logs de Tomcat
log "Setting up log rotation for Tomcat..."
cat <<EOF | sudo tee /etc/logrotate.d/tomcat
$TOMCAT_HOME/logs/*.log {
    daily
    missingok
    rotate 30
    compress
    delaycompress
    notifempty
    create 644 $TOMCAT_USER $TOMCAT_GROUP
    postrotate
        systemctl reload tomcat || true
    endscript
}
EOF

# Recargar systemd y habilitar el servicio
log "Reloading systemd daemon..."
sudo systemctl daemon-reload

log "Enabling Tomcat service to start on boot..."
sudo systemctl enable tomcat

# Limpiar archivos temporales
log "Cleaning up temporary files..."
rm -f "$TOMCAT_ARCHIVE"

# Verificación final
log "Verifying Tomcat installation..."
if [ -f "$TOMCAT_HOME/bin/catalina.sh" ] && [ -x "$TOMCAT_HOME/bin/catalina.sh" ]; then
    log "✓ Tomcat installation verified"
else
    log "ERROR: Tomcat installation verification failed"
    exit 1
fi

# Mostrar resumen de la instalación
log "=== Tomcat Installation Summary ==="
log "Tomcat Version: $TOMCAT_VERSION"
log "Installation Path: $TOMCAT_HOME"
log "User/Group: $TOMCAT_USER:$TOMCAT_GROUP"
log "Java Home: $DETECTED_JAVA_HOME"
log "Service File: /etc/systemd/system/tomcat.service"
log "Server Config: $TOMCAT_HOME/conf/server.xml"
log "Shared Classes: $TOMCAT_HOME/shared/classes"
log "Shared Libraries: $TOMCAT_HOME/shared/lib"

log "=== Service Management ==="
log "Start Tomcat: sudo systemctl start tomcat"
log "Stop Tomcat:  sudo systemctl stop tomcat"
log "Status:       sudo systemctl status tomcat"
log "Logs:         sudo journalctl -u tomcat -f"
log "Catalina Log: tail -f $TOMCAT_HOME/logs/catalina.out"

log "=== Important Notes ==="
log "• Tomcat is configured with optimized settings for Alfresco"
log "• Memory settings: -Xms2048M -Xmx4096M (adjust based on available RAM)"
log "• Shared loader is configured for Alfresco extensions"
log "• Log rotation is configured to manage log file sizes"
log "• Service will auto-start on boot"

log "🎉 Apache Tomcat installation and setup completed successfully!"

# Verificar que el servicio se puede iniciar (test rápido)
log "Testing service configuration..."
if sudo systemctl start tomcat; then
    sleep 10
    if sudo systemctl is-active --quiet tomcat; then
        log "✅ Tomcat service test successful"
        sudo systemctl stop tomcat
        log "Service stopped for final configuration"
    else
        log "⚠️  Tomcat service test failed - check configuration"
        sudo systemctl status tomcat --no-pager || true
    fi
else
    log "⚠️  Could not start Tomcat service - will need troubleshooting"
fi