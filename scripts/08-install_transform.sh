#!/bin/bash

set -e

echo "Install Transform dependencies"
sudo apt-get update &&
sudo apt install -y imagemagick &&
sudo apt install -y libreoffice &&
sudo apt install -y exiftool

latest_version=$(curl -s https://nexus.alfresco.com/nexus/service/rest/repository/browse/releases/org/alfresco/alfresco-pdf-renderer/ \
| sed -n 's/.*<a href="\(.*\)\/">.*/\1/p' \
| grep -E '^[0-9]+(\.[0-9]+)*$' \
| sort -V \
| tail -n 1
)

curl -L -o /tmp/alfresco-pdf-renderer-$latest_version-linux.tgz https://nexus.alfresco.com/nexus/repository/releases/org/alfresco/alfresco-pdf-renderer/$latest_version/alfresco-pdf-renderer-$latest_version-linux.tgz &&
sudo tar xf /tmp/alfresco-pdf-renderer-$latest_version-linux.tgz -C /usr/bin

echo "Configure Transform server"
mkdir /home/ubuntu/transform
cp downloads/alfresco-transform-core-aio-*.jar /home/ubuntu/transform

# Variables
TRANSFORM_USER=ubuntu
TRANSFORM_GROUP=ubuntu
TRANSFORM_HOME=/home/ubuntu/transform

echo "Creating Transform systemd service file..."
cat <<EOL | sudo tee /etc/systemd/system/transform.service
[Unit]
Description=Transform Application Container
After=network.target activemq.service
Requires=activemq.service

[Service]
Type=simple

User=$TRANSFORM_USER
Group=$TRANSFORM_GROUP

Environment="JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64"
Environment="LIBREOFFICE_HOME=/usr/lib/libreoffice"
############################################ ADJUST THE LINE BELOW TO REFLECT THE CORRECT JAR FILE ##########################################
ExecStart=java -jar /home/ubuntu/transform/alfresco-transform-core-aio-5.1.7.jar
ExecStop=/bin/kill -15 $MAINPID

[Install]
WantedBy=multi-user.target
EOL

echo "Reloading systemd daemon..."
sudo systemctl daemon-reload

echo "Starting Transform service..."
sudo systemctl start transform

echo "Stopping Transform service..."
sudo systemctl stop transform

echo "Enabling Transform service to start on boot..."
sudo systemctl enable transform

echo "Transform has been configured"
