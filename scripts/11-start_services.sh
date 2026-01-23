#!/bin/bash
# =============================================================================
# Alfresco Services Start Script
# =============================================================================
# Starts all Alfresco services in the correct order with health checks.
#
# Service startup order:
# 1. PostgreSQL (database)
# 2. ActiveMQ (messaging)
# 3. Transform (document transformation)
# 4. Tomcat (Alfresco + Share)
# 5. Solr (search)
# 6. Nginx (reverse proxy)
#
# Usage:
#   bash scripts/11-start_services.sh [--no-wait]
#
# Options:
#   --no-wait    Start services without waiting for health checks
# =============================================================================

# Load common functions and configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
WAIT_FOR_HEALTH="${WAIT_FOR_HEALTH:-true}"
SERVICE_TIMEOUT=120  # seconds to wait for each service

# -----------------------------------------------------------------------------
# Parse Arguments
# -----------------------------------------------------------------------------
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --no-wait)
                WAIT_FOR_HEALTH="false"
                shift
                ;;
            *)
                log_error "Unknown option: $1"
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
    
    log_step "Starting Alfresco services..."
    
    # Load configuration
    load_config
    
    # Calculate and display memory allocation
    calculate_memory_allocation
    show_memory_allocation
    echo ""
    
    # Track results
    declare -A SERVICE_STATUS
    
    # Start services in order
    start_postgresql
    start_activemq
    start_transform
    start_tomcat
    start_solr
    start_nginx
    
    # Display summary
    display_summary
}

# -----------------------------------------------------------------------------
# Start Service Helper
# -----------------------------------------------------------------------------
start_service() {
    local service_name=$1
    local display_name=$2
    local health_check_func=${3:-}
    
    log_step "Starting ${display_name}..."
    
    # Check if service exists
    if ! systemctl list-unit-files "${service_name}.service" &>/dev/null; then
        log_warn "${display_name} service not found, skipping..."
        SERVICE_STATUS[$service_name]="not installed"
        return 0
    fi
    
    # Check if already running
    if systemctl is-active --quiet "$service_name"; then
        log_info "${display_name} is already running"
        SERVICE_STATUS[$service_name]="running"
        return 0
    fi
    
    # Start the service
    if sudo systemctl start "$service_name"; then
        log_info "${display_name} start command issued"
    else
        log_error "Failed to start ${display_name}"
        SERVICE_STATUS[$service_name]="failed"
        return 1
    fi
    
    # Wait for service to be active
    local attempts=0
    local max_attempts=$((SERVICE_TIMEOUT / 2))
    
    while ! systemctl is-active --quiet "$service_name"; do
        if [ $attempts -ge $max_attempts ]; then
            log_error "${display_name} failed to start within ${SERVICE_TIMEOUT}s"
            SERVICE_STATUS[$service_name]="timeout"
            return 1
        fi
        echo -n "."
        sleep 2
        ((attempts++))
    done
    echo ""
    
    log_info "${display_name} is active"
    
    # Run health check if provided and waiting is enabled
    if [ "$WAIT_FOR_HEALTH" = "true" ] && [ -n "$health_check_func" ]; then
        if $health_check_func; then
            SERVICE_STATUS[$service_name]="healthy"
        else
            SERVICE_STATUS[$service_name]="unhealthy"
            log_warn "${display_name} started but health check failed"
        fi
    else
        SERVICE_STATUS[$service_name]="running"
    fi
    
    return 0
}

# -----------------------------------------------------------------------------
# PostgreSQL
# -----------------------------------------------------------------------------
start_postgresql() {
    # Skip if using remote database (Two-Server Architecture)
    if [ "${ALFRESCO_DB_HOST}" != "localhost" ] && [ "${ALFRESCO_DB_HOST}" != "127.0.0.1" ]; then
        log_info "Using remote database (${ALFRESCO_DB_HOST}), skipping local PostgreSQL start"
        SERVICE_STATUS["postgresql"]="remote"
        return 0
    fi
    start_service "postgresql" "PostgreSQL" "check_postgresql_health"
}

