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

# Función para obtener la versión de Java instalada
get_java_version() {
    if command_exists java; then
        java -version 2>&1 | head -1 | cut -d'"' -f2 | cut -d'.' -f1-2
    else
        echo "not_installed"
    fi
}

# Función para verificar si una versión específica de Java está disponible
check_java_package_available() {
    local version=$1
    apt list "openjdk-${version}-jdk" 2>/dev/null | grep -q "openjdk-${version}-jdk"
}

# Función para configurar alternativas de Java
configure_java_alternatives() {
    local java_version=$1
    local java_home="/usr/lib/jvm/java-${java_version}-openjdk-amd64"
    
    log "Configuring Java alternatives for version $java_version..."
    
    # Verificar que el directorio de instalación existe
    if [ ! -d "$java_home" ]; then
        log "ERROR: Java installation directory not found: $java_home"
        return 1
    fi
    
    # Configurar alternativas con prioridad alta para la versión deseada
    local priority=100
    
    sudo update-alternatives --install /usr/bin/java java "${java_home}/bin/java" $priority
    sudo update-alternatives --install /usr/bin/javac javac "${java_home}/bin/javac" $priority
    sudo update-alternatives --install /usr/bin/jar jar "${java_home}/bin/jar" $priority
    sudo update-alternatives --install /usr/bin/javadoc javadoc "${java_home}/bin/javadoc" $priority
    
    # Configurar automáticamente sin interacción
    sudo update-alternatives --set java "${java_home}/bin/java"
    sudo update-alternatives --set javac "${java_home}/bin/javac"
    sudo update-alternatives --set jar "${java_home}/bin/jar"
    sudo update-alternatives --set javadoc "${java_home}/bin/javadoc"
    
    log "✓ Java alternatives configured successfully"
}

# Función para configurar JAVA_HOME globalmente
configure_java_home() {
    local java_version=$1
    local java_home="/usr/lib/jvm/java-${java_version}-openjdk-amd64"
    
    log "Configuring JAVA_HOME environment variable..."
    
    # Crear archivo de configuración de entorno
    cat <<EOF | sudo tee /etc/environment.d/java.conf
JAVA_HOME=${java_home}
EOF
    
    # Configurar para el perfil del sistema
    if ! grep -q "JAVA_HOME" /etc/profile; then
        echo "export JAVA_HOME=${java_home}" | sudo tee -a /etc/profile
        echo "export PATH=\$JAVA_HOME/bin:\$PATH" | sudo tee -a /etc/profile
    fi
    
    # Configurar para bash
    if [ -f /etc/bash.bashrc ] && ! grep -q "JAVA_HOME" /etc/bash.bashrc; then
        echo "export JAVA_HOME=${java_home}" | sudo tee -a /etc/bash.bashrc
        echo "export PATH=\$JAVA_HOME/bin:\$PATH" | sudo tee -a /etc/bash.bashrc
    fi
    
    # Configurar para el usuario actual
    if [ -n "$HOME" ] && [ -f "$HOME/.bashrc" ]; then
        if ! grep -q "JAVA_HOME" "$HOME/.bashrc"; then
            echo "export JAVA_HOME=${java_home}" >> "$HOME/.bashrc"
            echo "export PATH=\$JAVA_HOME/bin:\$PATH" >> "$HOME/.bashrc"
        fi
    fi
    
    # Exportar para la sesión actual
    export JAVA_HOME="$java_home"
    export PATH="$JAVA_HOME/bin:$PATH"
    
    log "✓ JAVA_HOME configured: $java_home"
}

# Función para verificar la instalación de Java
verify_java_installation() {
    local expected_version=$1
    
    log "Verifying Java installation..."
    
    # Verificar que los comandos básicos existen
    local required_commands=("java" "javac" "jar")
    for cmd in "${required_commands[@]}"; do
        if ! command_exists "$cmd"; then
            log "ERROR: $cmd command not found"
            return 1
        fi
        log "✓ $cmd command available"
    done
    
    # Verificar versión de Java
    local installed_version=$(get_java_version)
    log "Installed Java version: $installed_version"
    
    if [[ "$installed_version" == *"$expected_version"* ]]; then
        log "✓ Java version verification successful"
    else
        log "WARNING: Expected Java $expected_version, but got $installed_version"
    fi
    
    # Verificar JAVA_HOME
    local java_home_check="${JAVA_HOME:-$(dirname $(dirname $(readlink -f $(which java))))}"
    if [ -d "$java_home_check" ]; then
        log "✓ JAVA_HOME is valid: $java_home_check"
    else
        log "WARNING: JAVA_HOME might not be set correctly"
    fi
    
    return 0
}

