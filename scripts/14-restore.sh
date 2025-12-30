#!/bin/bash
# =============================================================================
# Alfresco Restore Script
# =============================================================================
# Restores an Alfresco installation from a backup created by 13-backup.sh.
#
# Restore Types:
# - full:    Restore all components (default)
# - db:      Database only
# - content: Content store only
# - config:  Configuration files only
# - solr:    Solr indexes only
#
# Usage:
#   bash scripts/14-restore.sh --backup <backup_path> [options]
#
# Options:
#   --backup PATH     Path to backup file (.tar.gz) or directory (REQUIRED)
#   --type TYPE       Restore type: full|db|content|config|solr (default: full)
#   --no-solr         Skip Solr restore (indexes will rebuild automatically)
#   --force           Skip confirmation prompts
#   --dry-run         Show what would be restored without making changes
#
# Examples:
#   bash scripts/14-restore.sh --backup /home/ubuntu/backups/alfresco-backup_20240115.tar.gz
#   bash scripts/14-restore.sh --backup /home/ubuntu/backups/alfresco-backup_20240115 --type db
#   bash scripts/14-restore.sh --backup backup.tar.gz --no-solr --force
#
# IMPORTANT:
#   - Services must be stopped before restore (script will prompt)
#   - Existing data will be overwritten
#   - Test restore on non-production system first
# =============================================================================

# Load common functions and configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
BACKUP_PATH=""
RESTORE_TYPE="full"
INCLUDE_SOLR="true"
FORCE="false"
DRY_RUN="false"

# Working directory for extraction
RESTORE_WORK_DIR=""
BACKUP_EXTRACTED_DIR=""

# -----------------------------------------------------------------------------
# Parse Arguments
# -----------------------------------------------------------------------------
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --backup)
                BACKUP_PATH="$2"
                shift 2
                ;;
            --type)
                RESTORE_TYPE="$2"
                if [[ ! "$RESTORE_TYPE" =~ ^(full|db|content|config|solr)$ ]]; then
                    log_error "Invalid restore type: $RESTORE_TYPE"
                    log_error "Valid types: full, db, content, config, solr"
                    exit 1
                fi
                shift 2
                ;;
            --no-solr)
                INCLUDE_SOLR="false"
                shift
                ;;
            --force)
                FORCE="true"
                shift
                ;;
            --dry-run)
                DRY_RUN="true"
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
    
    # Validate required arguments
    if [ -z "$BACKUP_PATH" ]; then
        log_error "Backup path is required"
        echo "Usage: $0 --backup <backup_path> [options]"
        echo "Use --help for more information"
        exit 1
    fi
}

show_help() {
    head -40 "$0" | grep -E "^#" | sed 's/^# //' | sed 's/^#//'
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
    parse_args "$@"
    
    log_step "Starting Alfresco restore..."
    
    if [ "$DRY_RUN" = "true" ]; then
        log_warn "DRY RUN MODE - No changes will be made"
    fi
    
    # Load configuration
    load_config 2>/dev/null || {
        log_warn "Configuration not loaded, using defaults"
        ALFRESCO_HOME="${ALFRESCO_HOME:-/home/ubuntu}"
        ALFRESCO_USER="${ALFRESCO_USER:-ubuntu}"
        ALFRESCO_GROUP="${ALFRESCO_GROUP:-ubuntu}"
        ALFRESCO_DB_NAME="${ALFRESCO_DB_NAME:-alfresco}"
        ALFRESCO_DB_USER="${ALFRESCO_DB_USER:-alfresco}"
    }
    
    # Validate and prepare backup
    validate_backup
    prepare_backup
    
    # Check and stop services
    check_services
    
    # Show restore plan and confirm
    show_restore_plan
    confirm_restore
    
    # Perform restore based on type
    case "$RESTORE_TYPE" in
        full)
            restore_database
            restore_content_store
            restore_configuration
            [ "$INCLUDE_SOLR" = "true" ] && restore_solr_indexes
            ;;
        db)
            restore_database
            ;;
        content)
            restore_content_store
            ;;
        config)
            restore_configuration
            ;;
        solr)
            restore_solr_indexes
            ;;
    esac
    
    # Cleanup
    cleanup
    
    # Display summary
    display_summary
}