check_postgresql_health() {
    log_info "Checking PostgreSQL health..."
    
    local attempts=0
    local max_attempts=30
    
    while ! sudo -u postgres pg_isready -q 2>/dev/null; do
        if [ $attempts -ge $max_attempts ]; then
            log_error "PostgreSQL health check timed out"
            return 1
        fi
        sleep 1
        ((attempts++))
    done
    
    log_info "PostgreSQL is accepting connections"
    return 0
}

# -----------------------------------------------------------------------------
# ActiveMQ
# -----------------------------------------------------------------------------
start_activemq() {
    start_service "activemq" "ActiveMQ" "check_activemq_health"
}

check_activemq_health() {
    log_info "Checking ActiveMQ health..."
    
    local attempts=0
    local max_attempts=30
    
    while ! nc -z "${ACTIVEMQ_HOST:-localhost}" "${ACTIVEMQ_PORT:-61616}" 2>/dev/null; do
        if [ $attempts -ge $max_attempts ]; then
            log_error "ActiveMQ health check timed out"
            return 1
        fi
        sleep 1
        ((attempts++))
    done
    
    log_info "ActiveMQ is accepting connections on port ${ACTIVEMQ_PORT:-61616}"
    return 0
}

# -----------------------------------------------------------------------------
# Transform Service
# -----------------------------------------------------------------------------
start_transform() {
    start_service "transform" "Transform Service" "check_transform_health"
}

check_transform_health() {
    log_info "Checking Transform Service health..."
    
    local attempts=0
    local max_attempts=60  # Transform takes longer to start
    local health_url="http://${TRANSFORM_HOST:-localhost}:${TRANSFORM_PORT:-8090}/actuator/health"
    
    while true; do
        if curl -sf "$health_url" 2>/dev/null | grep -q '"status":"UP"'; then
            log_info "Transform Service is healthy"
            return 0
        fi
        
        if [ $attempts -ge $max_attempts ]; then
            log_error "Transform Service health check timed out"
            return 1
        fi
        
        sleep 2
        ((attempts++))
    done
}

# -----------------------------------------------------------------------------
# Tomcat (Alfresco + Share)
# -----------------------------------------------------------------------------
start_tomcat() {
    start_service "tomcat" "Tomcat (Alfresco + Share)" "check_tomcat_health"
}

check_tomcat_health() {
    log_info "Checking Alfresco health (this may take 2-3 minutes)..."
    
    local attempts=0
    local max_attempts=90  # Alfresco takes a while to start
    local alfresco_url="http://${ALFRESCO_HOST:-localhost}:${TOMCAT_HTTP_PORT:-8080}/alfresco/api/-default-/public/alfresco/versions/1/probes/-ready-"
    
    while true; do
        local response
        response=$(curl -sf "$alfresco_url" 2>/dev/null || echo "")
        
        if echo "$response" | grep -q 'readyProbe: Success'; then
            log_info "Alfresco is ready"
            break
        fi
        
        if [ $attempts -ge $max_attempts ]; then
            log_warn "Alfresco readiness check timed out (may still be starting)"
            log_warn "Check logs: tail -f ${ALFRESCO_HOME}/tomcat/logs/catalina.out"
            return 1
        fi
        
        # Show progress every 10 seconds
        if [ $((attempts % 5)) -eq 0 ]; then
            echo -n "."
        fi
        
        sleep 2
        ((attempts++))
    done
    echo ""
    
    # Also check Share
    local share_url="http://${SHARE_HOST:-localhost}:${TOMCAT_HTTP_PORT:-8080}/share/page"
    if curl -sf "$share_url" >/dev/null 2>&1; then
        log_info "Share is responding"
    else
        log_warn "Share may not be fully ready yet"
    fi
    
    return 0
}

# -----------------------------------------------------------------------------
# Solr
# -----------------------------------------------------------------------------
start_solr() {
    start_service "solr" "Solr" "check_solr_health"
}

