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

# Función para verificar memoria disponible
check_system_resources() {
    log "Checking system resources..."
    
    # Verificar memoria disponible (Node.js build necesita al menos 2GB)
    local mem_kb=$(grep MemAvailable /proc/meminfo | awk '{print $2}' 2>/dev/null || echo "0")
    local mem_gb=$((mem_kb / 1024 / 1024))
    
    if [ "$mem_gb" -lt 2 ]; then
        log "⚠️  Warning: Low memory detected ($mem_gb GB). Build may fail or be slow."
        log "Consider increasing system memory or enabling swap."
    else
        log "✓ Memory check passed ($mem_gb GB available)"
    fi
    
    # Verificar espacio en disco (build necesita al menos 2GB)
    local disk_space=$(df /home/ubuntu --output=avail | tail -1)
    local disk_gb=$((disk_space / 1024 / 1024))
    
    if [ "$disk_gb" -lt 2 ]; then
        log_error "Insufficient disk space ($disk_gb GB). At least 2GB required."
        exit 1
    else
        log "✓ Disk space check passed ($disk_gb GB available)"
    fi
}

# Función para instalar Node.js
install_nodejs() {
    log "Installing Node.js and npm..."
    
    # Verificar si Node.js ya está instalado con versión adecuada
    if command_exists node; then
        local node_version=$(node -v | sed 's/v//' | cut -d'.' -f1)
        if [ "$node_version" -ge 16 ]; then
            log "✓ Node.js $node_version already installed"
            return 0
        else
            log "⚠️  Node.js $node_version detected. Upgrading to LTS version..."
        fi
    fi
    
    # Detectar arquitectura del sistema
    local arch=$(uname -m)
    local node_arch=""
    case $arch in
        x86_64) node_arch="x64" ;;
        aarch64) node_arch="arm64" ;;
        armv7l) node_arch="armv7l" ;;
        *) 
            log_error "Unsupported architecture: $arch"
            exit 1
            ;;
    esac
    
    # Instalar Node.js LTS usando NodeSource repository
    log "Setting up NodeSource repository..."
    if ! curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -; then
        log_error "Failed to setup NodeSource repository"
        exit 1
    fi
    
    # Instalar Node.js
    if ! sudo apt install -y nodejs; then
        log_error "Failed to install Node.js"
        exit 1
    fi
    
    # Verificar instalación
    if command_exists node && command_exists npm; then
        local node_version=$(node -v)
        local npm_version=$(npm -v)
        log "✓ Node.js $node_version installed"
        log "✓ npm $npm_version installed"
    else
        log_error "Node.js or npm installation verification failed"
        exit 1
    fi
    
    # Configurar npm para evitar problemas de permisos
    log "Configuring npm..."
    mkdir -p /home/ubuntu/.npm-global
    npm config set prefix '/home/ubuntu/.npm-global'
    
    # Añadir al PATH si no está ya
    if ! echo "$PATH" | grep -q "/home/ubuntu/.npm-global/bin"; then
        echo 'export PATH=/home/ubuntu/.npm-global/bin:$PATH' >> /home/ubuntu/.bashrc
        export PATH="/home/ubuntu/.npm-global/bin:$PATH"
    fi
    
    # Configurar npm cache y registry
    npm config set cache /home/ubuntu/.npm-cache
    npm config set registry https://registry.npmjs.org/
    
    log "✓ npm configured successfully"
}

# Función para instalar Git si no está disponible
install_git() {
    if ! command_exists git; then
        log "Installing Git..."
        sudo apt update
        sudo apt install -y git
        
        if command_exists git; then
            local git_version=$(git --version)
            log "✓ $git_version installed"
        else
            log_error "Git installation failed"
            exit 1
        fi
    else
        local git_version=$(git --version)
        log "✓ $git_version already available"
    fi
}

