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

# Función para verificar el estado del servicio
check_service_status() {
    local service=$1
    if sudo systemctl is-active --quiet $service; then
        log "✓ $service is running"
        return 0
    else
        log "✗ $service is not running"
        return 1
    fi
}

log "Starting PostgreSQL installation and configuration..."

# Actualizar lista de paquetes
log "Updating package list..."
sudo apt update

# Instalar PostgreSQL
log "Installing PostgreSQL..."
sudo apt install -y postgresql postgresql-contrib

# Verificar instalación
if ! command_exists psql; then
    log "ERROR: PostgreSQL installation failed - psql command not found"
    exit 1
fi

# Detectar versión de PostgreSQL instalada dinámicamente
PG_VERSION=$(sudo -u postgres psql -t -c "SELECT version();" | grep -oP 'PostgreSQL \K[0-9]+' | head -1)
log "Detected PostgreSQL version: $PG_VERSION"

# Configurar archivos de configuración con la versión correcta
PG_CONFIG_DIR="/etc/postgresql/$PG_VERSION/main"
PG_HBA_FILE="$PG_CONFIG_DIR/pg_hba.conf"
PG_CONF_FILE="$PG_CONFIG_DIR/postgresql.conf"

# Verificar que los archivos de configuración existen
if [ ! -f "$PG_HBA_FILE" ]; then
    log "ERROR: PostgreSQL configuration file not found: $PG_HBA_FILE"
    exit 1
fi

log "Configuring PostgreSQL authentication..."

# Crear backup de configuración original
sudo cp "$PG_HBA_FILE" "$PG_HBA_FILE.backup.$(date +%Y%m%d_%H%M%S)"

# Configurar autenticación local mejorada
log "Updating pg_hba.conf for local connections..."
sudo sed -i 's/^local\s\+all\s\+postgres\s\+peer$/local   all             postgres                                trust/' "$PG_HBA_FILE"
sudo sed -i 's/^local\s\+all\s\+all\s\+peer$/local   all             all                                     md5/' "$PG_HBA_FILE"

# Agregar configuraciones adicionales para conexiones TCP/IP si no existen
if ! sudo grep -q "host.*alfresco.*md5" "$PG_HBA_FILE"; then
    log "Adding host-based authentication for alfresco user..."
    echo "host    alfresco        alfresco        127.0.0.1/32            md5" | sudo tee -a "$PG_HBA_FILE"
    echo "host    alfresco        alfresco        ::1/128                 md5" | sudo tee -a "$PG_HBA_FILE"
fi

# Configurar PostgreSQL para escuchar en localhost
log "Configuring PostgreSQL to listen on localhost..."
if sudo grep -q "^#listen_addresses" "$PG_CONF_FILE"; then
    sudo sed -i "s/#listen_addresses = 'localhost'/listen_addresses = 'localhost'/" "$PG_CONF_FILE"
elif ! sudo grep -q "^listen_addresses" "$PG_CONF_FILE"; then
    echo "listen_addresses = 'localhost'" | sudo tee -a "$PG_CONF_FILE"
fi

# Reiniciar PostgreSQL para aplicar cambios de configuración
log "Restarting PostgreSQL to apply configuration changes..."
sudo systemctl restart postgresql

# Esperar a que el servicio esté completamente iniciado
sleep 5

# Verificar que PostgreSQL está corriendo
if ! check_service_status postgresql; then
    log "ERROR: PostgreSQL failed to start after configuration"
    sudo systemctl status postgresql --no-pager
    exit 1
fi

# Configurar base de datos y usuario para Alfresco
log "Creating Alfresco database and user..."

# Función para ejecutar comandos SQL con manejo de errores
execute_sql() {
    local sql_command="$1"
    local description="$2"
    
    log "Executing: $description"
    if sudo -u postgres psql -c "$sql_command"; then
        log "✓ $description completed successfully"
    else
        log "✗ $description failed"
        return 1
    fi
}

# Crear usuario alfresco
execute_sql "DROP USER IF EXISTS alfresco;" "Removing existing alfresco user (if exists)"
execute_sql "CREATE USER alfresco WITH PASSWORD 'alfresco';" "Creating alfresco user"

# Crear base de datos alfresco
execute_sql "DROP DATABASE IF EXISTS alfresco;" "Removing existing alfresco database (if exists)"
execute_sql "CREATE DATABASE alfresco OWNER alfresco ENCODING 'UTF8' LC_COLLATE='en_US.UTF-8' LC_CTYPE='en_US.UTF-8';" "Creating alfresco database"

# Otorgar privilegios
execute_sql "GRANT ALL PRIVILEGES ON DATABASE alfresco TO alfresco;" "Granting privileges to alfresco user"

# Configuraciones adicionales de la base de datos para optimizar para Alfresco
execute_sql "ALTER DATABASE alfresco SET timezone TO 'UTC';" "Setting database timezone to UTC"

# Verificar la conexión con el nuevo usuario
log "Testing connection with alfresco user..."
if PGPASSWORD='alfresco' psql -h localhost -U alfresco -d alfresco -c "SELECT version();" >/dev/null; then
    log "✓ Connection test successful"
else
    log "✗ Connection test failed"
    exit 1
fi

# Configurar PostgreSQL para iniciar automáticamente
log "Enabling PostgreSQL to start on boot..."
sudo systemctl enable postgresql

# Verificación final
log "Performing final verification..."
check_service_status postgresql

# Mostrar información de la instalación
log "=== PostgreSQL Installation Summary ==="
log "PostgreSQL Version: $PG_VERSION"
log "Database: alfresco"
log "User: alfresco"
log "Password: alfresco"
log "Connection: localhost:5432"
log "Config files:"
log "  - Main config: $PG_CONF_FILE"
log "  - HBA config: $PG_HBA_FILE"
log "  - Backup: $PG_HBA_FILE.backup.*"

# Test de conectividad final
log "Running final connectivity test..."
if PGPASSWORD='alfresco' psql -h localhost -U alfresco -d alfresco -c "SELECT 'PostgreSQL is ready for Alfresco!' as status;" 2>/dev/null | grep -q "ready for Alfresco"; then
    log "🎉 PostgreSQL installation and setup completed successfully!"
else
    log "❌ Final connectivity test failed"
    exit 1
fi

log "You can connect to the database using:"
log "  psql -h localhost -U alfresco -d alfresco"
log "  Password: alfresco"