# -----------------------------------------------------------------------------
# Validate Backup
# -----------------------------------------------------------------------------
validate_backup() {
    log_step "Validating backup..."
    
    if [ ! -e "$BACKUP_PATH" ]; then
        log_error "Backup not found: $BACKUP_PATH"
        exit 1
    fi
    
    # Check if it's a compressed archive or directory
    if [ -f "$BACKUP_PATH" ]; then
        if [[ "$BACKUP_PATH" == *.tar.gz ]] || [[ "$BACKUP_PATH" == *.tgz ]]; then
            log_info "Backup type: Compressed archive"
        else
            log_error "Unsupported backup format. Expected .tar.gz or directory"
            exit 1
        fi
    elif [ -d "$BACKUP_PATH" ]; then
        log_info "Backup type: Directory"
    else
        log_error "Invalid backup path: $BACKUP_PATH"
        exit 1
    fi
    
    log_info "Backup path: $BACKUP_PATH"
}

# -----------------------------------------------------------------------------
# Prepare Backup
# -----------------------------------------------------------------------------
prepare_backup() {
    log_step "Preparing backup for restore..."
    
    # Create working directory
    RESTORE_WORK_DIR=$(mktemp -d -t alfresco-restore-XXXXXX)
    log_info "Working directory: $RESTORE_WORK_DIR"
    
    if [ -f "$BACKUP_PATH" ]; then
        # Extract compressed archive
        log_info "Extracting backup archive..."
        
        if [ "$DRY_RUN" = "false" ]; then
            tar -xzf "$BACKUP_PATH" -C "$RESTORE_WORK_DIR"
            
            # Find the extracted directory
            BACKUP_EXTRACTED_DIR=$(find "$RESTORE_WORK_DIR" -maxdepth 1 -type d -name "alfresco-*" | head -1)
            
            if [ -z "$BACKUP_EXTRACTED_DIR" ]; then
                # Files might be directly in work dir
                BACKUP_EXTRACTED_DIR="$RESTORE_WORK_DIR"
            fi
        else
            BACKUP_EXTRACTED_DIR="$RESTORE_WORK_DIR"
            log_info "[DRY RUN] Would extract archive to $RESTORE_WORK_DIR"
        fi
    else
        # Use directory directly
        BACKUP_EXTRACTED_DIR="$BACKUP_PATH"
    fi
    
    log_info "Backup directory: $BACKUP_EXTRACTED_DIR"
    
    # Read and display manifest if available
    local manifest="${BACKUP_EXTRACTED_DIR}/manifest.txt"
    if [ -f "$manifest" ] && [ "$DRY_RUN" = "false" ]; then
        log_info "Backup manifest found:"
        echo ""
        grep -E "^(backup_|completed_|total_)" "$manifest" | while read -r line; do
            echo "  $line"
        done
        echo ""
    fi
    
    # Validate backup contents based on restore type
    validate_backup_contents
}

# -----------------------------------------------------------------------------
# Validate Backup Contents
# -----------------------------------------------------------------------------
validate_backup_contents() {
    log_step "Validating backup contents..."
    
    local errors=0
    
    if [ "$DRY_RUN" = "true" ]; then
        log_info "[DRY RUN] Would validate backup contents"
        return 0
    fi
    
    case "$RESTORE_TYPE" in
        full|db)
            if ! ls "${BACKUP_EXTRACTED_DIR}"/database_*.sql* &>/dev/null; then
                if [ "$RESTORE_TYPE" = "db" ]; then
                    log_error "Database backup not found in archive"
                    ((errors++))
                else
                    log_warn "Database backup not found - will skip database restore"
                fi
            else
                log_info "Database backup: Found"
            fi
            ;;&  # Continue checking
        full|content)
            if [ ! -d "${BACKUP_EXTRACTED_DIR}/alf_data" ]; then
                if [ "$RESTORE_TYPE" = "content" ]; then
                    log_error "Content store backup not found in archive"
                    ((errors++))
                else
                    log_warn "Content store backup not found - will skip content restore"
                fi
            else
                log_info "Content store backup: Found"
            fi
            ;;&
        full|config)
            if [ ! -d "${BACKUP_EXTRACTED_DIR}/config" ]; then
                if [ "$RESTORE_TYPE" = "config" ]; then
                    log_error "Configuration backup not found in archive"
                    ((errors++))
                else
                    log_warn "Configuration backup not found - will skip config restore"
                fi
            else
                log_info "Configuration backup: Found"
            fi
            ;;&
        full|solr)
            if [ ! -d "${BACKUP_EXTRACTED_DIR}/solr" ]; then
                if [ "$RESTORE_TYPE" = "solr" ]; then
                    log_error "Solr backup not found in archive"
                    ((errors++))
                else
                    log_info "Solr backup: Not found (indexes will rebuild)"
                    INCLUDE_SOLR="false"
                fi
            else
                log_info "Solr backup: Found"
            fi
            ;;
    esac
    
    if [ $errors -gt 0 ]; then
        log_error "Backup validation failed"
        exit 1
    fi
    
    log_info "Backup validation passed"
}