# Función para clonar el repositorio de ACA
clone_aca_repository() {
    local repo_dir="/home/ubuntu/alfresco-content-app"
    
    log "Cloning Alfresco Content App repository..."
    
    # Limpiar directorio existente si existe
    if [ -d "$repo_dir" ]; then
        local backup_dir="${repo_dir}.backup.$(date +%Y%m%d_%H%M%S)"
        log "Backing up existing repository to $(basename "$backup_dir")"
        mv "$repo_dir" "$backup_dir"
    fi
    
    # Clonar repositorio con timeout y verificación
    local clone_success=false
    local max_retries=3
    local retry=0
    
    while [ $retry -lt $max_retries ] && [ "$clone_success" = false ]; do
        retry=$((retry + 1))
        log "Clone attempt $retry/$max_retries..."
        
        if timeout 300 git clone --depth 1 https://github.com/Alfresco/alfresco-content-app.git "$repo_dir"; then
            clone_success=true
            log "✓ Repository cloned successfully"
        else
            log "❌ Clone attempt $retry failed"
            [ -d "$repo_dir" ] && rm -rf "$repo_dir"
            
            if [ $retry -lt $max_retries ]; then
                log "Retrying in 10 seconds..."
                sleep 10
            fi
        fi
    done
    
    if [ "$clone_success" = false ]; then
        log_error "Failed to clone repository after $max_retries attempts"
        exit 1
    fi
    
    # Verificar que el repositorio se clonó correctamente
    if [ ! -f "$repo_dir/package.json" ]; then
        log_error "Repository clone appears incomplete - package.json not found"
        exit 1
    fi
    
    echo "$repo_dir"
}

# Función para obtener y checkout la versión más reciente
checkout_latest_version() {
    local repo_dir="$1"
    
    log "Fetching and checking out latest stable version..."
    
    cd "$repo_dir"
    
    # Obtener todas las tags
    if ! git fetch --tags --depth=50; then
        log "⚠️  Warning: Could not fetch tags, using default branch"
        return 0
    fi
    
    # Obtener la última versión tag que sea una release estable
    local latest_tag=$(git tag -l | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -n 1)
    
    if [ -n "$latest_tag" ]; then
        log "Latest stable version found: $latest_tag"
        
        # Crear una rama desde el tag
        if git checkout -b "build-$latest_tag" "tags/$latest_tag"; then
            log "✓ Checked out version $latest_tag"
            echo "$latest_tag"
        else
            log "⚠️  Warning: Could not checkout $latest_tag, using default branch"
            git checkout main 2>/dev/null || git checkout master 2>/dev/null || true
            echo "main/master"
        fi
    else
        log "⚠️  Warning: No stable version tags found, using default branch"
        git checkout main 2>/dev/null || git checkout master 2>/dev/null || true
        echo "main/master"
    fi
}

# Función para instalar dependencias del proyecto
install_project_dependencies() {
    local repo_dir="$1"
    
    log "Installing project dependencies..."
    cd "$repo_dir"
    
    # Verificar que package.json existe
    if [ ! -f "package.json" ]; then
        log_error "package.json not found in repository"
        exit 1
    fi
    
    # Mostrar información del proyecto
    local project_name=$(node -p "require('./package.json').name" 2>/dev/null || echo "unknown")
    local project_version=$(node -p "require('./package.json').version" 2>/dev/null || echo "unknown")
    log "Project: $project_name v$project_version"
    
    # Limpiar cache de npm
    log "Clearing npm cache..."
    npm cache clean --force 2>/dev/null || true
    
    # Instalar dependencias con configuración optimizada
    log "Installing npm dependencies (this may take several minutes)..."
    
    # Configurar npm para el build
    npm config set audit-level moderate
    npm config set fund false
    npm config set update-notifier false
    
    # Instalar con configuración específica para evitar problemas comunes
    local install_success=false
    local install_attempts=0
    local max_install_attempts=3
    
    while [ $install_attempts -lt $max_install_attempts ] && [ "$install_success" = false ]; do
        install_attempts=$((install_attempts + 1))
        log "Dependency installation attempt $install_attempts/$max_install_attempts..."
        
        # Usar npm ci si existe package-lock.json, npm install en caso contrario
        if [ -f "package-lock.json" ]; then
            if npm ci --no-audit --no-fund --prefer-offline; then
                install_success=true
            fi
        else
            if npm install --no-audit --no-fund --prefer-offline; then
                install_success=true
            fi
        fi
        
        if [ "$install_success" = false ] && [ $install_attempts -lt $max_install_attempts ]; then
            log "⚠️  Installation attempt failed, cleaning and retrying..."
            rm -rf node_modules package-lock.json 2>/dev/null || true
            sleep 5
        fi
    done
    
    if [ "$install_success" = false ]; then
        log_error "Failed to install dependencies after $max_install_attempts attempts"
        exit 1
    fi
    
    log "✓ Dependencies installed successfully"
    
    # Verificar que node_modules se creó correctamente
    if [ ! -d "node_modules" ]; then
        log_error "node_modules directory not created"
        exit 1
    fi
    
    # Mostrar estadísticas de instalación
    local dep_count=$(find node_modules -maxdepth 1 -type d | wc -l)
    local install_size=$(du -sh node_modules 2>/dev/null | cut -f1 || echo "unknown")
    log "✓ Installed $dep_count packages ($install_size)"
}

