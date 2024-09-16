#!/bin/bash

set -e

# Variables
ACTIVEMQ_USER=ubuntu
ACTIVEMQ_GROUP=ubuntu
ACTIVEMQ_HOME=/home/ubuntu/activemq

# Function to fetch the latest ActiveMQ version
fetch_latest_version() {
# Fetches the latest version 5.*.*
  curl -s https://dlcdn.apache.org/activemq/ | grep -oP '5+\.[0-9]+\.[0-9]+' | tail -1 | sed 's/v//'
# Fetches the latest version 6.*.*
# curl -s https://dlcdn.apache.org/activemq/ | grep -oP '[0-9]+\.[0-9]+\.[0-9]+' | tail -1 | sed 's/v//'
}

# Automatically fetch the latest ActiveMQ version
ACTIVEMQ_VERSION=$(fetch_latest_version)

echo "Using ActiveMQ version: $ACTIVEMQ_VERSION"

echo "Updating package list..."
sudo apt update

echo "Downloading ActiveMQ..."
wget https://dlcdn.apache.org/activemq/$ACTIVEMQ_VERSION/apache-activemq-$ACTIVEMQ_VERSION-bin.tar.gz -O /tmp/apache-activemq-$ACTIVEMQ_VERSION-bin.tar.gz

echo "Extracting ActiveMQ..."
sudo mkdir -p $ACTIVEMQ_HOME
sudo tar xzvf /tmp/apache-activemq-$ACTIVEMQ_VERSION-bin.tar.gz -C $ACTIVEMQ_HOME --strip-components=1

echo "Setting permissions for ActiveMQ directories..."
sudo chown -R $ACTIVEMQ_USER:$ACTIVEMQ_GROUP $ACTIVEMQ_HOME
sudo chmod -R 755 $ACTIVEMQ_HOME

echo "Creating ActiveMQ systemd service file..."
cat <<EOL | sudo tee /etc/systemd/system/activemq.service
[Unit]
Description=Apache ActiveMQ
After=network.target

[Service]
Type=forking

User=$ACTIVEMQ_USER
Group=$ACTIVEMQ_GROUP

Environment="JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64"
Environment="ACTIVEMQ_HOME=$ACTIVEMQ_HOME"
Environment="ACTIVEMQ_BASE=$ACTIVEMQ_HOME"
Environment="ACTIVEMQ_CONF=$ACTIVEMQ_HOME/conf"
Environment="ACTIVEMQ_DATA=$ACTIVEMQ_HOME/data"

ExecStart=$ACTIVEMQ_HOME/bin/activemq start
ExecStop=$ACTIVEMQ_HOME/bin/activemq stop

[Install]
WantedBy=multi-user.target
EOL

echo "Reloading systemd daemon..."
sudo systemctl daemon-reload

echo "Starting ActiveMQ service..."
sudo systemctl start activemq

echo "Stopping ActiveMQ service..."
sudo systemctl stop activemq

echo "Enabling ActiveMQ service to start on boot..."
sudo systemctl enable activemq

echo "Apache ActiveMQ installation and setup completed successfully!"
