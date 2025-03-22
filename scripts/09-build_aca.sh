#!/bin/bash

set -e

# Install Node.js and npm (LTS version)
echo "Installing Node.js and npm..."
curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -
sudo apt install -y nodejs

# Verify Node.js and npm installation
echo "Verifying Node.js and npm installation..."
node -v
npm -v

echo "Installing Git..."
sudo apt install -y git
# Clone the Alfresco Content App repository
git clone https://github.com/Alfresco/alfresco-content-app.git
cd alfresco-content-app

# Fetch the latest version tag dynamically
echo "Fetching the latest version tag..."
latest_tag=$(git ls-remote --tags --sort="v:refname" https://github.com/Alfresco/alfresco-content-app.git \
  | grep -o 'refs/tags/[0-9]*\.[0-9]*\.[0-9]*' \
  | tail -n 1 \
  | sed 's/refs\/tags\///')

# Checkout to the latest version tag
echo "Checking out to the latest version: $latest_tag"
git checkout tags/$latest_tag -b $latest_tag

# Install project dependencies
npm install

# Build the application for production
npm run build
