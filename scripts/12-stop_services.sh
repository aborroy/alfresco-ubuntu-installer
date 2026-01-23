#!/bin/bash
# =============================================================================
# Alfresco Services Stop Script
# =============================================================================
# Stops all Alfresco services in the correct order (reverse of startup).
#
# Service shutdown order:
# 1. Nginx (reverse proxy) - stop accepting new connections
# 2. Solr (search) - stop indexing
# 3. Tomcat (Alfresco + Share) - main application
# 4. Transform (document transformation)
# 5. ActiveMQ (messaging)
# 6. PostgreSQL (database) - stop last to ensure data integrity
#
# Usage:
#   bash scripts/12-stop_services.sh [--force] [--no-wait]
#
# Options:
#   --force      Force stop services (SIGKILL instead of SIGTERM)
#   --no-wait    Stop services without waiting for graceful shutdown
# =============================================================================

# Load common functions and configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
WAIT_FOR_SHUTDOWN="${WAIT_FOR_SHUTDOWN:-true}"
FORCE_STOP="${FORCE_STOP:-false}"
SERVICE_TIMEOUT=60  # seconds to wait for each service to stop

# -----------------------------------------------------------------------------
# Parse Arguments
# -----------------------------------------------------------------------------
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --force)
                FORCE_STOP="true"
                shift
                ;;
            --no-wait)
                WAIT_FOR_SHUTDOWN="false"
                shift
                ;;
            *)
                log_error "Unknown option: $1"
                echo "Usage: $0 [--force] [--no-wait]"
                exit 1
                ;;
        esac
    done
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
    parse_args "$@"
    
    log_step "Stopping Alfresco services..."
    
    if [ "$FORCE_STOP" = "true" ]; then
        log_warn "Force stop enabled - services will be killed if they don't stop gracefully"
    fi
    
    # Load configuration (for paths and ports)
    load_config 2>/dev/null || {
        log_warn "Configuration not loaded, using defaults"
    }
    
    # Track results
    declare -A SERVICE_STATUS
    
    # Stop services in reverse order
    stop_nginx
    stop_solr
    stop_tomcat
    stop_transform
    stop_activemq
    stop_postgresql
    
    # Display summary
    display_summary
}

# -----------------------------------------------------------------------------
# Stop Service Helper
# -----------------------------------------------------------------------------
stop_service() {
    local service_name=$1
    local display_name=$2
    local pre_stop_func=${3:-}
    
    log_step "Stopping ${display_name}..."
    
    # Check if service exists
    if ! systemctl list-unit-files "${service_name}.service" &>/dev/null; then
        log_info "${display_name} service not found, skipping..."
        SERVICE_STATUS[$service_name]="not installed"
        return 0
    fi
    
    # Check if already stopped
    if ! systemctl is-active --quiet "$service_name"; then
        log_info "${display_name} is already stopped"
        SERVICE_STATUS[$service_name]="already stopped"
        return 0
    fi
    
    # Run pre-stop function if provided (for graceful shutdown preparation)
    if [ -n "$pre_stop_func" ]; then
        $pre_stop_func || log_warn "Pre-stop check for ${display_name} reported issues"
    fi
    
    # Stop the service
    if sudo systemctl stop "$service_name"; then
        log_info "${display_name} stop command issued"
    else
        log_warn "Failed to stop ${display_name} gracefully"
        if [ "$FORCE_STOP" = "true" ]; then
            log_warn "Attempting force kill..."
            sudo systemctl kill -s SIGKILL "$service_name" 2>/dev/null || true
        fi
    fi
    
    # Wait for service to stop (if waiting is enabled)
    if [ "$WAIT_FOR_SHUTDOWN" = "true" ]; then
        local attempts=0
        local max_attempts=$((SERVICE_TIMEOUT / 2))
        
        while systemctl is-active --quiet "$service_name"; do
            if [ $attempts -ge $max_attempts ]; then
                log_warn "${display_name} did not stop within ${SERVICE_TIMEOUT}s"
                
                if [ "$FORCE_STOP" = "true" ]; then
                    log_warn "Force killing ${display_name}..."
                    sudo systemctl kill -s SIGKILL "$service_name" 2>/dev/null || true
                    sleep 2
                    if systemctl is-active --quiet "$service_name"; then
                        SERVICE_STATUS[$service_name]="failed to stop"
                        return 1
                    fi
                else
                    SERVICE_STATUS[$service_name]="timeout"
                    return 1
                fi
                break
            fi
            echo -n "."
            sleep 2
            ((attempts++))
        done
        echo ""
    fi
    
    # Verify stopped
    if ! systemctl is-active --quiet "$service_name"; then
        log_info "${display_name} stopped successfully"
        SERVICE_STATUS[$service_name]="stopped"
    else
        SERVICE_STATUS[$service_name]="still running"
        return 1
    fi
    
    return 0
}