# Función para configurar el build
configure_build() {
    local repo_dir="$1"
    
    log "Configuring build settings..."
    cd "$repo_dir"
    
    # Crear o actualizar configuración de build si es necesario
    local env_file=".env"
    if [ ! -f "$env_file" ]; then
        cat > "$env_file" << 'EOF'
# Production build configuration
NODE_ENV=production
NODE_OPTIONS=--max-old-space-size=4096

# Build optimization
GENERATE_SOURCEMAP=false
CI=true
EOF
        log "✓ Build environment configuration created"
    fi
    
    # Configurar memoria de Node.js para el build
    export NODE_OPTIONS="--max-old-space-size=4096"
    export CI=true
    
    log "✓ Build configuration completed"
}

# Función para construir la aplicación
build_application() {
    local repo_dir="$1"
    
    log "Building Alfresco Content App (this may take 10-15 minutes)..."
    cd "$repo_dir"
    
    # Verificar que existe un script de build
    if ! node -p "require('./package.json').scripts.build" >/dev/null 2>&1; then
        log_error "Build script not found in package.json"
        exit 1
    fi
    
    # Limpiar builds anteriores
    [ -d "dist" ] && rm -rf dist
    
    # Ejecutar build con timeout y monitoreo
    local build_start_time=$(date +%s)
    log "Starting build process..."
    
    # Ejecutar el build con timeout de 30 minutos
    if timeout 1800 npm run build; then
        local build_end_time=$(date +%s)
        local build_duration=$((build_end_time - build_start_time))
        local build_minutes=$((build_duration / 60))
        local build_seconds=$((build_duration % 60))
        
        log "✅ Build completed successfully in ${build_minutes}m${build_seconds}s"
    else
        local exit_code=$?
        if [ $exit_code -eq 124 ]; then
            log_error "Build timed out after 30 minutes"
        else
            log_error "Build failed with exit code $exit_code"
        fi
        exit 1
    fi
    
    # Verificar que el build se completó correctamente
    if [ ! -d "dist" ]; then
        log_error "Build output directory 'dist' not found"
        exit 1
    fi
    
    # Verificar que contiene archivos
    local file_count=$(find dist -type f | wc -l)
    if [ "$file_count" -eq 0 ]; then
        log_error "Build output directory is empty"
        exit 1
    fi
    
    # Mostrar estadísticas del build
    local build_size=$(du -sh dist 2>/dev/null | cut -f1 || echo "unknown")
    log "✓ Build output: $file_count files ($build_size)"
    
    # Verificar archivos críticos
    local critical_files=("dist/index.html")
    for file in "${critical_files[@]}"; do
        if [ ! -f "$file" ]; then
            log_error "Critical build file missing: $file"
            exit 1
        fi
    done
    
    log "✓ Build verification completed"
}