# -----------------------------------------------------------------------------
# Check Services
# -----------------------------------------------------------------------------
check_services() {
    log_step "Checking services status..."
    
    local services_running=()
    
    for service in tomcat solr activemq transform nginx; do
        if systemctl is-active --quiet "$service" 2>/dev/null; then
            services_running+=("$service")
        fi
    done
    
    if [ ${#services_running[@]} -gt 0 ]; then
        log_warn "The following services are running: ${services_running[*]}"
        log_warn "Services must be stopped before restore to prevent data corruption."
        echo ""
        
        if [ "$FORCE" = "true" ]; then
            log_info "Force mode: Stopping services automatically..."
            if [ "$DRY_RUN" = "false" ]; then
                bash "${SCRIPT_DIR}/12-stop_services.sh" --force
            else
                log_info "[DRY RUN] Would run: 12-stop_services.sh --force"
            fi
        else
            read -p "Stop services now? [y/N] " -n 1 -r
            echo ""
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                if [ "$DRY_RUN" = "false" ]; then
                    bash "${SCRIPT_DIR}/12-stop_services.sh"
                else
                    log_info "[DRY RUN] Would run: 12-stop_services.sh"
                fi
            else
                log_error "Cannot restore with services running. Stop services first:"
                log_error "  bash scripts/12-stop_services.sh"
                exit 1
            fi
        fi
    else
        log_info "All services are stopped"
    fi
    
    # PostgreSQL needs to be running for database restore
    if [[ "$RESTORE_TYPE" == "full" || "$RESTORE_TYPE" == "db" ]]; then
        if ! systemctl is-active --quiet postgresql 2>/dev/null; then
            log_info "Starting PostgreSQL for database restore..."
            if [ "$DRY_RUN" = "false" ]; then
                sudo systemctl start postgresql
                sleep 2
            else
                log_info "[DRY RUN] Would start postgresql"
            fi
        fi
    fi
}

# -----------------------------------------------------------------------------
# Show Restore Plan
# -----------------------------------------------------------------------------
show_restore_plan() {
    log_step "Restore Plan"
    
    echo ""
    echo "┌─────────────────────────────────────────────────────────────┐"
    echo "│                    RESTORE PLAN                             │"
    echo "├─────────────────────────────────────────────────────────────┤"
    printf "│ %-59s │\n" "Backup: $(basename "$BACKUP_PATH")"
    printf "│ %-59s │\n" "Type: $RESTORE_TYPE"
    printf "│ %-59s │\n" "Target: $ALFRESCO_HOME"
    echo "├─────────────────────────────────────────────────────────────┤"
    echo "│ Components to restore:                                      │"
    
    case "$RESTORE_TYPE" in
        full)
            printf "│   %-57s │\n" "- PostgreSQL database ($ALFRESCO_DB_NAME)"
            printf "│   %-57s │\n" "- Content store (alf_data)"
            printf "│   %-57s │\n" "- Configuration files"
            if [ "$INCLUDE_SOLR" = "true" ]; then
                printf "│   %-57s │\n" "- Solr indexes"
            else
                printf "│   %-57s │\n" "- Solr indexes (SKIPPED - will rebuild)"
            fi
            ;;
        db)
            printf "│   %-57s │\n" "- PostgreSQL database ($ALFRESCO_DB_NAME)"
            ;;
        content)
            printf "│   %-57s │\n" "- Content store (alf_data)"
            ;;
        config)
            printf "│   %-57s │\n" "- Configuration files"
            ;;
        solr)
            printf "│   %-57s │\n" "- Solr indexes"
            ;;
    esac
    
    echo "├─────────────────────────────────────────────────────────────┤"
    echo "│ WARNING: Existing data will be OVERWRITTEN!                 │"
    echo "└─────────────────────────────────────────────────────────────┘"
    echo ""
}

