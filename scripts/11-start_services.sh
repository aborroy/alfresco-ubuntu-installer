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

# Función para logging de éxito
log_success() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✅ $1"
}

# Función para logging de advertencia
log_warning() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ⚠️  $1"
}

# Función para verificar si un comando existe
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Función para verificar el estado de un servicio
check_service_status() {
    local service="$1"
    local description="$2"
    
    if sudo systemctl is-active --quiet "$service"; then
        log_success "$description is running"
        return 0
    else
        log_error "$description is not running"
        return 1
    fi
}

# Función para esperar a que un servicio esté listo
wait_for_service() {
    local service="$1"
    local description="$2"
    local max_wait="${3:-120}"
    local check_interval="${4:-3}"
    
    log "Waiting for $description to be ready (max ${max_wait}s)..."
    
    local count=0
    local checks=$((max_wait / check_interval))
    
    while [ $count -lt $checks ]; do
        if sudo systemctl is-active --quiet "$service"; then
            log_success "$description is ready"
            return 0
        fi
        
        local dots=$(printf "%*s" $((count % 4)) | tr ' ' '.')
        printf "\r[$(date '+%Y-%m-%d %H:%M:%S')] Waiting for $description$dots"
        
        sleep $check_interval
        count=$((count + 1))
    done
    
    echo  # Nueva línea después del printf
    log_error "$description failed to start within ${max_wait} seconds"
    
    # Mostrar estado del servicio para diagnóstico
    log "Service status for $service:"
    sudo systemctl status "$service" --no-pager || true
    
    return 1
}

# Función para probar conectividad a un endpoint
test_endpoint() {
    local url="$1"
    local description="$2"
    local max_retries="${3:-15}"
    local retry_interval="${4:-10}"
    
    log "Testing $description at $url..."
    
    for i in $(seq 1 $max_retries); do
        if curl -f -s -o /dev/null --connect-timeout 10 --max-time 30 "$url"; then
            log_success "$description is responding"
            return 0
        fi
        
        if [ $i -lt $max_retries ]; then
            log "Attempt $i/$max_retries failed, retrying in ${retry_interval}s..."
            sleep $retry_interval
        fi
    done
    
    log_error "$description failed to respond after $max_retries attempts"
    return 1
}

