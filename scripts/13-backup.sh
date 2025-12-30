#!/bin/bash
# =============================================================================
# Alfresco Backup Script
# =============================================================================
# Creates a complete backup of an Alfresco installation including:
# - PostgreSQL database
# - Content store (alf_data)
# - Solr indexes (optional)
# - Configuration files
#
# Backup Types:
# - full:   Complete backup of all components (default)
# - db:     Database only
# - content: Content store only
# - config: Configuration files only
# - solr:   Solr indexes only
#
# Usage:
#   bash scripts/13-backup.sh [options]
#
# Options:
#   --type TYPE       Backup type: full|db|content|config|solr (default: full)
#   --output DIR      Output directory (default: /home/ubuntu/backups)
#   --name NAME       Backup name prefix (default: alfresco-backup)
#   --no-solr         Skip Solr indexes in full backup
#   --hot             Hot backup (services remain running) - CAUTION
#   --compress        Compress backup with gzip (default: true)
#   --no-compress     Skip compression
#   --keep DAYS       Keep backups for N days, delete older (default: 30)
#   --quiet           Minimal output
#
# Examples:
#   bash scripts/13-backup.sh                           # Full backup
#   bash scripts/13-backup.sh --type db                 # Database only
#   bash scripts/13-backup.sh --output /mnt/backup      # Custom location
#   bash scripts/13-backup.sh --no-solr --keep 7        # Skip Solr, keep 7 days
# =============================================================================

# Load common functions and configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
BACKUP_TYPE="full"
BACKUP_OUTPUT_DIR=""
BACKUP_NAME="alfresco-backup"
INCLUDE_SOLR="true"
HOT_BACKUP="false"
COMPRESS="true"
KEEP_DAYS="30"
QUIET="false"

# Will be set after loading config
BACKUP_DIR=""
BACKUP_TIMESTAMP=""
BACKUP_MANIFEST=""

# -----------------------------------------------------------------------------
# Parse Arguments
# -----------------------------------------------------------------------------
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --type)
                BACKUP_TYPE="$2"
                if [[ ! "$BACKUP_TYPE" =~ ^(full|db|content|config|solr)$ ]]; then
                    log_error "Invalid backup type: $BACKUP_TYPE"
                    log_error "Valid types: full, db, content, config, solr"
                    exit 1
                fi
                shift 2
                ;;
            --output)
                BACKUP_OUTPUT_DIR="$2"
                shift 2
                ;;
            --name)
                BACKUP_NAME="$2"
                shift 2
                ;;
            --no-solr)
                INCLUDE_SOLR="false"
                shift
                ;;
            --hot)
                HOT_BACKUP="true"
                shift
                ;;
            --compress)
                COMPRESS="true"
                shift
                ;;
            --no-compress)
                COMPRESS="false"
                shift
                ;;
            --keep)
                KEEP_DAYS="$2"
                shift 2
                ;;
            --quiet)
                QUIET="true"
                shift
                ;;
            --help|-h)
                show_help
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                echo "Use --help for usage information"
                exit 1
                ;;
        esac
    done
}

show_help() {
    head -50 "$0" | grep -E "^#" | sed 's/^# //' | sed 's/^#//'
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
    parse_args "$@"
    
    log_step "Starting Alfresco backup..."
    log_info "Backup type: $BACKUP_TYPE"
    
    # Load configuration
    load_config 2>/dev/null || {
        log_warn "Configuration not loaded, using defaults"
        ALFRESCO_HOME="${ALFRESCO_HOME:-/home/ubuntu}"
        ALFRESCO_USER="${ALFRESCO_USER:-ubuntu}"
        ALFRESCO_DB_NAME="${ALFRESCO_DB_NAME:-alfresco}"
        ALFRESCO_DB_USER="${ALFRESCO_DB_USER:-alfresco}"
        ALFRESCO_DB_HOST="${ALFRESCO_DB_HOST:-localhost}"
    }
    
    # Set backup output directory
    BACKUP_OUTPUT_DIR="${BACKUP_OUTPUT_DIR:-${ALFRESCO_HOME}/backups}"
    
    # Initialize backup
    init_backup
    
    # Check services status
    check_services_status
    
    # Perform backup based on type
    case "$BACKUP_TYPE" in
        full)
            backup_database
            backup_content_store
            backup_configuration
            [ "$INCLUDE_SOLR" = "true" ] && backup_solr_indexes
            ;;
        db)
            backup_database
            ;;
        content)
            backup_content_store
            ;;
        config)
            backup_configuration
            ;;
        solr)
            backup_solr_indexes
            ;;
    esac
    
    # Finalize backup
    finalize_backup
    
    # Cleanup old backups
    cleanup_old_backups
    
    # Display summary
    display_summary
}