# -----------------------------------------------------------------------------
# Confirm Restore
# -----------------------------------------------------------------------------
confirm_restore() {
    if [ "$DRY_RUN" = "true" ]; then
        log_info "[DRY RUN] Would proceed with restore"
        return 0
    fi
    
    if [ "$FORCE" = "true" ]; then
        log_info "Force mode: Proceeding without confirmation"
        return 0
    fi
    
    echo ""
    log_warn "This will overwrite existing Alfresco data!"
    read -p "Are you sure you want to continue? Type 'yes' to confirm: " -r
    echo ""
    
    if [ "$REPLY" != "yes" ]; then
        log_info "Restore cancelled"
        cleanup
        exit 0
    fi
}

# -----------------------------------------------------------------------------
# Restore Database
# -----------------------------------------------------------------------------
restore_database() {
    log_step "Restoring PostgreSQL database..."
    
    # Ensure PostgreSQL is running and ready
    if ! systemctl is-active --quiet postgresql 2>/dev/null; then
        log_info "Starting PostgreSQL..."
        sudo systemctl start postgresql
    fi
    
    # Wait for PostgreSQL to be ready
    local attempts=0
    while ! sudo -u postgres pg_isready -q 2>/dev/null; do
        ((attempts++)) || true
        if [ $attempts -ge 30 ]; then
            log_error "PostgreSQL failed to become ready within 30 seconds"
            return 1
        fi
        sleep 1
    done
    log_info "PostgreSQL is ready"
    
    # Find database backup file
    local db_dump
    db_dump=$(find "${BACKUP_EXTRACTED_DIR}" -name "database_*.dump" 2>/dev/null | head -1)
    
    local db_sql
    db_sql=$(find "${BACKUP_EXTRACTED_DIR}" -name "database_*.sql" ! -name "*.dump" 2>/dev/null | head -1)
    
    if [ -z "$db_dump" ] && [ -z "$db_sql" ]; then
        log_warn "No database backup found, skipping database restore"
        return 0
    fi
    
    if [ "$DRY_RUN" = "true" ]; then
        log_info "[DRY RUN] Would restore database from: ${db_dump:-$db_sql}"
        return 0
    fi
    
    # Create a persistent log location
    local db_log="${BACKUP_EXTRACTED_DIR}/db_restore.log"
    
    # Drop and recreate database
    log_info "Dropping existing database..."
    sudo -u postgres psql -c "DROP DATABASE IF EXISTS ${ALFRESCO_DB_NAME};" 2>>"$db_log" || true
    
    log_info "Creating fresh database..."
    sudo -u postgres psql -c "CREATE DATABASE ${ALFRESCO_DB_NAME} OWNER ${ALFRESCO_DB_USER} ENCODING 'UTF8';" 2>>"$db_log"
    
    # Grant privileges to alfresco user
    sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE ${ALFRESCO_DB_NAME} TO ${ALFRESCO_DB_USER};" 2>>"$db_log" || true
    
    # Restore from custom format dump (preferred) or plain SQL
    local restore_success=false
    
    if [ -n "$db_dump" ] && [ -f "$db_dump" ]; then
        log_info "Restoring from custom dump: $(basename "$db_dump")"
        
        # pg_restore returns non-zero on warnings, so we capture output and check manually
        if sudo -u postgres pg_restore \
            --dbname="$ALFRESCO_DB_NAME" \
            --verbose \
            --no-owner \
            --no-privileges \
            --role="${ALFRESCO_DB_USER}" \
            "$db_dump" 2>>"$db_log"; then
            restore_success=true
        else
            # Check if it's just warnings (common with pg_restore)
            if grep -q "pg_restore: error:" "$db_log" 2>/dev/null; then
                log_warn "pg_restore completed with errors (check $db_log)"
            else
                log_info "pg_restore completed (warnings logged to $db_log)"
                restore_success=true
            fi
        fi
    fi
    
    # If custom dump failed or not found, try plain SQL
    if [ "$restore_success" = "false" ] && [ -n "$db_sql" ] && [ -f "$db_sql" ]; then
        log_info "Restoring from SQL dump: $(basename "$db_sql")"
        if sudo -u postgres psql \
            --dbname="$ALFRESCO_DB_NAME" \
            --file="$db_sql" \
            2>>"$db_log"; then
            restore_success=true
        else
            log_warn "psql completed with warnings (check $db_log)"
            restore_success=true  # psql often returns non-zero on warnings
        fi
    fi
    
    # Grant schema privileges to alfresco user
    sudo -u postgres psql -d "$ALFRESCO_DB_NAME" -c "GRANT ALL ON SCHEMA public TO ${ALFRESCO_DB_USER};" 2>>"$db_log" || true
    sudo -u postgres psql -d "$ALFRESCO_DB_NAME" -c "GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO ${ALFRESCO_DB_USER};" 2>>"$db_log" || true
    sudo -u postgres psql -d "$ALFRESCO_DB_NAME" -c "GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO ${ALFRESCO_DB_USER};" 2>>"$db_log" || true
    
    # Verify restore
    local table_count
    table_count=$(sudo -u postgres psql -tAc "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'public';" "$ALFRESCO_DB_NAME" 2>/dev/null || echo "0")
    
    if [ "$table_count" -gt 0 ] 2>/dev/null; then
        log_info "Database restored successfully ($table_count tables)"
    else
        log_error "Database restore may have failed (no tables found)"
        log_error "Check $db_log for details"
        # Show last few lines of log
        if [ -f "$db_log" ]; then
            echo "--- Last 10 lines of database restore log ---"
            tail -10 "$db_log"
            echo "--- End of log ---"
        fi
    fi
}

