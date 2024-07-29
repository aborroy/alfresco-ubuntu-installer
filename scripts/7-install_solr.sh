#!/bin/bash

set -e

echo "Unzip SOLR ZIP Distribution File"
mkdir /tmp/solr
unzip downloads/alfresco-search-services-2.0.9.1.zip -d /tmp/solr
mv /tmp/solr/alfresco-search-services /home/ubuntu

# Variables
SOLR_USER=ubuntu
SOLR_GROUP=ubuntu
SOLR_HOME=/home/ubuntu/alfresco-search-services

echo "Creating SOLR systemd service file..."
cat <<EOL | sudo tee /etc/systemd/system/solr.service
[Unit]
Description=Apache SOLR Web Application Container
After=network.target

[Service]
Type=forking

User=$SOLR_USER
Group=$SOLR_GROUP

Environment="JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64"

ExecStart=/home/ubuntu/alfresco-search-services/solr/bin/solr start -a "-Dcreate.alfresco.defaults=alfresco,archive -Dalfresco.secureComms=secret -Dalfresco.secureComms.secret=secret"
ExecStop=/home/ubuntu/alfresco-search-services/solr/bin/solr stop

[Install]
WantedBy=multi-user.target
EOL

echo "Reloading systemd daemon..."
sudo systemctl daemon-reload

echo "Starting Solr service..."
sudo systemctl start solr

echo "Stopping Solr service..."
sudo systemctl stop solr

echo "Enabling Solr service to start on boot..."
sudo systemctl enable solr

echo "SOLR has been configured"