# -----------------------------------------------------------------------------
# Initialize Backup
# -----------------------------------------------------------------------------
init_backup() {
    log_step "Initializing backup..."
    
    # Create timestamp
    BACKUP_TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    
    # Create backup directory
    BACKUP_DIR="${BACKUP_OUTPUT_DIR}/${BACKUP_NAME}_${BACKUP_TIMESTAMP}"
    
    if ! mkdir -p "$BACKUP_DIR"; then
        log_error "Failed to create backup directory: $BACKUP_DIR"
        exit 1
    fi
    
    # Initialize manifest
    BACKUP_MANIFEST="${BACKUP_DIR}/manifest.txt"
    
    cat > "$BACKUP_MANIFEST" << EOF
# Alfresco Backup Manifest
# ========================
backup_name=${BACKUP_NAME}
backup_type=${BACKUP_TYPE}
backup_timestamp=${BACKUP_TIMESTAMP}
backup_date=$(date '+%Y-%m-%d %H:%M:%S %Z')
alfresco_home=${ALFRESCO_HOME}
hostname=$(hostname)
include_solr=${INCLUDE_SOLR}
hot_backup=${HOT_BACKUP}
compressed=${COMPRESS}

# Components
# ----------
EOF
    
    log_info "Backup directory: $BACKUP_DIR"
}

# -----------------------------------------------------------------------------
# Check Services Status
# -----------------------------------------------------------------------------
check_services_status() {
    log_step "Checking services status..."
    
    local services_running=0
    
    for service in postgresql tomcat solr; do
        if systemctl is-active --quiet "$service" 2>/dev/null; then
            log_info "$service is running"
            ((services_running++))
        else
            log_info "$service is stopped"
        fi
    done
    
    if [ "$HOT_BACKUP" = "false" ] && [ $services_running -gt 0 ]; then
        log_warn "Services are running. For consistent backup, stop services first:"
        log_warn "  bash scripts/12-stop_services.sh"
        log_warn ""
        log_warn "Or use --hot for hot backup (may have consistency issues)"
        echo ""
        read -p "Continue with hot backup? [y/N] " -n 1 -r
        echo ""
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "Backup cancelled"
            rm -rf "$BACKUP_DIR"
            exit 0
        fi
        HOT_BACKUP="true"
    fi
    
    echo "hot_backup_confirmed=${HOT_BACKUP}" >> "$BACKUP_MANIFEST"
}

# -----------------------------------------------------------------------------
# Backup Database
# -----------------------------------------------------------------------------
backup_database() {
    log_step "Backing up PostgreSQL database..."
    
    local db_backup_file="${BACKUP_DIR}/database_${ALFRESCO_DB_NAME}.sql"
    local pg_was_stopped="false"
    
    # Create a temporary directory for postgres user to write to
    local pg_temp_dir="/tmp/alfresco_backup_$$"
    mkdir -p "$pg_temp_dir"
    chmod 777 "$pg_temp_dir"
    
    # Check if PostgreSQL is accessible
    if ! sudo -u postgres pg_isready -q 2>/dev/null; then
        # Try to check if it's running but we can connect differently
        if ! systemctl is-active --quiet postgresql 2>/dev/null; then
            log_warn "PostgreSQL is not running."
            log_info "Temporarily starting PostgreSQL for database backup..."
            
            if sudo systemctl start postgresql; then
                pg_was_stopped="true"
                # Wait for PostgreSQL to be ready
                local attempts=0
                while ! sudo -u postgres pg_isready -q 2>/dev/null; do
                    ((attempts++))
                    if [ $attempts -ge 30 ]; then
                        log_error "PostgreSQL failed to start within 30 seconds"
                        rm -rf "$pg_temp_dir"
                        exit 1
                    fi
                    sleep 1
                done
                log_info "PostgreSQL started successfully"
            else
                log_error "Failed to start PostgreSQL. Cannot backup database."
                log_error "Start PostgreSQL manually or skip database backup with --type content"
                rm -rf "$pg_temp_dir"
                exit 1
            fi
        fi
    fi
    
    log_info "Dumping database: $ALFRESCO_DB_NAME"
    
    # Perform database dump to temp directory (postgres user can write there)
    local temp_dump="${pg_temp_dir}/database_${ALFRESCO_DB_NAME}.sql"
    
    if sudo -u postgres pg_dump \
        --verbose \
        --format=custom \
        --file="${temp_dump}.dump" \
        "$ALFRESCO_DB_NAME" 2>"${BACKUP_DIR}/database_backup.log"; then
        
        log_info "Database dump completed"
        
        # Also create a plain SQL backup for portability
        log_info "Creating plain SQL backup..."
        sudo -u postgres pg_dump \
            --format=plain \
            --file="$temp_dump" \
            "$ALFRESCO_DB_NAME" 2>>"${BACKUP_DIR}/database_backup.log"
        
        # Move dumps to backup directory
        mv "${temp_dump}.dump" "${db_backup_file}.dump"
        mv "$temp_dump" "$db_backup_file"
        
        # Get database size
        local db_size
        db_size=$(sudo -u postgres psql -tAc "SELECT pg_size_pretty(pg_database_size('$ALFRESCO_DB_NAME'));" 2>/dev/null)
        
        log_info "Database size: $db_size"
        
        {
            echo "database=${ALFRESCO_DB_NAME}"
            echo "database_size=${db_size}"
            echo "database_dump=${db_backup_file}.dump"
            echo "database_sql=${db_backup_file}"
        } >> "$BACKUP_MANIFEST"
    else
        log_error "Database backup failed. Check ${BACKUP_DIR}/database_backup.log"
        # Stop PostgreSQL if we started it
        if [ "$pg_was_stopped" = "true" ]; then
            log_info "Stopping PostgreSQL (was started for backup)..."
            sudo systemctl stop postgresql
        fi
        rm -rf "$pg_temp_dir"
        exit 1
    fi
    
    # Cleanup temp directory
    rm -rf "$pg_temp_dir"
    
    # Stop PostgreSQL if we started it for the backup
    if [ "$pg_was_stopped" = "true" ]; then
        log_info "Stopping PostgreSQL (was started for backup)..."
        sudo systemctl stop postgresql
    fi
}

