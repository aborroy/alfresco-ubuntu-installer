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

# Función para obtener la última versión de ActiveMQ con fallback
fetch_latest_activemq_version() {
    local base_url="https://dlcdn.apache.org/activemq/"
    local fallback_version="6.1.4"  # Versión conocida estable
    
    log "Fetching latest ActiveMQ version from Apache mirror..."
    
    # Intentar obtener versiones disponibles
    local latest_version=""
    if command_exists curl; then
        # Buscar versiones 6.x.x (más estables para producción)
        latest_version=$(curl --connect-timeout 15 --max-time 30 -s "$base_url" 2>/dev/null | \
                        grep -oP '6\.[0-9]+\.[0-9]+' | \
                        sort -V | \
                        tail -1) || true
        
        # Si no encuentra 6.x.x, buscar 5.x.x como fallback
        if [ -z "$latest_version" ]; then
            latest_version=$(curl --connect-timeout 15 --max-time 30 -s "$base_url" 2>/dev/null | \
                            grep -oP '5\.[0-9]+\.[0-9]+' | \
                            sort -V | \
                            tail -1) || true
        fi
    fi
    
    # Verificar que la versión obtenida es válida
    if [[ "$latest_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        log "✓ Latest ActiveMQ version found: $latest_version"
        echo "$latest_version"
    else
        log "⚠️  Could not fetch latest version, using fallback: $fallback_version"
        echo "$fallback_version"
    fi
}

# Función para verificar si Java está instalado
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

# Función para descargar ActiveMQ con reintentos
download_activemq() {
    local version=$1
    local download_url="https://dlcdn.apache.org/activemq/$version/apache-activemq-$version-bin.tar.gz"
    local temp_file="/tmp/apache-activemq-$version-bin.tar.gz"
    local max_retries=3
    local retry=0
    
    log "Downloading Apache ActiveMQ $version..."
    
    while [ $retry -lt $max_retries ]; do
        log "Download attempt $((retry + 1))/$max_retries..."
        
        if wget --timeout=120 --tries=3 -O "$temp_file" "$download_url"; then
            # Verificar que el archivo descargado no está vacío y tiene tamaño razonable
            local file_size=$(stat -c%s "$temp_file" 2>/dev/null || stat -f%z "$temp_file" 2>/dev/null)
            if [ "$file_size" -gt 10485760 ]; then  # > 10MB
                log "✓ ActiveMQ downloaded successfully ($file_size bytes)"
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
            log "Retrying in 15 seconds..."
            sleep 15
        fi
    done
    
    log "ERROR: Failed to download ActiveMQ after $max_retries attempts"
    return 1
}

# Función para crear usuario del sistema si no existe
create_activemq_user() {
    local user="$1"
    local group="$2"
    
    log "Setting up ActiveMQ user and group..."
    
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

# Función para configurar ActiveMQ
configure_activemq() {
    local activemq_home="$1"
    local user="$2"
    local group="$3"
    
    log "Configuring ActiveMQ..."
    
    # Crear backup de la configuración original
    sudo cp "$activemq_home/conf/activemq.xml" "$activemq_home/conf/activemq.xml.backup"
    
    # Configurar activemq.xml optimizado para Alfresco
    cat << 'EOF' | sudo tee "$activemq_home/conf/activemq.xml" > /dev/null
<!--
    Licensed to the Apache Software Foundation (ASF) under one or more
    contributor license agreements.  See the NOTICE file distributed with
    this work for additional information regarding copyright ownership.
    The ASF licenses this file to You under the Apache License, Version 2.0
    (the "License"); you may not use this file except in compliance with
    the License.  You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

    Unless required by applicable law or agreed to in writing, software
    distributed under the License is distributed on an "AS IS" BASIS,
    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
    See the License for the specific language governing permissions and
    limitations under the License.
-->
<beans
  xmlns="http://www.springframework.org/schema/beans"
  xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
  xsi:schemaLocation="http://www.springframework.org/schema/beans http://www.springframework.org/schema/beans/spring-beans.xsd
  http://activemq.apache.org/schema/core http://activemq.apache.org/schema/core/activemq-core.xsd">

    <bean class="org.springframework.beans.factory.config.PropertyPlaceholderConfigurer">
        <property name="locations">
            <value>file:${activemq.conf}/credentials.properties</value>
        </property>
    </bean>

    <broker xmlns="http://activemq.apache.org/schema/core" brokerName="localhost" dataDirectory="${activemq.data}">

        <destinationPolicy>
            <policyMap>
              <policyEntries>
                <policyEntry topic=">" >
                    <pendingMessageLimitStrategy>
                      <constantPendingMessageLimitStrategy limit="1000"/>
                    </pendingMessageLimitStrategy>
                </policyEntry>
              </policyEntries>
            </policyMap>
        </destinationPolicy>

        <managementContext>
            <managementContext createConnector="false"/>
        </managementContext>

        <persistenceAdapter>
            <kahaDB directory="${activemq.data}/kahadb"/>
        </persistenceAdapter>

          <systemUsage>
            <systemUsage>
                <memoryUsage>
                    <memoryUsage percentOfJvmHeap="70" />
                </memoryUsage>
                <storeUsage>
                    <storeUsage limit="100 gb"/>
                </storeUsage>
                <tempUsage>
                    <tempUsage limit="50 gb"/>
                </tempUsage>
            </systemUsage>
        </systemUsage>

        <transportConnectors>
            <transportConnector name="openwire" uri="tcp://0.0.0.0:61616?maximumConnections=1000&amp;wireFormat.maxFrameSize=104857600"/>
            <transportConnector name="amqp" uri="amqp://0.0.0.0:5672?maximumConnections=1000&amp;wireFormat.maxFrameSize=104857600"/>
            <transportConnector name="stomp" uri="stomp://0.0.0.0:61613?maximumConnections=1000&amp;wireFormat.maxFrameSize=104857600"/>
            <transportConnector name="mqtt" uri="mqtt://0.0.0.0:1883?maximumConnections=1000&amp;wireFormat.maxFrameSize=104857600"/>
            <transportConnector name="ws" uri="ws://0.0.0.0:61614?maximumConnections=1000&amp;wireFormat.maxFrameSize=104857600"/>
        </transportConnectors>

        <shutdownHooks>
            <bean xmlns="http://www.springframework.org/schema/beans" class="org.apache.activemq.hooks.SpringContextHook" />
        </shutdownHooks>

    </broker>

    <import resource="jetty.xml"/>

</beans>
EOF
    
    # Configurar jetty.xml para la consola web
    cat << 'EOF' | sudo tee "$activemq_home/conf/jetty.xml" > /dev/null
<!--
    Licensed to the Apache Software Foundation (ASF) under one or more
    contributor license agreements.  See the NOTICE file distributed with
    this work for additional information regarding copyright ownership.
    The ASF licenses this file to You under the Apache License, Version 2.0
    (the "License"); you may not use this file except in compliance with
    the License.  You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

    Unless required by applicable law or agreed to in writing, software
    distributed under the License is distributed on an "AS IS" BASIS,
    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
    See the License for the specific language governing permissions and
    limitations under the License.
-->
<beans xmlns="http://www.springframework.org/schema/beans" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
       xsi:schemaLocation="http://www.springframework.org/schema/beans http://www.springframework.org/schema/beans/spring-beans.xsd">

    <bean id="securityLoginService" class="org.eclipse.jetty.security.HashLoginService">
        <property name="name" value="ActiveMQRealm" />
        <property name="config" value="${activemq.conf}/jetty-realm.properties" />
    </bean>

    <bean id="securityConstraint" class="org.eclipse.jetty.util.security.Constraint">
        <property name="name" value="BASIC" />
        <property name="roles" value="user,admin" />
        <property name="authenticate" value="true" />
    </bean>

    <bean id="adminSecurityConstraint" class="org.eclipse.jetty.util.security.Constraint">
        <property name="name" value="BASIC" />
        <property name="roles" value="admin" />
        <property name="authenticate" value="true" />
    </bean>

    <bean id="securityConstraintMapping" class="org.eclipse.jetty.security.ConstraintMapping">
        <property name="constraint" ref="securityConstraint" />
        <property name="pathSpec" value="/api/*,/admin/*,*.jsp" />
    </bean>

    <bean id="adminSecurityConstraintMapping" class="org.eclipse.jetty.security.ConstraintMapping">
        <property name="constraint" ref="adminSecurityConstraint" />
        <property name="pathSpec" value="*.action" />
    </bean>

    <bean id="rewriteHandler" class="org.eclipse.jetty.rewrite.handler.RewriteHandler">
        <property name="rules">
            <list>
                <bean id="header" class="org.eclipse.jetty.rewrite.handler.HeaderPatternRule">
                    <property name="pattern" value="*" />
                    <property name="name" value="X-FRAME-OPTIONS" />
                    <property name="value" value="SAMEORIGIN" />
                </bean>
            </list>
        </property>
    </bean>

    <bean id="secHandlerCollection" class="org.eclipse.jetty.server.handler.HandlerCollection">
        <property name="handlers">
            <list>
                <ref bean="rewriteHandler" />
                <bean class="org.eclipse.jetty.webapp.WebAppContext">
                    <property name="contextPath" value="/admin" />
                    <property name="resourceBase" value="${activemq.home}/webapps/admin" />
                    <property name="logUrlOnStart" value="true" />
                </bean>
                <bean class="org.eclipse.jetty.webapp.WebAppContext">
                    <property name="contextPath" value="/api" />
                    <property name="resourceBase" value="${activemq.home}/webapps/api" />
                    <property name="logUrlOnStart" value="true" />
                </bean>
                <bean class="org.eclipse.jetty.server.handler.ResourceHandler">
                    <property name="directoriesListed" value="false" />
                    <property name="welcomeFiles">
                        <list>
                            <value>index.html</value>
                        </list>
                    </property>
                    <property name="resourceBase" value="${activemq.home}/webapps/" />
                </bean>
            </list>
        </property>
    </bean>

    <bean id="contexts" class="org.eclipse.jetty.server.handler.ContextHandlerCollection">
    </bean>

    <bean id="jettyPort" class="org.apache.activemq.web.WebConsolePort" init-method="start">
        <property name="host" value="0.0.0.0"/>
        <property name="port" value="8161"/>
    </bean>

    <bean id="Server" depends-on="jettyPort" class="org.eclipse.jetty.server.Server"
          destroy-method="stop">

        <property name="handler">
            <bean id="handlers" class="org.eclipse.jetty.server.handler.HandlerCollection">
                <property name="handlers">
                    <list>
                        <bean class="org.eclipse.jetty.security.ConstraintSecurityHandler">
                            <property name="loginService" ref="securityLoginService" />
                            <property name="authenticator">
                                <bean class="org.eclipse.jetty.security.authentication.BasicAuthenticator" />
                            </property>
                            <property name="constraintMappings">
                                <list>
                                    <ref bean="adminSecurityConstraintMapping" />
                                    <ref bean="securityConstraintMapping" />
                                </list>
                            </property>
                            <property name="handler" ref="secHandlerCollection" />
                        </bean>
                    </list>
                </property>
            </bean>
        </property>

    </bean>

</beans>
EOF

    # Configurar credenciales para la consola web
    cat << 'EOF' | sudo tee "$activemq_home/conf/jetty-realm.properties" > /dev/null
# username: password [,rolename ...]
admin: admin, admin
user: user, user
EOF

    # Configurar log4j
    if [ -f "$activemq_home/conf/log4j.properties" ]; then
        sudo cp "$activemq_home/conf/log4j.properties" "$activemq_home/conf/log4j.properties.backup"
        # Configurar logging menos verboso
        sudo sed -i 's/log4j.rootLogger=INFO/log4j.rootLogger=WARN/' "$activemq_home/conf/log4j.properties"
    fi

    # Establecer permisos
    sudo chown -R "$user:$group" "$activemq_home"
    sudo chmod -R 755 "$activemq_home"
}

# Variables
ACTIVEMQ_USER="ubuntu"
ACTIVEMQ_GROUP="ubuntu"
ACTIVEMQ_HOME="/home/ubuntu/activemq"

log "Starting Apache ActiveMQ installation..."

# Verificar prerrequisitos
verify_java_installation

# Actualizar lista de paquetes e instalar dependencias
log "Installing required dependencies..."
sudo apt update
sudo apt install -y curl wget tar

# Obtener la versión más reciente de ActiveMQ
ACTIVEMQ_VERSION=$(fetch_latest_activemq_version)

# Configurar usuario y grupo
create_activemq_user "$ACTIVEMQ_USER" "$ACTIVEMQ_GROUP"

# Descargar ActiveMQ
ACTIVEMQ_ARCHIVE=$(download_activemq "$ACTIVEMQ_VERSION")
if [ ! -f "$ACTIVEMQ_ARCHIVE" ]; then
    log "ERROR: Failed to download ActiveMQ"
    exit 1
fi

# Crear directorio de instalación
log "Creating ActiveMQ installation directory..."
sudo mkdir -p "$ACTIVEMQ_HOME"

# Extraer ActiveMQ
log "Extracting ActiveMQ to $ACTIVEMQ_HOME..."
sudo tar xzf "$ACTIVEMQ_ARCHIVE" -C "$ACTIVEMQ_HOME" --strip-components=1

# Configurar ActiveMQ
configure_activemq "$ACTIVEMQ_HOME" "$ACTIVEMQ_USER" "$ACTIVEMQ_GROUP"

# Obtener la ruta correcta de JAVA_HOME
DETECTED_JAVA_HOME="${JAVA_HOME:-$(dirname $(dirname $(readlink -f $(which java))))}"

# Crear archivo de servicio systemd
log "Creating ActiveMQ systemd service file..."
cat <<EOF | sudo tee /etc/systemd/system/activemq.service
[Unit]
Description=Apache ActiveMQ Message Broker
Documentation=http://activemq.apache.org/
After=network.target postgresql.service
Requires=postgresql.service
Before=transform.service tomcat.service

[Service]
Type=forking
User=$ACTIVEMQ_USER
Group=$ACTIVEMQ_GROUP
RestartSec=10
Restart=always

Environment="JAVA_HOME=$DETECTED_JAVA_HOME"
Environment="ACTIVEMQ_HOME=$ACTIVEMQ_HOME"
Environment="ACTIVEMQ_BASE=$ACTIVEMQ_HOME"
Environment="ACTIVEMQ_CONF=$ACTIVEMQ_HOME/conf"
Environment="ACTIVEMQ_DATA=$ACTIVEMQ_HOME/data"

# Configuraciones de memoria optimizadas
Environment="ACTIVEMQ_OPTS=-Xms1024M -Xmx2048M -Djava.awt.headless=true -Djava.io.tmpdir=$ACTIVEMQ_HOME/tmp"

# Configuraciones de seguridad
Environment="ACTIVEMQ_SUNJMX_START=-Dcom.sun.management.jmxremote=false"

ExecStart=$ACTIVEMQ_HOME/bin/activemq start
ExecStop=$ACTIVEMQ_HOME/bin/activemq stop
ExecReload=$ACTIVEMQ_HOME/bin/activemq restart

PIDFile=$ACTIVEMQ_HOME/data/activemq.pid

# Security settings
PrivateTmp=yes
ProtectSystem=strict
ReadWritePaths=$ACTIVEMQ_HOME
NoNewPrivileges=yes
ProtectKernelTunables=yes
ProtectControlGroups=yes
RestrictRealtime=yes

[Install]
WantedBy=multi-user.target
EOF

# Crear directorio temporal si no existe
sudo mkdir -p "$ACTIVEMQ_HOME/tmp"
sudo chown -R "$ACTIVEMQ_USER:$ACTIVEMQ_GROUP" "$ACTIVEMQ_HOME/tmp"

# Configurar logrotate para los logs de ActiveMQ
log "Setting up log rotation for ActiveMQ..."
cat <<EOF | sudo tee /etc/logrotate.d/activemq
$ACTIVEMQ_HOME/data/*.log {
    daily
    missingok
    rotate 30
    compress
    delaycompress
    notifempty
    create 644 $ACTIVEMQ_USER $ACTIVEMQ_GROUP
    postrotate
        systemctl reload activemq || true
    endscript
}
EOF

# Recargar systemd y habilitar el servicio
log "Reloading systemd daemon..."
sudo systemctl daemon-reload

log "Enabling ActiveMQ service to start on boot..."
sudo systemctl enable activemq

# Limpiar archivos temporales
log "Cleaning up temporary files..."
rm -f "$ACTIVEMQ_ARCHIVE"

# Verificación final
log "Verifying ActiveMQ installation..."
if [ -f "$ACTIVEMQ_HOME/bin/activemq" ] && [ -x "$ACTIVEMQ_HOME/bin/activemq" ]; then
    log "✓ ActiveMQ installation verified"
else
    log "ERROR: ActiveMQ installation verification failed"
    exit 1
fi

# Mostrar resumen de la instalación
log "=== ActiveMQ Installation Summary ==="
log "ActiveMQ Version: $ACTIVEMQ_VERSION"
log "Installation Path: $ACTIVEMQ_HOME"
log "User/Group: $ACTIVEMQ_USER:$ACTIVEMQ_GROUP"
log "Java Home: $DETECTED_JAVA_HOME"
log "Service File: /etc/systemd/system/activemq.service"
log "Configuration: $ACTIVEMQ_HOME/conf/activemq.xml"
log "Data Directory: $ACTIVEMQ_HOME/data"

log "=== Connection Details ==="
log "OpenWire (JMS): tcp://localhost:61616"
log "AMQP: amqp://localhost:5672"
log "STOMP: stomp://localhost:61613"
log "MQTT: mqtt://localhost:1883"
log "WebSocket: ws://localhost:61614"
log "Web Console: http://localhost:8161/"

log "=== Web Console Credentials ==="
log "Admin User: admin / admin"
log "Regular User: user / user"

log "=== Service Management ==="
log "Start ActiveMQ: sudo systemctl start activemq"
log "Stop ActiveMQ:  sudo systemctl stop activemq"
log "Status:         sudo systemctl status activemq"
log "Logs:           sudo journalctl -u activemq -f"
log "ActiveMQ Log:   tail -f $ACTIVEMQ_HOME/data/activemq.log"

log "=== Important Notes ==="
log "• ActiveMQ is configured with optimized settings for Alfresco"
log "• Memory settings: -Xms1024M -Xmx2048M (adjust based on available RAM)"
log "• Multiple transport connectors enabled (OpenWire, AMQP, STOMP, MQTT, WS)"
log "• Log rotation configured to manage log file sizes"
log "• Service will auto-start on boot and restart on failure"

log "🎉 Apache ActiveMQ installation and setup completed successfully!"

# Test del servicio
log "Testing ActiveMQ service configuration..."
if sudo systemctl start activemq; then
    sleep 15
    if sudo systemctl is-active --quiet activemq; then
        log "✅ ActiveMQ service test successful"
        
        # Test de conectividad a la consola web
        if command_exists curl; then
            log "Testing web console connectivity..."
            if curl -f -s --connect-timeout 10 --max-time 10 "http://localhost:8161/" >/dev/null 2>&1; then
                log "✅ Web console is accessible"
            else
                log "⚠️  Web console test failed - may need more time to start"
            fi
        fi
        
        sudo systemctl stop activemq
        log "Service stopped for final configuration"
    else
        log "⚠️  ActiveMQ service test failed - check configuration"
        sudo systemctl status activemq --no-pager || true
    fi
else
    log "⚠️  Could not start ActiveMQ service - will need troubleshooting"
fi