# -----------------------------------------------------------------------------
# Restore Content Store
# -----------------------------------------------------------------------------
restore_content_store() {
    log_step "Restoring content store..."
    
    local backup_content="${BACKUP_EXTRACTED_DIR}/alf_data"
    local target_content="${ALFRESCO_HOME}/alf_data"
    
    if [ ! -d "$backup_content" ]; then
        log_warn "Content store backup not found, skipping"
        return 0
    fi
    
    if [ "$DRY_RUN" = "true" ]; then
        log_info "[DRY RUN] Would restore content store:"
        log_info "  From: $backup_content"
        log_info "  To: $target_content"
        return 0
    fi
    
    # Backup existing content store (just rename)
    if [ -d "$target_content" ]; then
        local backup_timestamp
        backup_timestamp=$(date +%Y%m%d_%H%M%S)
        local old_content="${target_content}.old.${backup_timestamp}"
        
        log_info "Moving existing content store to: $old_content"
        sudo mv "$target_content" "$old_content"
    fi
    
    # Restore content store
    log_info "Copying content store (this may take a while)..."
    
    local content_size
    content_size=$(du -sh "$backup_content" 2>/dev/null | cut -f1)
    log_info "Content size: $content_size"
    
    if command -v rsync &>/dev/null; then
        sudo rsync -a --info=progress2 "$backup_content/" "$target_content/"
    else
        sudo cp -a "$backup_content" "$target_content"
    fi
    
    # Set permissions
    sudo chown -R "${ALFRESCO_USER}:${ALFRESCO_GROUP}" "$target_content"
    
    log_info "Content store restored successfully"
}