# -----------------------------------------------------------------------------
# Backup Content Store
# -----------------------------------------------------------------------------
backup_content_store() {
    log_step "Backing up content store..."
    
    local alf_data="${ALFRESCO_HOME}/alf_data"
    local content_backup="${BACKUP_DIR}/alf_data"
    
    if [ ! -d "$alf_data" ]; then
        log_error "Content store not found: $alf_data"
        exit 1
    fi
    
    # Get content store size
    local content_size
    content_size=$(sudo du -sh "$alf_data" 2>/dev/null | cut -f1)
    log_info "Content store size: $content_size"
    
    # Check available disk space
    local available_space
    available_space=$(df -h "$BACKUP_OUTPUT_DIR" | awk 'NR==2 {print $4}')
    log_info "Available disk space: $available_space"
    
    log_info "Copying content store (this may take a while)..."
    
    # Use rsync for efficient copy with progress
    local rsync_result=0
    if command -v rsync &>/dev/null; then
        if [ "$QUIET" = "true" ]; then
            sudo rsync -a "$alf_data/" "$content_backup/" 2>"${BACKUP_DIR}/content_backup.log" || rsync_result=$?
        else
            sudo rsync -a --info=progress2 "$alf_data/" "$content_backup/" 2>"${BACKUP_DIR}/content_backup.log" || rsync_result=$?
        fi
    else
        sudo cp -a "$alf_data" "$content_backup" 2>"${BACKUP_DIR}/content_backup.log" || rsync_result=$?
    fi
    
    if [ $rsync_result -eq 0 ]; then
        log_info "Content store backup completed"
        echo "content_store=${content_backup}" >> "$BACKUP_MANIFEST"
        echo "content_store_size=${content_size}" >> "$BACKUP_MANIFEST"
    else
        log_error "Content store backup failed. Check ${BACKUP_DIR}/content_backup.log"
        exit 1
    fi
}