log "Starting Java JDK installation..."

# Actualizar lista de paquetes
log "Updating package list..."
sudo apt update

# Definir versiones de Java en orden de preferencia (Java 17 es requerido para Alfresco)
PREFERRED_VERSIONS=("17" "21" "11")
SELECTED_VERSION=""

# Buscar la primera versión disponible
log "Checking available Java versions..."
for version in "${PREFERRED_VERSIONS[@]}"; do
    log "Checking Java $version availability..."
    if check_java_package_available "$version"; then
        SELECTED_VERSION="$version"
        log "✓ Java $version is available and will be installed"
        break
    else
        log "✗ Java $version is not available"
    fi
done

# Si no se encuentra ninguna versión preferida, usar la versión por defecto del sistema
if [ -z "$SELECTED_VERSION" ]; then
    log "No preferred Java version found, checking default-jdk..."
    if apt list default-jdk 2>/dev/null | grep -q default-jdk; then
        log "Installing default-jdk as fallback..."
        sudo apt install -y default-jdk
        SELECTED_VERSION="default"
    else
        log "ERROR: No suitable Java version found"
        exit 1
    fi
else
    # Instalar la versión seleccionada
    log "Installing Java JDK $SELECTED_VERSION..."
    sudo apt install -y "openjdk-${SELECTED_VERSION}-jdk"
    
    # Instalar herramientas adicionales útiles para desarrollo
    if check_java_package_available "${SELECTED_VERSION}"; then
        log "Installing additional Java tools..."
        sudo apt install -y "openjdk-${SELECTED_VERSION}-jdk-headless" "openjdk-${SELECTED_VERSION}-source" || true
    fi
fi

# Configurar alternativas de Java (solo para versiones numéricas)
if [ "$SELECTED_VERSION" != "default" ]; then
    configure_java_alternatives "$SELECTED_VERSION"
    configure_java_home "$SELECTED_VERSION"
fi

# Verificar la instalación
log "Checking Java version..."
java -version
javac -version 2>/dev/null || log "WARNING: javac not found (development tools may not be available)"

# Verificación completa
if [ "$SELECTED_VERSION" != "default" ]; then
    verify_java_installation "$SELECTED_VERSION"
else
    verify_java_installation "default"
fi

# Mostrar información de Java instalado
log "=== Java Installation Summary ==="
log "Java Version: $(java -version 2>&1 | head -1)"
log "Java Compiler: $(javac -version 2>&1 || echo 'Not available')"
log "Java Home: ${JAVA_HOME:-'Not set in current session'}"
log "Java Binary: $(which java)"
log "Javac Binary: $(which javac 2>/dev/null || echo 'Not available')"

# Mostrar alternativas configuradas
log "=== Java Alternatives ==="
sudo update-alternatives --list java 2>/dev/null || log "No Java alternatives found"

# Verificar compatibilidad con Alfresco
log "=== Alfresco Compatibility Check ==="
current_java_version=$(java -version 2>&1 | head -1 | sed 's/.*version "\([0-9]*\).*/\1/')

if [ "$current_java_version" -ge 17 ] 2>/dev/null; then
    log "✅ Java $current_java_version is compatible with Alfresco (requires Java 17+)"
elif [ "$current_java_version" -eq 11 ] 2>/dev/null; then
    log "⚠️  Java $current_java_version detected. Alfresco recommends Java 17+ for best performance"
else
    log "❌ Java $current_java_version may not be compatible with Alfresco. Please verify compatibility"
fi

log "🎉 Java JDK installation and setup completed successfully!"

# Instrucciones adicionales
log "=== Additional Information ==="
log "To reload environment variables in current session, run:"
log "  source /etc/profile"
log ""
log "To verify Java installation manually:"
log "  java -version"
log "  javac -version"
log "  echo \$JAVA_HOME"