# Función para limpiar archivos de desarrollo
cleanup_development_files() {
    local repo_dir="$1"
    
    log "Cleaning up development files..."
    cd "$repo_dir"
    
    # Remover archivos y directorios innecesarios para producción
    local cleanup_items=(
        "node_modules"
        ".git"
        "src"
        "e2e"
        "*.md"
        ".gitignore"
        ".editorconfig"
        "tsconfig.json"
        "angular.json"
        "karma.conf.js"
        "protractor.conf.js"
        "package.json"
        "package-lock.json"
    )
    
    for item in "${cleanup_items[@]}"; do
        if [ -e "$item" ]; then
            rm -rf "$item"
            log "  Removed: $item"
        fi
    done
    
    # Mantener solo el directorio dist y archivos de licencia
    log "✓ Development files cleaned up"
    
    # Mostrar el tamaño final
    local final_size=$(du -sh . 2>/dev/null | cut -f1 || echo "unknown")
    log "✓ Final package size: $final_size"
}

# Función para verificar el build
verify_build() {
    local repo_dir="$1"
    
    log "Verifying build output..."
    cd "$repo_dir"
    
    # Verificar estructura del build
    if [ ! -d "dist" ]; then
        log_error "Build output directory missing"
        exit 1
    fi
    
    # Verificar archivos críticos
    local critical_files=(
        "dist/index.html"
        "dist/main*.js"
        "dist/polyfills*.js"
        "dist/runtime*.js"
    )
    
    local missing_files=()
    for pattern in "${critical_files[@]}"; do
        if ! ls $pattern >/dev/null 2>&1; then
            missing_files+=("$pattern")
        fi
    done
    
    if [ ${#missing_files[@]} -gt 0 ]; then
        log_error "Critical build files missing:"
        for file in "${missing_files[@]}"; do
            log_error "  - $file"
        done
        exit 1
    fi
    
    # Verificar que index.html es válido
    if ! grep -q "<title>" "dist/index.html"; then
        log_error "Build output appears to be corrupted"
        exit 1
    fi
    
    log "✓ Build verification successful"
}

# Función principal
main() {
    log "=== Starting Alfresco Content App Build Process ==="
    
    # Verificar que el usuario actual puede escribir en /home/ubuntu
    if [ ! -w "/home/ubuntu" ]; then
        log_error "Cannot write to /home/ubuntu directory. Please check permissions."
        exit 1
    fi
    
    # Verificar recursos del sistema
    check_system_resources
    
    # Instalar Git
    install_git
    
    # Instalar Node.js y npm
    install_nodejs
    
    # Clonar repositorio
    local repo_dir
    repo_dir=$(clone_aca_repository)
    
    # Checkout versión más reciente
    local version
    version=$(checkout_latest_version "$repo_dir")
    
    # Instalar dependencias del proyecto
    install_project_dependencies "$repo_dir"
    
    # Configurar build
    configure_build "$repo_dir"
    
    # Construir aplicación
    build_application "$repo_dir"
    
    # Verificar build
    verify_build "$repo_dir"
    
    # Limpiar archivos de desarrollo (opcional)
    # cleanup_development_files "$repo_dir"
    
    # Configurar permisos finales
    chown -R ubuntu:ubuntu "$repo_dir"
    
    # Mostrar resumen
    log "=== Alfresco Content App Build Summary ==="
    log "Repository: $repo_dir"
    log "Version: $version"
    log "Build Output: $repo_dir/dist"
    log "Build Files: $(find "$repo_dir/dist" -type f | wc -l) files"
    log "Build Size: $(du -sh "$repo_dir/dist" 2>/dev/null | cut -f1 || echo 'unknown')"
    
    log "=== Next Steps ==="
    log "The built application is ready for deployment with Nginx"
    log "Run script 10-install_nginx.sh to complete the setup"
    log ""
    log "Build output location: $repo_dir/dist"
    log "Static files are ready to be served by a web server"
    
    log "🎉 Alfresco Content App build completed successfully!"
    
    # Test básico del build
    log "Performing basic build test..."
    if [ -f "$repo_dir/dist/index.html" ] && [ -s "$repo_dir/dist/index.html" ]; then
        log "✅ Build test passed - index.html is present and not empty"
    else
        log "⚠️  Build test warning - index.html may have issues"
    fi
}

# Ejecutar función principal
main "$@"