# Función para verificar que los servicios existen
verify_services_exist() {
    log "Verifying that all required services are installed..."
    
    local services=("postgresql" "activemq" "transform" "tomcat" "solr" "nginx")
    local missing_services=()
    
    for service in "${services[@]}"; do
        if ! sudo systemctl list-unit-files "$service.service" >/dev/null 2>&1; then
            missing_services+=("$service")
        fi
    done
    
    if [ ${#missing_services[@]} -gt 0 ]; then
        log_error "The following services are not installed:"
        for service in "${missing_services[@]}"; do
            log_error "  - $service"
        done
        log_error "Please run the corresponding installation scripts first"
        exit 1
    fi
    
    log_success "All required services are installed"
}

# Función para detener todos los servicios (en orden reverso)
stop_all_services() {
    log "Stopping all Alfresco services..."
    
    local services=("nginx" "solr" "tomcat" "transform" "activemq" "postgresql")
    
    for service in "${services[@]}"; do
        if sudo systemctl is-active --quiet "$service"; then
            log "Stopping $service..."
            sudo systemctl stop "$service" || log_warning "Failed to stop $service"
        else
            log "$service is already stopped"
        fi
    done
}

# Función para iniciar PostgreSQL
start_postgresql() {
    log "=== Starting PostgreSQL Database ==="
    
    if sudo systemctl is-active --quiet postgresql; then
        log "PostgreSQL is already running"
        return 0
    fi
    
    sudo systemctl start postgresql
    wait_for_service postgresql "PostgreSQL" 60 2
    
    # Verificar conectividad a la base de datos
    log "Testing PostgreSQL connectivity..."
    if PGPASSWORD='alfresco' psql -h localhost -U alfresco -d alfresco -c "SELECT 1;" >/dev/null 2>&1; then
        log_success "PostgreSQL database connection successful"
    else
        log_error "PostgreSQL database connection failed"
        return 1
    fi
}

# Función para iniciar ActiveMQ
start_activemq() {
    log "=== Starting ActiveMQ Message Broker ==="
    
    if sudo systemctl is-active --quiet activemq; then
        log "ActiveMQ is already running"
        return 0
    fi
    
    sudo systemctl start activemq
    wait_for_service activemq "ActiveMQ" 90 3
    
    # Verificar conectividad a ActiveMQ
    test_endpoint "http://localhost:8161" "ActiveMQ Web Console" 8 5
}

# Función para iniciar Transform Service
start_transform() {
    log "=== Starting Transform Service ==="
    
    if sudo systemctl is-active --quiet transform; then
        log "Transform Service is already running"
        return 0
    fi
    
    sudo systemctl start transform
    wait_for_service transform "Transform Service" 150 5
    
    # Verificar conectividad al Transform Service
    test_endpoint "http://localhost:8090/actuator/health" "Transform Service Health" 12 10
}

# Función para iniciar Tomcat (Alfresco + Share)
start_tomcat() {
    log "=== Starting Tomcat (Alfresco + Share) ==="
    
    if sudo systemctl is-active --quiet tomcat; then
        log "Tomcat is already running"
        return 0
    fi
    
    sudo systemctl start tomcat
    wait_for_service tomcat "Tomcat" 240 5
    
    # Esperar que Alfresco esté completamente cargado
    log "Waiting for Alfresco to fully initialize (this may take several minutes)..."
    
    # Primero verificar que el puerto responde
    test_endpoint "http://localhost:8080" "Tomcat Server" 10 15
    
    # Luego verificar que Alfresco API está disponible
    test_endpoint "http://localhost:8080/alfresco/api/-default-/public/authentication/versions/1/tickets" "Alfresco Repository API" 20 15
    
    # Verificar Share si está disponible
    if curl -f -s --connect-timeout 10 --max-time 30 "http://localhost:8080/share" >/dev/null 2>&1; then
        log_success "Alfresco Share is responding"
    else
        log_warning "Alfresco Share may not be responding (this might be normal)"
    fi
}

# Función para iniciar Solr
start_solr() {
    log "=== Starting Solr Search Service ==="
    
    if sudo systemctl is-active --quiet solr; then
        log "Solr is already running"
        return 0
    fi
    
    sudo systemctl start solr
    wait_for_service solr "Solr" 180 5
    
    # Verificar conectividad a Solr
    test_endpoint "http://localhost:8983/solr/admin/cores?action=STATUS" "Solr Admin" 15 10
    
    # Verificar cores específicos de Alfresco
    log "Checking Alfresco Solr cores..."
    if curl -f -s --connect-timeout 10 --max-time 30 "http://localhost:8983/solr/alfresco/admin/ping" >/dev/null 2>&1; then
        log_success "Alfresco core is responding"
    else
        log_warning "Alfresco core may not be ready yet"
    fi
    
    if curl -f -s --connect-timeout 10 --max-time 30 "http://localhost:8983/solr/archive/admin/ping" >/dev/null 2>&1; then
        log_success "Archive core is responding"
    else
        log_warning "Archive core may not be ready yet"
    fi
}

# Función para iniciar Nginx
start_nginx() {
    log "=== Starting Nginx Web Server ==="
    
    if sudo systemctl is-active --quiet nginx; then
        log "Nginx is already running"
        return 0
    fi
    
    # Verificar configuración antes de iniciar
    if ! sudo nginx -t >/dev/null 2>&1; then
        log_error "Nginx configuration is invalid"
        sudo nginx -t
        return 1
    fi
    
    sudo systemctl start nginx
    wait_for_service nginx "Nginx" 60 2
    
    # Verificar endpoints principales
    test_endpoint "http://localhost/health" "Nginx Health Check" 5 5
    test_endpoint "http://localhost/" "ACA Frontend" 5 5
}

# Función para realizar tests finales de conectividad
run_final_connectivity_tests() {
    log "=== Running Final Connectivity Tests ==="
    
    local tests_passed=0
    local total_tests=0
    
    # Test 1: ACA Frontend
    total_tests=$((total_tests + 1))
    if test_endpoint "http://localhost/" "ACA Frontend" 3 5; then
        tests_passed=$((tests_passed + 1))
    fi
    
    # Test 2: Alfresco Repository via Nginx
    total_tests=$((total_tests + 1))
    if test_endpoint "http://localhost/alfresco/" "Alfresco via Nginx" 3 5; then
        tests_passed=$((tests_passed + 1))
    fi
    
    # Test 3: Share via Nginx
    total_tests=$((total_tests + 1))
    if curl -f -s --connect-timeout 10 --max-time 30 "http://localhost/share/" >/dev/null 2>&1; then
        log_success "Share via Nginx is responding"
        tests_passed=$((tests_passed + 1))
    else
        log_warning "Share via Nginx test failed"
    fi
    
    # Test 4: Solr direct access
    total_tests=$((total_tests + 1))
    if test_endpoint "http://localhost:8983/solr/" "Solr Direct Access" 3 5; then
        tests_passed=$((tests_passed + 1))
    fi
    
    # Test 5: ActiveMQ Console
    total_tests=$((total_tests + 1))
    if test_endpoint "http://localhost:8161/" "ActiveMQ Console" 3 5; then
        tests_passed=$((tests_passed + 1))
    fi
    
    log "=== Connectivity Test Results ==="
    log "Passed: $tests_passed/$total_tests tests"
    
    if [ $tests_passed -eq $total_tests ]; then
        log_success "All connectivity tests passed!"
        return 0
    else
        log_warning "Some connectivity tests failed"
        return 1
    fi
}

# Función para mostrar resumen del estado de servicios
show_services_status() {
    log "=== Services Status Summary ==="
    
    local services=(
        "postgresql:PostgreSQL Database"
        "activemq:ActiveMQ Message Broker"
        "transform:Transform Service"
        "tomcat:Tomcat (Alfresco + Share)"
        "solr:Solr Search Service"
        "nginx:Nginx Web Server"
    )
    
    local all_running=true
    
    for service_info in "${services[@]}"; do
        IFS=':' read -r service description <<< "$service_info"
        
        if sudo systemctl is-active --quiet "$service"; then
            log_success "$description"
        else
            log_error "$description"
            all_running=false
        fi
    done
    
    return $all_running
}

# Función para mostrar información de acceso
show_access_information() {
    log "=== Access Information ==="
    log ""
    log "🌐 Web Applications:"
    log "   • Alfresco Content App:  http://localhost/"
    log "   • Alfresco Repository:   http://localhost/alfresco/"
    log "   • Alfresco Share:        http://localhost/share/"
    log ""
    log "🔧 Administration Consoles:"
    log "   • ActiveMQ Console:      http://localhost:8161/ (admin/admin)"
    log "   • Solr Admin:            http://localhost:8983/solr/"
    log "   • Transform Service:     http://localhost:8090/"
    log "   • Nginx Status:          http://localhost/nginx_status (localhost only)"
    log ""
    log "🔑 Default Credentials:"
    log "   • Alfresco Admin:        admin/admin"
    log "   • ActiveMQ Console:      admin/admin"
    log ""
    log "📋 Health Checks:"
    log "   • Overall Health:        http://localhost/health"
    log "   • Transform Health:      http://localhost:8090/actuator/health"
    log ""
    log "📊 Log Locations:"
    log "   • Alfresco:              /home/ubuntu/tomcat/logs/alfresco.log"
    log "   • Share:                 /home/ubuntu/tomcat/logs/share.log"
    log "   • Tomcat:                /home/ubuntu/tomcat/logs/catalina.out"
    log "   • Solr:                  /home/ubuntu/alfresco-search-services/logs/solr.log"
    log "   • Transform:             /home/ubuntu/transform/transform.log"
    log "   • Nginx:                 /var/log/nginx/alfresco/access.log"
}

# Función para mostrar comandos útiles
show_useful_commands() {
    log "=== Useful Commands ==="
    log ""
    log "📋 Service Management:"
    log "   sudo systemctl status <service>     # Check service status"
    log "   sudo systemctl restart <service>    # Restart a service"
    log "   sudo systemctl stop <service>       # Stop a service"
    log "   sudo journalctl -u <service> -f     # Follow service logs"
    log ""
    log "🔧 Troubleshooting:"
    log "   sudo nginx -t                       # Test Nginx configuration"
    log "   curl -I http://localhost/           # Test web server response"
    log "   tail -f /home/ubuntu/tomcat/logs/catalina.out  # Follow Tomcat logs"
    log ""
    log "🔄 Restart All Services:"
    log "   $0 --restart                        # Restart all services"
}

# Función principal
main() {
    local restart_mode=false
    
    # Procesar argumentos de línea de comandos
    while [[ $# -gt 0 ]]; do
        case $1 in
            --restart|-r)
                restart_mode=true
                shift
                ;;
            --help|-h)
                echo "Usage: $0 [--restart|-r] [--help|-h]"
                echo "  --restart, -r    Stop all services before starting"
                echo "  --help, -h       Show this help message"
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                exit 1
                ;;
        esac
    done
    
    log "=== Starting Alfresco Services Stack ==="
    log "Timestamp: $(date)"
    log "Mode: $([ "$restart_mode" = true ] && echo 'Restart' || echo 'Start')"
    
    # Verificar que todos los servicios están instalados
    verify_services_exist
    
    # Si está en modo restart, detener todos los servicios primero
    if [ "$restart_mode" = true ]; then
        stop_all_services
        sleep 5
    fi
    
    # Verificar que curl está disponible para los tests
    if ! command_exists curl; then
        log "Installing curl for connectivity tests..."
        sudo apt update && sudo apt install -y curl
    fi
    
    log "Starting services in dependency order..."
    
    # Iniciar servicios en el orden correcto
    if ! start_postgresql; then
        log_error "Failed to start PostgreSQL. Aborting."
        exit 1
    fi
    
    if ! start_activemq; then
        log_error "Failed to start ActiveMQ. Aborting."
        exit 1
    fi
    
    if ! start_transform; then
        log_error "Failed to start Transform Service. Aborting."
        exit 1
    fi
    
    if ! start_tomcat; then
        log_error "Failed to start Tomcat. Aborting."
        exit 1
    fi
    
    if ! start_solr; then
        log_error "Failed to start Solr. Aborting."
        exit 1
    fi
    
    if ! start_nginx; then
        log_error "Failed to start Nginx. Aborting."
        exit 1
    fi
    
    # Esperar un momento para que todos los servicios se estabilicen
    log "Allowing services to stabilize..."
    sleep 10
    
    # Ejecutar tests finales de conectividad
    run_final_connectivity_tests
    
    # Mostrar resumen del estado
    if show_services_status; then
        log_success "All Alfresco services are running successfully!"
        
        # Mostrar información de acceso
        show_access_information
        
        # Mostrar comandos útiles
        show_useful_commands
        
        log ""
        log "🎉 Alfresco Content Services stack is ready!"
        log "You can now access the applications using the URLs above."
        
        exit 0
    else
        log_error "Some services failed to start properly."
        log "Check the service logs for more information:"
        log "  sudo journalctl -u <service-name> -f"
        
        exit 1
    fi
}

# Ejecutar función principal con todos los argumentos
main "$@"