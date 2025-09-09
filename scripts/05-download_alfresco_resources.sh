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

# Función para validar descargas
validate_download() {
    local file="$1"
    local min_size="$2"
    local expected_extension="$3"
    
    log "Validating downloaded file: $(basename "$file")"
    
    # Verificar que el archivo existe
    if [ ! -f "$file" ]; then
        log_error "File does not exist: $file"
        return 1
    fi
    
    # Verificar tamaño del archivo
    local size=$(stat -c%s "$file" 2>/dev/null || stat -f%z "$file" 2>/dev/null || echo "0")
    if [ "$size" -lt "$min_size" ]; then
        log_error "File is too small ($size bytes, minimum $min_size): $(basename "$file")"
        return 1
    fi
    
    # Verificar extensión del archivo
    if [[ "$file" != *"$expected_extension" ]]; then
        log_error "File extension mismatch. Expected: $expected_extension, Got: $file"
        return 1
    fi
    
    # Verificar integridad básica según el tipo de archivo
    case "$expected_extension" in
        ".zip")
            if command_exists unzip; then
                if ! unzip -t "$file" >/dev/null 2>&1; then
                    log_error "ZIP file is corrupted: $(basename "$file")"
                    return 1
                fi
            fi
            ;;
        ".jar")
            if command_exists file; then
                if ! file "$file" | grep -q "Java archive"; then
                    log_error "JAR file appears to be corrupted: $(basename "$file")"
                    return 1
                fi
            fi
            ;;
    esac
    
    log "✓ File validated successfully: $(basename "$file") ($size bytes)"
    return 0
}