# -----------------------------------------------------------------------------
# Backup Configuration
# -----------------------------------------------------------------------------
backup_configuration() {
    log_step "Backing up configuration files..."
    
    local config_backup="${BACKUP_DIR}/config"
    mkdir -p "$config_backup"
    
    # Define configuration files/directories to backup
    local configs=(
        "${ALFRESCO_HOME}/tomcat/shared/classes/alfresco-global.properties"
        "${ALFRESCO_HOME}/tomcat/shared/classes/alfresco"
        "${ALFRESCO_HOME}/tomcat/conf/server.xml"
        "${ALFRESCO_HOME}/tomcat/conf/catalina.properties"
        "${ALFRESCO_HOME}/tomcat/bin/setenv.sh"
        "${ALFRESCO_HOME}/alfresco-search-services/solrhome/conf"
        "${ALFRESCO_HOME}/alfresco-search-services/solr.in.sh"
        "${ALFRESCO_HOME}/activemq/conf"
        "${ALFRESCO_HOME}/transform/application.properties"
        "${ALFRESCO_HOME}/keystore"
        "/etc/nginx/sites-available/alfresco"
        "/etc/systemd/system/tomcat.service"
        "/etc/systemd/system/solr.service"
        "/etc/systemd/system/activemq.service"
        "/etc/systemd/system/transform.service"
        "${CONFIG_DIR}/alfresco.env"
        "${CONFIG_DIR}/versions.conf"
    )
    
    local backed_up=0
    
    for config in "${configs[@]}"; do
        if sudo test -e "$config"; then
            # Preserve directory structure
            local relative_path="${config#/}"
            local target_dir
            target_dir="${config_backup}/$(dirname "$relative_path")"
            mkdir -p "$target_dir"
            
            if sudo cp -a "$config" "$target_dir/" 2>/dev/null; then
                log_info "Backed up: $config"
                ((backed_up++))
            else
                log_warn "Failed to backup: $config"
            fi
        fi
    done
    
    echo "config_files_count=${backed_up}" >> "$BACKUP_MANIFEST"
    echo "config_backup=${config_backup}" >> "$BACKUP_MANIFEST"
    
    log_info "Configuration backup completed ($backed_up files/directories)"
}

