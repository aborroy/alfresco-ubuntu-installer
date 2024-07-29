#!/bin/bash

set -e

echo "Updating package list..."
sudo apt update

echo "Installing PostgreSQL..."
sudo apt install -y postgresql postgresql-contrib

echo "Enable local connections"
sudo sed -i 's/local\s\+all\s\+postgres\s\+peer/local   all             postgres                                trust/' /etc/postgresql/16/main/pg_hba.conf
sudo sed -i 's/local\s\+all\s\+all\s\+peer/local   all             all                                md5/' /etc/postgresql/16/main/pg_hba.conf

echo "Stopping PostgreSQL service..."
sudo systemctl stop postgresql

echo "Starting PostgreSQL service..."
sudo systemctl start postgresql

echo "Configuring Alfresco database..."
psql -U postgres -c "CREATE USER alfresco WITH PASSWORD 'alfresco';"
psql -U postgres -c "CREATE DATABASE alfresco OWNER alfresco ENCODING 'UTF8';"
psql -U postgres -c "GRANT ALL PRIVILEGES ON DATABASE alfresco TO alfresco;"

echo "Stopping PostgreSQL service..."
sudo systemctl stop postgresql

echo "Enabling PostgreSQL to start on boot..."
sudo systemctl enable postgresql

echo "PostgreSQL installation and setup completed successfully!"