check_solr_health() {
    log_info "Checking Solr health..."
    
    local attempts=0
    local max_attempts=60
    local solr_url="http://${SOLR_HOST:-localhost}:${SOLR_PORT:-8983}/solr/alfresco/admin/ping"
    
    while true; do
        local response
        response=$(curl -sf -H "X-Alfresco-Search-Secret: ${SOLR_SHARED_SECRET:-secret}" "$solr_url" 2>/dev/null || echo "")
        
        # Check for OK status in both JSON and XML formats
        if echo "$response" | grep -qE '("status":"OK"|<str name="status">OK</str>|>OK<)'; then
            log_info "Solr is healthy"
            return 0
        fi
        
        if [ $attempts -ge $max_attempts ]; then
            # Solr cores might not exist yet on first run
            log_warn "Solr health check timed out (cores may be initializing)"
            return 0  # Don't fail, cores are created on first connect
        fi
        
        sleep 2
        ((attempts++))
    done
}

# -----------------------------------------------------------------------------
# Nginx
# -----------------------------------------------------------------------------
start_nginx() {
    start_service "nginx" "Nginx" "check_nginx_health"
}

check_nginx_health() {
    log_info "Checking Nginx health..."
    
    local attempts=0
    local max_attempts=15
    local health_url="http://${NGINX_SERVER_NAME:-localhost}:${NGINX_HTTP_PORT:-80}/nginx-health"
    
    while true; do
        if curl -sf "$health_url" 2>/dev/null | grep -q "healthy"; then
            log_info "Nginx is healthy"
            return 0
        fi
        
        if [ $attempts -ge $max_attempts ]; then
            log_error "Nginx health check timed out"
            return 1
        fi
        
        sleep 1
        ((attempts++))
    done
}

# -----------------------------------------------------------------------------
# Display Summary
# -----------------------------------------------------------------------------
display_summary() {
    log_step "Service Status Summary"
    
    echo ""
    echo "┌─────────────────────────────────────────────────────────────┐"
    echo "│                    SERVICE STATUS                           │"
    echo "├────────────────────┬────────────────────────────────────────┤"
    
    # Define service order for display
    local services=("postgresql" "activemq" "transform" "tomcat" "solr" "nginx")
    local names=("PostgreSQL" "ActiveMQ" "Transform Service" "Tomcat (Alfresco)" "Solr" "Nginx")
    
    for i in "${!services[@]}"; do
        local service="${services[$i]}"
        local name="${names[$i]}"
        local status="${SERVICE_STATUS[$service]:-unknown}"
        local status_icon
        
        case "$status" in
            "healthy"|"running")
                status_icon="v"
                ;;
            "unhealthy")
                status_icon="^"
                ;;
            "not installed")
                status_icon="-"
                ;;
            "remote")
                status_icon="~"
                ;;
            *)
                status_icon="x"
                ;;
        esac
        
        printf "│ %-18s │ %s %-36s │\n" "$name" "$status_icon" "$status"
    done
    
    echo "└────────────────────┴────────────────────────────────────────┘"
    echo ""
    
    # Display access URLs
    log_info "Access URLs:"
    log_info "  Alfresco Content App: http://${NGINX_SERVER_NAME:-localhost}:${NGINX_HTTP_PORT:-80}/"
    log_info "  Alfresco Repository:  http://${NGINX_SERVER_NAME:-localhost}:${NGINX_HTTP_PORT:-80}/alfresco/"
    log_info "  Alfresco Share:       http://${NGINX_SERVER_NAME:-localhost}:${NGINX_HTTP_PORT:-80}/share/"
    log_info "  Solr Admin:           http://${SOLR_HOST:-localhost}:${SOLR_PORT:-8983}/solr/"
    log_info "  ActiveMQ Console:     http://${ACTIVEMQ_HOST:-localhost}:${ACTIVEMQ_WEBCONSOLE_PORT:-8161}/"
    log_info ""
    log_info "Default credentials: admin / admin"
    log_info ""
    
    # Check if any service failed
    local failed=0
    for status in "${SERVICE_STATUS[@]}"; do
        if [[ "$status" == "failed" || "$status" == "timeout" ]]; then
            ((failed++))
        fi
    done
    
    if [ $failed -gt 0 ]; then
        log_error "$failed service(s) failed to start. Check logs for details."
        exit 1
    else
        log_info "All services started successfully!"
    fi
}

# -----------------------------------------------------------------------------
# Run Main
# -----------------------------------------------------------------------------
main "$@"