# Función para obtener la versión más reciente con múltiples estrategias
get_latest_version() {
    local base_url="$1"
    local component_name="$2"
    local timeout="${3:-20}"
    local fallback_version="$4"
    
    log "Fetching latest version for $component_name..."
    
    local latest_version=""
    local attempts=0
    local max_attempts=3
    
    while [ $attempts -lt $max_attempts ] && [ -z "$latest_version" ]; do
        attempts=$((attempts + 1))
        log "Attempt $attempts/$max_attempts for $component_name version detection..."
        
        # Estrategia 1: Usar curl con parsing mejorado
        if command_exists curl && [ -z "$latest_version" ]; then
            latest_version=$(curl --connect-timeout 10 --max-time $timeout -s "$base_url" 2>/dev/null | \
                sed -n 's/.*<a href="\([0-9]\+\.[0-9]\+\.[0-9]\+\)\/">.*/\1/p' | \
                sort -V | \
                tail -n 1 || echo "")
        fi
        
        # Estrategia 2: Usar wget si curl falla
        if command_exists wget && [ -z "$latest_version" ]; then
            latest_version=$(wget --timeout=$timeout --tries=1 -qO- "$base_url" 2>/dev/null | \
                sed -n 's/.*<a href="\([0-9]\+\.[0-9]\+\.[0-9]\+\)\/">.*/\1/p' | \
                sort -V | \
                tail -n 1 || echo "")
        fi
        
        # Verificar que la versión obtenida es válida
        if [[ "$latest_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            log "✓ Latest $component_name version found: $latest_version"
            echo "$latest_version"
            return 0
        else
            latest_version=""
            if [ $attempts -lt $max_attempts ]; then
                log "Invalid version detected, retrying in 5 seconds..."
                sleep 5
            fi
        fi
    done
    
    # Usar versión de fallback si no se puede obtener la más reciente
    log "⚠️  Could not fetch latest $component_name version, using fallback: $fallback_version"
    echo "$fallback_version"
}

# Función mejorada para descargar archivos con reintentos y validación
download_file() {
    local url="$1"
    local dest_dir="$2"
    local min_size="$3"
    local expected_extension="$4"
    local max_retries="${5:-3}"
    
    local filename=$(basename "$url")
    local filepath="$dest_dir/$filename"
    local temp_filepath="${filepath}.tmp"
    
    log "Downloading $filename..."
    
    # Crear directorio si no existe
    mkdir -p "$dest_dir"
    
    local retry=0
    while [ $retry -lt $max_retries ]; do
        retry=$((retry + 1))
        log "Download attempt $retry/$max_retries for $filename..."
        
        # Limpiar archivo temporal si existe
        [ -f "$temp_filepath" ] && rm -f "$temp_filepath"
        
        # Intentar descarga con curl primero
        local download_success=false
        if command_exists curl; then
            if curl -L -f --connect-timeout 30 --max-time 600 --retry 2 \
                   -o "$temp_filepath" \
                   -w "HTTP Status: %{http_code}, Size: %{size_download} bytes\n" \
                   "$url"; then
                download_success=true
            fi
        elif command_exists wget; then
            if wget --timeout=600 --tries=2 -O "$temp_filepath" "$url"; then
                download_success=true
            fi
        else
            log_error "Neither curl nor wget is available for downloading"
            return 1
        fi
        
        # Verificar descarga y mover archivo si es válido
        if [ "$download_success" = true ] && validate_download "$temp_filepath" "$min_size" "$expected_extension"; then
            mv "$temp_filepath" "$filepath"
            log "✅ Successfully downloaded: $filename"
            return 0
        else
            log "❌ Download or validation failed for $filename (attempt $retry)"
            [ -f "$temp_filepath" ] && rm -f "$temp_filepath"
            
            if [ $retry -lt $max_retries ]; then
                local wait_time=$((retry * 10))
                log "Retrying in $wait_time seconds..."
                sleep $wait_time
            fi
        fi
    done
    
    log_error "Failed to download $filename after $max_retries attempts"
    return 1
}

# Función para verificar conectividad de red
check_network_connectivity() {
    log "Checking network connectivity..."
    
    local test_urls=(
        "https://www.google.com"
        "https://nexus.alfresco.com"
        "https://dlcdn.apache.org"
    )
    
    for url in "${test_urls[@]}"; do
        if command_exists curl; then
            if curl --connect-timeout 10 --max-time 15 -s -o /dev/null "$url"; then
                log "✓ Network connectivity verified via $url"
                return 0
            fi
        elif command_exists wget; then
            if wget --timeout=15 --tries=1 -q --spider "$url"; then
                log "✓ Network connectivity verified via $url"
                return 0
            fi
        fi
    done
    
    log_error "Network connectivity check failed"
    return 1
}

# Función para crear checksum de archivos descargados
create_checksums() {
    local download_dir="$1"
    local checksum_file="$download_dir/checksums.md5"
    
    log "Creating checksums for downloaded files..."
    
    if command_exists md5sum; then
        (cd "$download_dir" && md5sum *.zip *.jar 2>/dev/null > "$checksum_file" || true)
        if [ -f "$checksum_file" ] && [ -s "$checksum_file" ]; then
            log "✓ Checksums created: $checksum_file"
        fi
    else
        log "⚠️  md5sum not available, skipping checksum creation"
    fi
}

# Configuración principal
DOWNLOAD_DIR="./downloads"
VERSIONS_FILE="$DOWNLOAD_DIR/versions.txt"

# URLs base para los componentes
ALFRESCO_CONTENT_BASE_URL="https://nexus.alfresco.com/nexus/service/rest/repository/browse/releases/org/alfresco/alfresco-content-services-community-distribution/"
ALFRESCO_SEARCH_BASE_URL="https://nexus.alfresco.com/nexus/service/rest/repository/browse/releases/org/alfresco/alfresco-search-services/"
ALFRESCO_TRANSFORM_CORE_BASE_URL="https://nexus.alfresco.com/nexus/service/rest/repository/browse/releases/org/alfresco/alfresco-transform-core-aio/"

# Versiones de fallback conocidas y estables
FALLBACK_CONTENT_VERSION="25.1.0"
FALLBACK_SEARCH_VERSION="2.1.0"
FALLBACK_TRANSFORM_VERSION="5.1.7"

# Tamaños mínimos esperados (en bytes)
MIN_CONTENT_SIZE=104857600     # ~100MB
MIN_SEARCH_SIZE=52428800       # ~50MB
MIN_TRANSFORM_SIZE=10485760    # ~10MB

log "=== Starting Alfresco Resources Download ==="

# Verificar prerrequisitos
if ! command_exists curl && ! command_exists wget; then
    log_error "Neither curl nor wget is available. Installing wget..."
    sudo apt update && sudo apt install -y wget curl
fi

# Verificar conectividad de red
check_network_connectivity || {
    log_error "Network connectivity issues detected. Please check your internet connection."
    exit 1
}

# Crear directorio de descarga
mkdir -p "$DOWNLOAD_DIR"

# Obtener las versiones más recientes
log "=== Fetching Latest Versions ==="
latest_content_version=$(get_latest_version "$ALFRESCO_CONTENT_BASE_URL" "Alfresco Content Services" 30 "$FALLBACK_CONTENT_VERSION")
latest_search_version=$(get_latest_version "$ALFRESCO_SEARCH_BASE_URL" "Alfresco Search Services" 30 "$FALLBACK_SEARCH_VERSION")
latest_transform_version=$(get_latest_version "$ALFRESCO_TRANSFORM_CORE_BASE_URL" "Alfresco Transform Core" 30 "$FALLBACK_TRANSFORM_VERSION")

log "=== Versions to Download ==="
log "Content Services: $latest_content_version"
log "Search Services: $latest_search_version"
log "Transform Core: $latest_transform_version"

# Construir URLs de descarga
content_url="https://nexus.alfresco.com/nexus/repository/releases/org/alfresco/alfresco-content-services-community-distribution/$latest_content_version/alfresco-content-services-community-distribution-$latest_content_version.zip"
search_url="https://nexus.alfresco.com/nexus/repository/releases/org/alfresco/alfresco-search-services/$latest_search_version/alfresco-search-services-$latest_search_version.zip"
transform_url="https://nexus.alfresco.com/nexus/repository/releases/org/alfresco/alfresco-transform-core-aio/$latest_transform_version/alfresco-transform-core-aio-$latest_transform_version.jar"

# Definir descargas con sus parámetros
declare -a downloads=(
    "$content_url|$MIN_CONTENT_SIZE|.zip"
    "$search_url|$MIN_SEARCH_SIZE|.zip"
    "$transform_url|$MIN_TRANSFORM_SIZE|.jar"
)

# Realizar descargas
log "=== Starting Downloads ==="
failed_downloads=()
successful_downloads=()

for download_info in "${downloads[@]}"; do
    IFS='|' read -r url min_size extension <<< "$download_info"
    filename=$(basename "$url")
    
    # Verificar si el archivo ya existe y es válido
    if [ -f "$DOWNLOAD_DIR/$filename" ]; then
        log "File already exists: $filename"
        if validate_download "$DOWNLOAD_DIR/$filename" "$min_size" "$extension"; then
            log "✓ Existing file is valid, skipping download: $filename"
            successful_downloads+=("$filename")
            continue
        else
            log "⚠️  Existing file is invalid, re-downloading: $filename"
            rm -f "$DOWNLOAD_DIR/$filename"
        fi
    fi
    
    # Descargar archivo
    if download_file "$url" "$DOWNLOAD_DIR" "$min_size" "$extension"; then
        successful_downloads+=("$filename")
    else
        failed_downloads+=("$filename")
    fi
done

# Crear archivo de versiones para referencia
log "Creating versions reference file..."
cat > "$VERSIONS_FILE" << EOF
# Alfresco Components Versions Downloaded
# Generated on: $(date '+%Y-%m-%d %H:%M:%S')

alfresco_content_version=$latest_content_version
alfresco_search_version=$latest_search_version
alfresco_transform_version=$latest_transform_version

# Download URLs used
content_url=$content_url
search_url=$search_url
transform_url=$transform_url

# Download statistics
successful_downloads=${#successful_downloads[@]}
failed_downloads=${#failed_downloads[@]}
total_downloads=$((${#successful_downloads[@]} + ${#failed_downloads[@]}))

# File listing
EOF

# Añadir información de archivos descargados
if [ ${#successful_downloads[@]} -gt 0 ]; then
    echo "# Successfully downloaded files:" >> "$VERSIONS_FILE"
    for file in "${successful_downloads[@]}"; do
        if [ -f "$DOWNLOAD_DIR/$file" ]; then
            size=$(stat -c%s "$DOWNLOAD_DIR/$file" 2>/dev/null || stat -f%z "$DOWNLOAD_DIR/$file" 2>/dev/null || echo "unknown")
            echo "# - $file ($size bytes)" >> "$VERSIONS_FILE"
        fi
    done
fi

# Crear checksums
create_checksums "$DOWNLOAD_DIR"

# Verificar resultados finales
log "=== Download Summary ==="
log "Successful downloads: ${#successful_downloads[@]}"
log "Failed downloads: ${#failed_downloads[@]}"

if [ ${#successful_downloads[@]} -gt 0 ]; then
    log "✅ Successfully downloaded:"
    for file in "${successful_downloads[@]}"; do
        log "  - $file"
    done
fi

if [ ${#failed_downloads[@]} -gt 0 ]; then
    log "❌ Failed downloads:"
    for file in "${failed_downloads[@]}"; do
        log "  - $file"
    done
fi

# Mostrar información del directorio de descarga
log "=== Download Directory Contents ==="
ls -la "$DOWNLOAD_DIR"

# Mostrar espacio en disco usado
if command_exists du; then
    total_size=$(du -sh "$DOWNLOAD_DIR" | cut -f1)
    log "Total download size: $total_size"
fi

# Resultado final
if [ ${#failed_downloads[@]} -eq 0 ]; then
    log "🎉 All downloads completed successfully!"
    log "Downloads are ready for installation."
    log "Versions file created: $VERSIONS_FILE"
    exit 0
else
    log_error "Some downloads failed. Please check network connectivity and try again."
    log "You can re-run this script to retry failed downloads."
    exit 1
fi