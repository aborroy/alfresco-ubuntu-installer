#!/bin/bash

# Exit script on any error
set -e

# Update and upgrade the system
echo "Updating system..."
sudo apt update && sudo apt upgrade -y

# Install Nginx
echo "Installing Nginx..."
sudo apt install -y nginx

# Create directory for the Alfresco Content App
echo "Creating directory for Alfresco Content App..."
sudo mkdir -p /var/www/alfresco-content-app
sudo cp -r /home/ubuntu/alfresco-content-app/dist/content-ce/* /var/www/alfresco-content-app

echo "Creating nginx systemd service file..."
cat <<EOL | sudo tee /etc/systemd/system/nginx.service
[Unit]
Description=A high performance web server and a reverse proxy server
Documentation=man:nginx(8)
After=network.target remote-fs.target nss-lookup.target

[Service]
Type=forking
PIDFile=/run/nginx.pid
ExecStartPre=/usr/sbin/nginx -t -q -g 'daemon on; master_process on;'
ExecStart=/usr/sbin/nginx -g 'daemon on; master_process on;'
ExecReload=/usr/sbin/nginx -g 'daemon on; master_process on;' -s reload
ExecStop=/bin/kill -s QUIT $MAINPID
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOL

echo "Reloading systemd daemon..."
sudo systemctl daemon-reload

echo "Enabling nginx service to start on boot..."
sudo systemctl enable nginx

# Configure Nginx to serve the Alfresco Content App
echo "Configuring Nginx..."
cat <<EOL | sudo tee /etc/nginx/sites-available/alfresco-content-app
server {
    listen 80;
    server_name localhost;

    client_max_body_size 0;

    set  \$allowOriginSite *;
    proxy_pass_request_headers on;
    proxy_pass_header Set-Cookie;

    proxy_next_upstream error timeout invalid_header http_500 http_502 http_503 http_504;
    proxy_redirect off;
    proxy_buffering off;
    proxy_set_header Host            \$host:\$server_port;
    proxy_set_header X-Real-IP       \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_pass_header Set-Cookie;    

    root /var/www/alfresco-content-app;
    index index.html;

    location / {
        try_files \$uri \$uri/ /index.html;
    }

    location /alfresco/ {
        proxy_pass http://localhost:8080;
    }

    location /share/ {
        proxy_pass http://localhost:8080;
    }    
}
EOL


# Enable the new Nginx configuration
echo "Enabling Nginx configuration..."
sudo ln -s /etc/nginx/sites-available/alfresco-content-app /etc/nginx/sites-enabled/
sudo nginx -t
sudo systemctl restart nginx

sudo systemctl stop nginx

# Instructions to transfer the built files
echo "Nginx setup complete."