#!/bin/bash

# URLs of the resources to be downloaded
URLS=(
  "https://nexus.alfresco.com/nexus/repository/releases/org/alfresco/alfresco-content-services-community-distribution/23.2.1/alfresco-content-services-community-distribution-23.2.1.zip"
  "https://nexus.alfresco.com/nexus/repository/releases/org/alfresco/alfresco-search-services/2.0.9.1/alfresco-search-services-2.0.9.1.zip"
  "https://nexus.alfresco.com/nexus/repository/releases/org/alfresco/alfresco-transform-core-aio/5.1.0/alfresco-transform-core-aio-5.1.0.jar"
)


# Directory to save the downloaded files
DOWNLOAD_DIR="./downloads"

# Create the download directory if it does not exist
mkdir -p "$DOWNLOAD_DIR"

# Function to download a file
download_file() {
  local url=$1
  local dest_dir=$2
  local filename=$(basename "$url")
  
  echo "Downloading $filename..."
  curl -L -o "$dest_dir/$filename" -w "\nHTTP Status: %{http_code}\n" "$url"
  
  if [ $? -eq 0 ]; then
    echo "Downloaded $filename successfully."
  else
    echo "Failed to download $filename."
  fi
  
  # Check if the file size is greater than 0 bytes
  if [ ! -s "$dest_dir/$filename" ]; then
    echo "Warning: Downloaded file $filename is empty."
  fi
}

# Loop through each URL and download the file
for url in "${URLS[@]}"; do
  download_file "$url" "$DOWNLOAD_DIR"
done

echo "All downloads are complete."