# -----------------------------------------------------------------------------
# Backup Solr Indexes
# -----------------------------------------------------------------------------
backup_solr_indexes() {
    log_step "Backing up Solr indexes..."
    
    local solr_home="${ALFRESCO_HOME}/alfresco-search-services"
    local solr_data="${solr_home}/solrhome"
    local solr_backup="${BACKUP_DIR}/solr"
    
    if [ ! -d "$solr_data" ]; then
        log_warn "Solr data directory not found: $solr_data"
        log_warn "Skipping Solr backup"
        return 0
    fi
    
    # Check if Solr is running - recommend snapshot for hot backup
    if systemctl is-active --quiet solr 2>/dev/null && [ "$HOT_BACKUP" = "true" ]; then
        log_info "Solr is running - attempting to create snapshot first..."
        
        # Try to create a snapshot via Solr API
        local snapshot_name="backup_${BACKUP_TIMESTAMP}"
        for core in alfresco archive; do
            local snapshot_url="http://${SOLR_HOST:-localhost}:${SOLR_PORT:-8983}/solr/${core}/replication?command=backup&name=${snapshot_name}"
            if curl -sf -H "X-Alfresco-Search-Secret: ${SOLR_SHARED_SECRET:-secret}" "$snapshot_url" >/dev/null 2>&1; then
                log_info "Created snapshot for ${core} core"
            fi
        done
        sleep 5  # Wait for snapshot to complete
    fi
    
    # Get Solr index size
    local solr_size
    solr_size=$(sudo du -sh "$solr_data" 2>/dev/null | cut -f1)
    log_info "Solr data size: $solr_size"
    
    log_info "Copying Solr indexes (this may take a while)..."
    
    mkdir -p "$solr_backup"
    
    local solr_rsync_result=0
    if command -v rsync &>/dev/null; then
        if [ "$QUIET" = "true" ]; then
            sudo rsync -a "$solr_data/" "$solr_backup/" 2>"${BACKUP_DIR}/solr_backup.log" || solr_rsync_result=$?
        else
            sudo rsync -a --info=progress2 "$solr_data/" "$solr_backup/" 2>"${BACKUP_DIR}/solr_backup.log" || solr_rsync_result=$?
        fi
    else
        sudo cp -a "$solr_data"/* "$solr_backup/" 2>"${BACKUP_DIR}/solr_backup.log" || solr_rsync_result=$?
    fi
    
    if [ $solr_rsync_result -eq 0 ]; then
        log_info "Solr backup completed"
        echo "solr_backup=${solr_backup}" >> "$BACKUP_MANIFEST"
        echo "solr_size=${solr_size}" >> "$BACKUP_MANIFEST"
    else
        log_warn "Solr backup may be incomplete. Check ${BACKUP_DIR}/solr_backup.log"
    fi
}

# -----------------------------------------------------------------------------
# Finalize Backup
# -----------------------------------------------------------------------------
finalize_backup() {
    log_step "Finalizing backup..."
    
    # Add completion timestamp to manifest
    {
        echo ""
        echo "# Completion"
        echo "# ----------"
        echo "completed_at=$(date '+%Y-%m-%d %H:%M:%S %Z')"
    } >> "$BACKUP_MANIFEST"
    
    # Calculate backup size
    local backup_size
    backup_size=$(du -sh "$BACKUP_DIR" | cut -f1)
    echo "total_size_uncompressed=${backup_size}" >> "$BACKUP_MANIFEST"
    
    # Compress if requested
    if [ "$COMPRESS" = "true" ]; then
        log_info "Compressing backup..."
        
        local archive_file="${BACKUP_OUTPUT_DIR}/${BACKUP_NAME}_${BACKUP_TIMESTAMP}.tar.gz"
        
        cd "$BACKUP_OUTPUT_DIR" || exit 1
        
        if tar -czf "$archive_file" "$(basename "$BACKUP_DIR")" 2>"${BACKUP_DIR}/compress.log"; then
            local compressed_size
            compressed_size=$(du -sh "$archive_file" | cut -f1)
            
            log_info "Backup compressed: $archive_file ($compressed_size)"
            
            # Remove uncompressed directory
            rm -rf "$BACKUP_DIR"
            
            BACKUP_DIR="$archive_file"
            echo "compressed_file=${archive_file}" >> "$BACKUP_MANIFEST" 2>/dev/null || true
            echo "compressed_size=${compressed_size}" >> "$BACKUP_MANIFEST" 2>/dev/null || true
        else
            log_warn "Compression failed, keeping uncompressed backup"
            COMPRESS="false"
        fi
    fi
    
    # Set permissions
    sudo chown -R "${ALFRESCO_USER:-$USER}:${ALFRESCO_USER:-$USER}" "$BACKUP_DIR" 2>/dev/null || true
    
    log_info "Backup finalized"
}

# -----------------------------------------------------------------------------
# Cleanup Old Backups
# -----------------------------------------------------------------------------
cleanup_old_backups() {
    if [ "$KEEP_DAYS" -le 0 ]; then
        return 0
    fi
    
    log_step "Cleaning up backups older than $KEEP_DAYS days..."
    
    local deleted=0
    
    # Find and delete old backup directories
    while IFS= read -r -d '' old_backup; do
        log_info "Removing old backup: $(basename "$old_backup")"
        rm -rf "$old_backup"
        ((deleted++))
    done < <(find "$BACKUP_OUTPUT_DIR" -maxdepth 1 -name "${BACKUP_NAME}_*" -type d -mtime +"$KEEP_DAYS" -print0 2>/dev/null)
    
    # Find and delete old backup archives
    while IFS= read -r -d '' old_archive; do
        log_info "Removing old archive: $(basename "$old_archive")"
        rm -f "$old_archive"
        ((deleted++))
    done < <(find "$BACKUP_OUTPUT_DIR" -maxdepth 1 -name "${BACKUP_NAME}_*.tar.gz" -type f -mtime +"$KEEP_DAYS" -print0 2>/dev/null)
    
    if [ $deleted -gt 0 ]; then
        log_info "Removed $deleted old backup(s)"
    else
        log_info "No old backups to remove"
    fi
}

# -----------------------------------------------------------------------------
# Display Summary
# -----------------------------------------------------------------------------
display_summary() {
    log_step "Backup Summary"
    
    echo ""
    echo "┌─────────────────────────────────────────────────────────────┐"
    echo "│                    BACKUP COMPLETE                          │"
    echo "├─────────────────────────────────────────────────────────────┤"
    printf "│ %-59s │\n" "Type: $BACKUP_TYPE"
    printf "│ %-59s │\n" "Location: $BACKUP_DIR"
    
    if [ "$COMPRESS" = "true" ]; then
        local size
        size=$(du -sh "$BACKUP_DIR" 2>/dev/null | cut -f1)
        printf "│ %-59s │\n" "Size: $size (compressed)"
    fi
    
    printf "│ %-59s │\n" "Timestamp: $BACKUP_TIMESTAMP"
    
    if [ "$HOT_BACKUP" = "true" ]; then
        printf "│ %-59s │\n" "Warning: Hot backup (verify consistency)"
    fi
    
    echo "└─────────────────────────────────────────────────────────────┘"
    echo ""
    
    log_info "Backup completed successfully!"
    
    if [ "$BACKUP_TYPE" = "full" ]; then
        echo ""
        log_info "To restore this backup, use:"
        log_info "  bash scripts/14-restore.sh --backup $BACKUP_DIR"
    fi
}

# -----------------------------------------------------------------------------
# Run Main
# -----------------------------------------------------------------------------
main "$@"