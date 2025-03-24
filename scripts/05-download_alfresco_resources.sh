#!/bin/bash

# Function to get the latest version of a component
get_latest_version() {
  local base_url=$1
  curl -s "$base_url" \
  | sed -n 's/.*<a href="\(.*\)\/">.*/\1/p' \
  | grep -E '^[0-9]+(\.[0-9]+)*$' \
  | sort -V \
  | tail -n 1
}

# Base URLs for the components
alfresco_content_base_url="https://nexus.alfresco.com/nexus/service/rest/repository/browse/releases/org/alfresco/alfresco-content-services-community-distribution/"
alfresco_search_base_url="https://nexus.alfresco.com/nexus/service/rest/repository/browse/releases/org/alfresco/alfresco-search-services/"
alfresco_transform_core_base_url="https://nexus.alfresco.com/nexus/service/rest/repository/browse/releases/org/alfresco/alfresco-transform-core-aio/"

# Fetch the latest versions
latest_alfresco_content_version=$(get_latest_version "$alfresco_content_base_url")
latest_alfresco_search_version=$(get_latest_version "$alfresco_search_base_url")
latest_alfresco_transform_core_version=$(get_latest_version "$alfresco_transform_core_base_url")

# Construct the download URLs
alfresco_content_url="https://nexus.alfresco.com/nexus/repository/releases/org/alfresco/alfresco-content-services-community-distribution/$latest_alfresco_content_version/alfresco-content-services-community-distribution-$latest_alfresco_content_version.zip"
alfresco_search_url="https://nexus.alfresco.com/nexus/repository/releases/org/alfresco/alfresco-search-services/$latest_alfresco_search_version/alfresco-search-services-$latest_alfresco_search_version.zip"
alfresco_transform_core_url="https://nexus.alfresco.com/nexus/repository/releases/org/alfresco/alfresco-transform-core-aio/$latest_alfresco_transform_core_version/alfresco-transform-core-aio-$latest_alfresco_transform_core_version.jar"

# URLs of the resources to be downloaded
URLS=(
  "$alfresco_content_url"
  "$alfresco_search_url"
  "$alfresco_transform_core_url"
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
