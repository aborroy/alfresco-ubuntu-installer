#!/bin/bash

set -e

echo "Updating package list..."
sudo apt update

echo "Installing Java JDK 17..."
sudo apt install -y openjdk-17-jdk

echo "Setting Java 17 as the default Java version..."
sudo update-alternatives --install /usr/bin/java java /usr/lib/jvm/java-17-openjdk-amd64/bin/java 1
sudo update-alternatives --install /usr/bin/javac javac /usr/lib/jvm/java-17-openjdk-amd64/bin/javac 1
sudo update-alternatives --set java /usr/lib/jvm/java-17-openjdk-amd64/bin/java
sudo update-alternatives --set javac /usr/lib/jvm/java-17-openjdk-amd64/bin/javac

echo "Checking Java version..."
java -version

echo "Java JDK 17 installation and setup completed successfully!"