# -----------------------------------------------------------------------------
# Nginx
# -----------------------------------------------------------------------------
stop_nginx() {
    stop_service "nginx" "Nginx" "pre_stop_nginx"
}

pre_stop_nginx() {
    log_info "Nginx will stop accepting new connections..."
    return 0
}

# -----------------------------------------------------------------------------
# Solr
# -----------------------------------------------------------------------------
stop_solr() {
    stop_service "solr" "Solr" "pre_stop_solr"
}

pre_stop_solr() {
    log_info "Solr will flush pending changes..."
    # Optionally trigger a commit before stopping
    local solr_url="http://${SOLR_HOST:-localhost}:${SOLR_PORT:-8983}/solr/alfresco/update?commit=true"
    curl -sf -H "X-Alfresco-Search-Secret: ${SOLR_SHARED_SECRET:-secret}" "$solr_url" >/dev/null 2>&1 || true
    return 0
}

# -----------------------------------------------------------------------------
# Tomcat (Alfresco + Share)
# -----------------------------------------------------------------------------
stop_tomcat() {
    stop_service "tomcat" "Tomcat (Alfresco + Share)" "pre_stop_tomcat"
}

pre_stop_tomcat() {
    log_info "Waiting for Alfresco to complete pending operations..."
    # Give time for any in-flight requests to complete
    sleep 2
    return 0
}

# -----------------------------------------------------------------------------
# Transform Service
# -----------------------------------------------------------------------------
stop_transform() {
    stop_service "transform" "Transform Service"
}

# -----------------------------------------------------------------------------
# ActiveMQ
# -----------------------------------------------------------------------------
stop_activemq() {
    stop_service "activemq" "ActiveMQ" "pre_stop_activemq"
}

pre_stop_activemq() {
    log_info "ActiveMQ will drain pending messages..."
    # Give time for message processing
    sleep 2
    return 0
}

# -----------------------------------------------------------------------------
# PostgreSQL
# -----------------------------------------------------------------------------
stop_postgresql() {
    # Skip if using remote database (Two-Server Architecture)
    if [ "${ALFRESCO_DB_HOST}" != "localhost" ] && [ "${ALFRESCO_DB_HOST}" != "127.0.0.1" ]; then
        log_info "Using remote database (${ALFRESCO_DB_HOST}), skipping local PostgreSQL stop"
        SERVICE_STATUS["postgresql"]="remote"
        return 0
    fi
    stop_service "postgresql" "PostgreSQL" "pre_stop_postgresql"
}

pre_stop_postgresql() {
    log_info "Checking for active PostgreSQL connections..."
    
    # Show active connections (informational)
    local active_connections
    active_connections=$(sudo -u postgres psql -tAc "SELECT count(*) FROM pg_stat_activity WHERE state = 'active' AND pid != pg_backend_pid();" 2>/dev/null || echo "0")
    
    if [ "$active_connections" != "0" ] && [ -n "$active_connections" ]; then
        log_warn "PostgreSQL has ${active_connections} active connection(s)"
        log_info "Connections will be terminated during shutdown"
    fi
    
    return 0
}

# -----------------------------------------------------------------------------
# Display Summary
# -----------------------------------------------------------------------------
display_summary() {
    log_step "Service Stop Summary"
    
    echo ""
    echo "┌─────────────────────────────────────────────────────────────┐"
    echo "│                    SERVICE STATUS                           │"
    echo "├────────────────────┬────────────────────────────────────────┤"
    
    # Define service order for display (reverse of startup)
    local services=("nginx" "solr" "tomcat" "transform" "activemq" "postgresql")
    local names=("Nginx" "Solr" "Tomcat (Alfresco)" "Transform Service" "ActiveMQ" "PostgreSQL")
    
    for i in "${!services[@]}"; do
        local service="${services[$i]}"
        local name="${names[$i]}"
        local status="${SERVICE_STATUS[$service]:-unknown}"
        local status_icon
        
        case "$status" in
            "stopped"|"already stopped")
                status_icon="v"
                ;;
            "not installed")
                status_icon="-"
                ;;
            "remote")
                status_icon="~"
                ;;
            "timeout"|"still running"|"failed to stop")
                status_icon="x"
                ;;
            *)
                status_icon="?"
                ;;
        esac
        
        printf "│ %-18s │ %s %-36s │\n" "$name" "$status_icon" "$status"
    done
    
    echo "└────────────────────┴────────────────────────────────────────┘"
    echo ""
    
    # Check if any service failed to stop
    local failed=0
    for status in "${SERVICE_STATUS[@]}"; do
        if [[ "$status" == "failed to stop" || "$status" == "still running" ]]; then
            ((failed++))
        fi
    done
    
    if [ $failed -gt 0 ]; then
        log_error "$failed service(s) failed to stop."
        log_info "Try running with --force to kill stubborn services"
        exit 1
    else
        log_info "All services stopped successfully!"
    fi
}

# -----------------------------------------------------------------------------
# Run Main
# -----------------------------------------------------------------------------
main "$@"