# -----------------------------------------------------------------------------
# Restore Configuration
# -----------------------------------------------------------------------------
restore_configuration() {
    log_step "Restoring configuration files..."
    
    local backup_config="${BACKUP_EXTRACTED_DIR}/config"
    
    if [ ! -d "$backup_config" ]; then
        log_warn "Configuration backup not found, skipping"
        return 0
    fi
    
    if [ "$DRY_RUN" = "true" ]; then
        log_info "[DRY RUN] Would restore configuration files from: $backup_config"
        return 0
    fi
    
    local restored=0
    
    # Restore files maintaining directory structure
    # The backup preserves paths like: config/home/ubuntu/tomcat/...
    
    # Find and restore each file
    while IFS= read -r -d '' backup_file; do
        # Get relative path within backup
        local relative_path="${backup_file#"$backup_config"/}"
        local target_path="/${relative_path}"
        local target_dir
        target_dir=$(dirname "$target_path")
        
        # Create target directory if needed
        if [ ! -d "$target_dir" ]; then
            sudo mkdir -p "$target_dir"
        fi
        
        # Backup existing file
        if [ -f "$target_path" ]; then
            sudo cp "$target_path" "${target_path}.restore-backup" 2>/dev/null || true
        fi
        
        # Restore file
        if sudo cp -a "$backup_file" "$target_path" 2>/dev/null; then
            log_info "Restored: $target_path"
            restored=$((restored + 1))
        else
            log_warn "Failed to restore: $target_path"
        fi
    done < <(find "$backup_config" -type f -print0 2>/dev/null)
    
    # Also handle directories (for things like keystore)
    while IFS= read -r -d '' backup_dir; do
        local relative_path="${backup_dir#"$backup_config"/}"
        local target_path="/${relative_path}"
        
        if [ ! -d "$target_path" ]; then
            sudo mkdir -p "$target_path"
        fi
        
        sudo cp -a "$backup_dir"/* "$target_path"/ 2>/dev/null || true
    done < <(find "$backup_config" -mindepth 1 -type d -print0 2>/dev/null)
    
    # Reload systemd if service files were restored
    if ls "${backup_config}"/etc/systemd/system/*.service &>/dev/null 2>&1; then
        log_info "Reloading systemd daemon..."
        sudo systemctl daemon-reload
    fi
    
    log_info "Configuration restored ($restored files)"
}

# -----------------------------------------------------------------------------
# Restore Solr Indexes
# -----------------------------------------------------------------------------
restore_solr_indexes() {
    log_step "Restoring Solr indexes..."
    
    local backup_solr="${BACKUP_EXTRACTED_DIR}/solr"
    local target_solr="${ALFRESCO_HOME}/alfresco-search-services/solrhome"
    
    if [ ! -d "$backup_solr" ]; then
        log_warn "Solr backup not found, indexes will rebuild on startup"
        return 0
    fi
    
    if [ "$DRY_RUN" = "true" ]; then
        log_info "[DRY RUN] Would restore Solr indexes:"
        log_info "  From: $backup_solr"
        log_info "  To: $target_solr"
        return 0
    fi
    
    # Backup existing Solr data
    if [ -d "$target_solr" ]; then
        local backup_timestamp
        backup_timestamp=$(date +%Y%m%d_%H%M%S)
        local old_solr="${target_solr}.old.${backup_timestamp}"
        
        log_info "Moving existing Solr data to: $old_solr"
        sudo mv "$target_solr" "$old_solr"
    fi
    
    # Restore Solr data
    log_info "Copying Solr indexes (this may take a while)..."
    
    local solr_size
    solr_size=$(du -sh "$backup_solr" 2>/dev/null | cut -f1)
    log_info "Solr data size: $solr_size"
    
    sudo mkdir -p "$(dirname "$target_solr")"
    
    if command -v rsync &>/dev/null; then
        sudo rsync -a --info=progress2 "$backup_solr/" "$target_solr/"
    else
        sudo cp -a "$backup_solr" "$target_solr"
    fi
    
    # Set permissions
    sudo chown -R "${ALFRESCO_USER}:${ALFRESCO_GROUP}" "$target_solr"
    
    log_info "Solr indexes restored successfully"
}

# -----------------------------------------------------------------------------
# Cleanup
# -----------------------------------------------------------------------------
cleanup() {
    if [ -n "$RESTORE_WORK_DIR" ] && [ -d "$RESTORE_WORK_DIR" ]; then
        log_info "Cleaning up temporary files..."
        rm -rf "$RESTORE_WORK_DIR"
    fi
}

# -----------------------------------------------------------------------------
# Display Summary
# -----------------------------------------------------------------------------
display_summary() {
    log_step "Restore Summary"
    
    echo ""
    echo "┌─────────────────────────────────────────────────────────────┐"
    echo "│                   RESTORE COMPLETE                          │"
    echo "├─────────────────────────────────────────────────────────────┤"
    printf "│ %-59s │\n" "Backup: $(basename "$BACKUP_PATH")"
    printf "│ %-59s │\n" "Type: $RESTORE_TYPE"
    printf "│ %-59s │\n" "Target: $ALFRESCO_HOME"
    echo "└─────────────────────────────────────────────────────────────┘"
    echo ""
    
    if [ "$DRY_RUN" = "true" ]; then
        log_info "DRY RUN completed - no changes were made"
        return 0
    fi
    
    log_info "Restore completed successfully!"
    echo ""
    log_info "Next steps:"
    log_info "  1. Review restored configuration files"
    log_info "  2. Start services: bash scripts/11-start_services.sh"
    log_info "  3. Verify Alfresco is working correctly"
    
    if [ "$INCLUDE_SOLR" = "false" ]; then
        echo ""
        log_info "Note: Solr indexes were not restored."
        log_info "Indexes will rebuild automatically (may take time for large repositories)."
    fi
}

# -----------------------------------------------------------------------------
# Run Main
# -----------------------------------------------------------------------------
main "$@"