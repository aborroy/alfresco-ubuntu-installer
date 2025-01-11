# Alfresco installation in Ubuntu using ZIP Distribution Files

Alfresco Platform provides flexibility in deployment, accommodating various infrastructures and operational preferences. 

Below are several deployment approaches:

**[ZIP Distribution files](https://docs.alfresco.com/content-services/latest/install/zip/)**

Deploying Alfresco using ZIP distribution files involves manually configuring and installing Alfresco on servers. This approach allows for detailed customization of the installation process, making it suitable for environments where specific configurations or integrations are required.

**[Ansible](https://docs.alfresco.com/content-services/latest/install/ansible/)**

Ansible automation simplifies the deployment and management of Alfresco across multiple servers. Ansible playbooks automate the installation and configuration tasks, ensuring consistency and reducing deployment time. This method is ideal for environments requiring rapid deployment and scalability.

**[Containers](https://docs.alfresco.com/content-services/latest/install/containers/)**

Containerization of Alfresco leverages Docker and Kubernetes technologies, offering a modern approach to deployment:

   - **[Docker Compose](https://docs.alfresco.com/content-services/latest/install/containers/docker-compose/)**: Docker Compose simplifies the orchestration of multiple Alfresco services, such as Alfresco Content Repository, ActiveMQ, Elasticsearch, and others, defined in a single YAML file. It facilitates deployment in development, testing, and small-scale production environments.

   - **[Helm](https://docs.alfresco.com/content-services/latest/install/containers/helm/)**: Helm charts streamline the deployment of Alfresco on Kubernetes clusters. Helm manages Kubernetes applications through easy-to-use templates (charts) and package management. It enables scalability, version control, and rollback capabilities, making it suitable for production-grade deployments.

This project provides a sample **ZIP Distribution Files** configuration for deploying the Alfresco Platform.

## Contents

This project provides a collection of `bash` scripts designed to automate various installation and setup tasks on an Ubuntu system. Each script handles a specific component or service, ensuring a streamlined and repeatable setup process. Below is a list of the available scripts along with their descriptions:

1. **PostgreSQL Installation**
   - Script: [01-install_postgres.sh](scripts/01-install_postgres.sh)
   - Description: Installs and configures PostgreSQL, to be used as object-relational database system.

2. **Java Installation**
   - Script: [02-install_java.sh](scripts/02-install_java.sh)
   - Description: Installs Java Development Kit (JDK), essential for running Apache Tomcat and Java applications like Apache Solr, Apache ActiveMQ and Transform Service.

3. **Tomcat Installation**
   - Script: [03-install_tomcat.sh](scripts/03-install_tomcat.sh)
   - Description: Installs Apache Tomcat, to deploy Alfresco and Share web applications.

4. **ActiveMQ Installation**
   - Script: [04-install_activemq.sh](scripts/04-install_activemq.sh)
   - Description: Installs Apache ActiveMQ, to be used as messaging server.

5. **Alfresco Resources Download**
   - Script: [05-download_alfresco_resources.sh](scripts/05-download_alfresco_resources.sh)
   - Description: Downloads necessary resources for Alfresco, including web applications, search service and transform service.

6. **Alfresco Installation**
   - Script: [06-install_alfresco.sh](scripts/06-install_alfresco.sh)
   - Description: Installs Alfresco Community Edition, configuring Alfresco and Share web applications.
   - **TIP**: If you use different port numbers for alfresco.port and share.port e.g. alfresco.port=39003 and share.port=39003. Ensure you adjust the same in the following files:
       
         ● 10-install_nginx.sh
         ● /home/ubuntu/tomcat/conf/server.xml
         ● /home/ubuntu/tomcat/shared/classes/alfresco/web-extension/share-config-custom.xml
         ● /home/ubuntu/alfresco-search-services/solrhome/archive/conf/solrcore.properties
         ● /home/ubuntu/alfresco-search-services/solrhome/templates/noRerank/conf/solrcore.properties
         ● /home/ubuntu/alfresco-search-services/solrhome/templates/rerank/conf/solrcore.properties 
         ● /home/ubuntu/alfresco-search-services/solrhome/alfresco/conf/solrcore.properties 
    
   Otherwise, alfresco, solr and share wouldn't work properly i.e., alfresco and share won't allow you to login and solr won't be able to search properly.

7. **Solr Installation**
   - Script: [07-install_solr.sh](scripts/07-install_solr.sh)
   - Description: Installs Apache Solr, to be used as search platform for indexing and searching data.

8. **Transform Service Installation**
   - Script: [08-install_transform.sh](scripts/08-install_transform.sh)
   - Description: Installs services required for document transformations within Alfresco.

9. **Alfresco Content App Building**
   - Script: [09-build_aca.sh](scripts/09-build_aca.sh)
   - Description: Builds static website from NodeJS application ACA. *This task can be performed in a separate server or machine.*

10. **Nginx Installation**
   - Script: [10-install_nginx.sh](scripts/10-install_nginx.sh)
   - Description: Installs web server for ACA and configure web proxy for Alfresco and Share web applications.   

11. **Start Services**
   - Script: [11-start_services.sh](scripts/11-start_services.sh)
   - Description: Starts all the installed services to ensure they are running correctly.

## Usage

Each script can be executed individually in a bash shell. Despiste user `ubuntu` is expected to be used, ensure you have the necessary permissions (e.g., using `sudo` where required).

```bash
bash scripts/01-install_postgres.sh
bash scripts/02-install_java.sh
bash scripts/03-install_tomcat.sh
bash scripts/04-install_activemq.sh
bash scripts/05-download_alfresco_resources.sh
bash scripts/06-install_alfresco.sh
bash scripts/07-install_solr.sh
bash scripts/08-install_transform.sh
bash scripts/09-build_aca.sh
bash scripts/10-install_nginx.sh
```

Although the `11-start_services.sh` script includes the sequence for executing the services, it is recommended to run each line manually. This allows you to verify that each service is up and running correctly before proceeding to the next one.

```bash
sudo systemctl start postgresql
sudo systemctl status postgresql
● postgresql.service - PostgreSQL RDBMS
     Loaded: loaded (/usr/lib/systemd/system/postgresql.service; enabled; preset: ena>
     Active: active (exited) since Mon 2024-07-29 09:46:15 UTC; 19s ago
```

```bash
sudo systemctl start activemq
sudo systemctl status activemq
● activemq.service - Apache ActiveMQ
     Loaded: loaded (/etc/systemd/system/activemq.service; enabled; preset: enabled)
     Active: active (running) since Mon 2024-07-29 09:46:56 UTC; 6s ago
```

```bash
sudo systemctl start transform
sudo systemctl status transform
● transform.service - Transform Application Container
     Loaded: loaded (/etc/systemd/system/transform.service; enabled; preset: enabled)
     Active: active (running) since Mon 2024-07-29 09:47:33 UTC; 8s ago
```

```bash
sudo systemctl start tomcat
sudo systemctl status tomcat
● tomcat.service - Apache Tomcat Web Application Container
     Loaded: loaded (/etc/systemd/system/tomcat.service; enabled; preset: enabled)
     Active: active (running) since Mon 2024-07-29 09:48:15 UTC; 7s ago
tail -f /home/ubuntu/tomcat/logs/catalina.out
...
29-Jul-2024 09:49:08.922 INFO [main] org.apache.catalina.startup.Catalina.start Server startup in [52678] milliseconds
```

```bash
sudo systemctl start solr
sudo systemctl status solr
● solr.service - Apache SOLR Web Application Container
     Loaded: loaded (/etc/systemd/system/solr.service; enabled; preset: enabled)
     Active: active (running) since Mon 2024-07-29 09:49:32 UTC; 11s ago
```

```bash
sudo systemctl start nginx
sudo systemctl status nginx
```

## Verification

Default credentials are `admin`/`admin`

* Alfresco Repository: http://localhost/alfresco

* ACA UI: http://localhost/

* Share UI: http://localhost/share
  - Search "budget" >> 8 results found
  - Access to document "Meeting Notes 2011-01-27.doc" in folder "Meeting Notes" of site "swsdp". PDF Preview must be available.

## Troubleshooting

If you encounter issues while using the project, refer to the specific service sections below for credentials, port information, data directories, and log file locations. This guide provides essential details for managing and diagnosing problems with PostgreSQL, Tomcat, ActiveMQ, Solr, Transform Service, and Nginx.

1. **PostgreSQL**
   - **Credentials:** `alfresco/alfresco`
   - **Port:** `5432`
   - **Data Directory:** `/var/lib/postgresql/16`
   - **Log Directory:** `/var/log/postgresql`

2. **Tomcat (Alfresco + Share)**
   - **Credentials:** `admin/admin`
   - **Port:** `8080`
   - **Data Directory:** `/home/ubuntu/alf_data` (Alfresco filesystem)
   - **Log Directory:** `/home/ubuntu/tomcat/logs`

3. **ActiveMQ**
   - **Credentials:** `admin/admin`
   - **Ports:**
     - Web Console: `8161`
     - OpenWire: `61616`
   - **Data Directory:** `/home/ubuntu/activemq/data`
   - **Log Directory:** `/home/ubuntu/activemq/data`

4. **Solr**
   - **Credentials:** HTTP Header with `X-Alfresco-Search-Secret: secret`
   - **Port:** `8983`
   - **Data Directory:** `/home/ubuntu/alfresco-search-services/solrhome`
   - **Log Directory:** `/home/ubuntu/alfresco-search-services/logs`

5. **Transform Service**
   - **Port:** `8090`
   - **Logs URL:** [http://localhost:8090/log](http://localhost:8090/log)

6. **Nginx**
   - **Port:** `80`
   - **Log Directory:** `/var/log/nginx/`
