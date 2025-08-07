#!/bin/bash

# ==============================================================================
#                      Task 1: Create Infrastructure for the Virtual Machine
# ==============================================================================
echo "--- Task 1: Creating VM infrastructure ---"

# Set project ID
gcloud config set project qwiklabs-gcp-04-1ae1a2336233

# Create a public static IP address
echo "Creating a public static IP address..."
gcloud compute addresses create eth-mainnet-rpc-ip \
    --region=REGION \
    --network-tier=PREMIUM

# Create a firewall rule
echo "Creating a firewall rule..."
gcloud compute firewall-rules create eth-rpc-node-fw \
    --direction=INGRESS \
    --priority=1000 \
    --network=default \
    --action=ALLOW \
    --rules=tcp:30303,tcp:9000,tcp:8545,udp:30303,udp:9000 \
    --source-ranges=0.0.0.0/0 \
    --target-tags=eth-rpc-node

# Create a service account
echo "Creating a service account..."
gcloud iam service-accounts create eth-rpc-node-sa \
    --display-name="eth-rpc-node-sa"

echo "Adding roles to the service account..."
gcloud projects add-iam-policy-binding qwiklabs-gcp-04-1ae1a2336233 \
    --member="serviceAccount:eth-rpc-node-sa@qwiklabs-gcp-04-1ae1a2336233.iam.gserviceaccount.com" \
    --role="roles/compute.osLogin"
gcloud projects add-iam-policy-binding qwiklabs-gcp-04-1ae1a2336233 \
    --member="serviceAccount:eth-rpc-node-sa@qwiklabs-gcp-04-1ae1a2336233.iam.gserviceaccount.com" \
    --role="roles/servicecontrol.serviceController"
gcloud projects add-iam-policy-binding qwiklabs-gcp-04-1ae1a2336233 \
    --member="serviceAccount:eth-rpc-node-sa@qwiklabs-gcp-04-1ae1a2336233.iam.gserviceaccount.com" \
    --role="roles/logging.logWriter"
gcloud projects add-iam-policy-binding qwiklabs-gcp-04-1ae1a2336233 \
    --member="serviceAccount:eth-rpc-node-sa@qwiklabs-gcp-04-1ae1a2336233.iam.gserviceaccount.com" \
    --role="roles/monitoring.metricWriter"
gcloud projects add-iam-policy-binding qwiklabs-gcp-04-1ae1a2336233 \
    --member="serviceAccount:eth-rpc-node-sa@qwiklabs-gcp-04-1ae1a2336233.iam.gserviceaccount.com" \
    --role="roles/cloudtrace.agent"
gcloud projects add-iam-policy-binding qwiklabs-gcp-04-1ae1a2336233 \
    --member="serviceAccount:eth-rpc-node-sa@qwiklabs-gcp-04-1ae1a2336233.iam.gserviceaccount.com" \
    --role="roles/compute.networkUser"

# Create a snapshot schedule
echo "Creating a snapshot schedule..."
gcloud compute resource-policies create snapshot-schedule eth-mainnet-rpc-node-disk-snapshot \
    --region=REGION \
    --daily-schedule \
    --start-time=18:00 \
    --on-source-disk-delete=keep-schedule \
    --retention-days=7

# Create a Virtual Machine
echo "Creating a VM instance with attached disk..."
gcloud compute instances create eth-mainnet-rpc-node \
    --project=qwiklabs-gcp-04-1ae1a2336233 \
    --zone=ZONE \
    --machine-type=e2-standard-4 \
    --network-interface=network-tier=PREMIUM,subnet=default,no-address,aliases=eth-mainnet-rpc-ip \
    --maintenance-policy=MIGRATE \
    --tags=eth-rpc-node \
    --service-account=eth-rpc-node-sa@qwiklabs-gcp-04-1ae1a2336233.iam.gserviceaccount.com \
    --scopes=https://www.googleapis.com/auth/cloud-platform \
    --disk=name=eth-mainnet-rpc-node-disk,device-name=eth-mainnet-rpc-node-disk,mode=rw,size=200GB,type=pd-ssd \
    --image-family=ubuntu-2404-lts \
    --image-project=ubuntu-os-cloud \
    --boot-disk-size=50GB \
    --boot-disk-type=pd-ssd \
    --no-shielded-secure-boot \
    --no-enable-display-device \
    --reservation-affinity=any

echo "Waiting for VM to be ready..."
sleep 60

# Assign the static IP to the VM
echo "Assigning static IP to the VM..."
gcloud compute instances add-access-config eth-mainnet-rpc-node \
    --zone=ZONE \
    --address=eth-mainnet-rpc-ip

# Attach snapshot schedule to disk
echo "Attaching snapshot schedule to the disk..."
gcloud compute disks add-resource-policies eth-mainnet-rpc-node-disk \
    --zone=ZONE \
    --resource-policies=eth-mainnet-rpc-node-disk-snapshot

# ==============================================================================
#             Task 2: Setup and Installation on the Virtual Machine
# ==============================================================================
echo "--- Task 2: Setting up and installing software on the VM ---"

# SSH into the VM and run setup commands
gcloud compute ssh eth-mainnet-rpc-node --zone=ZONE --command='
  # Create a swap file (40GB swap file with 1MiB block size)
  sudo dd if=/dev/zero of=/swapfile bs=1MiB count=40KiB
  sudo chmod 0600 /swapfile
  sudo mkswap /swapfile
  echo "/swapfile swap swap defaults 0 0" | sudo tee -a /etc/fstab
  sudo swapon -a

  # Mount the attached disk
  sudo mkfs.ext4 -m 0 -E lazy_itable_init=0,lazy_journal_init=0,discard /dev/sdb
  sudo mkdir -p /mnt/disks/chaindata-disk
  sudo mount -o discard,defaults /dev/sdb /mnt/disks/chaindata-disk
  sudo chmod a+w /mnt/disks/chaindata-disk
  export DISK_UUID=$(findmnt -n -o UUID /dev/sdb)
  echo "UUID=$DISK_UUID /mnt/disks/chaindata-disk ext4 discard,defaults,nofail 0 2" | sudo tee -a /etc/fstab

  # Create a user for Ethereum processes
  sudo useradd -m ethereum
  sudo usermod -aG sudo ethereum
  sudo usermod -aG google-sudoers ethereum
  sudo su ethereum <<EOF
    # Update OS and install common software
    sudo apt update -y
    sudo apt-get update -y
    sudo apt install -y dstat jq

    # Install the Google Cloud Ops Agent
    curl -sSO https://dl.google.com/cloudagents/add-google-cloud-ops-agent-repo.sh
    sudo bash add-google-cloud-ops-agent-repo.sh --also-install
    rm add-google-cloud-ops-agent-repo.sh

    # Create folders for logs and chaindata
    mkdir -p /mnt/disks/chaindata-disk/ethereum/geth/chaindata
    mkdir -p /mnt/disks/chaindata-disk/ethereum/geth/logs
    mkdir -p /mnt/disks/chaindata-disk/ethereum/lighthouse/chaindata
    mkdir -p /mnt/disks/chaindata-disk/ethereum/lighthouse/logs

    # Install Geth
    sudo add-apt-repository -y ppa:ethereum/ethereum
    sudo apt-get -y install ethereum

    # Install Lighthouse
    RELEASE_URL="https://api.github.com/repos/sigp/lighthouse/releases/latest"
    LATEST_VERSION=$(curl -s $RELEASE_URL | jq -r .tag_name)
    DOWNLOAD_URL=$(curl -s $RELEASE_URL | jq -r ".assets[] | select(.name | endswith(\"x86_64-unknown-linux-gnu.tar.gz\")) | .browser_download_url")
    curl -L "$DOWNLOAD_URL" -o "lighthouse-${LATEST_VERSION}-x86_64-unknown-linux-gnu.tar.gz"
    tar -xvf "lighthouse-${LATEST_VERSION}-x86_64-unknown-linux-gnu.tar.gz"
    rm "lighthouse-${LATEST_VERSION}-x86_64-unknown-linux-gnu.tar.gz"
    sudo mv lighthouse /usr/bin

    # Create JWT secret for Geth and Lighthouse communication
    mkdir -p ~/.secret
    openssl rand -hex 32 > ~/.secret/jwtsecret
    chmod 440 ~/.secret/jwtsecret
EOF
'

# ==============================================================================
#       Task 3: Start the Ethereum Execution and Consensus Clients
# ==============================================================================
echo "--- Task 3: Starting Geth and Lighthouse clients ---"

# SSH into the VM to start the clients
gcloud compute ssh eth-mainnet-rpc-node --zone=ZONE --command='
  # Switch to ethereum user
  sudo su ethereum <<EOF
    # Set environment variables for Geth
    export CHAIN=eth
    export NETWORK=mainnet
    export EXT_IP_ADDRESS_NAME=$CHAIN-$NETWORK-rpc-ip
    export EXT_IP_ADDRESS=$(gcloud compute addresses list --filter=$EXT_IP_ADDRESS_NAME --format="value(address)")

    # Start Geth as a background process (execution client)
    nohup geth --datadir "/mnt/disks/chaindata-disk/ethereum/geth/chaindata" \
      --http.corsdomain "*" \
      --http \
      --http.addr 0.0.0.0 \
      --http.port 8545 \
      --http.api admin,debug,web3,eth,txpool,net \
      --http.vhosts "*" \
      --gcmode full \
      --cache 2048 \
      --mainnet \
      --metrics \
      --metrics.addr 127.0.0.1 \
      --syncmode snap \
      --authrpc.vhosts="localhost" \
      --authrpc.port 8551 \
      --authrpc.jwtsecret=/home/ethereum/.secret/jwtsecret \
      --nat extip:$EXT_IP_ADDRESS \
      --txpool.accountslots 32 \
      --txpool.globalslots 8192 \
      --txpool.accountqueue 128 \
      --txpool.globalqueue 2048 \
      &> "/mnt/disks/chaindata-disk/ethereum/geth/logs/geth.log" &

    # Wait for Geth to start before launching Lighthouse
    sleep 30

    # Start Lighthouse as a background process (consensus client)
    nohup lighthouse bn \
      --network mainnet \
      --http \
      --metrics \
      --datadir /mnt/disks/chaindata-disk/ethereum/lighthouse/chaindata \
      --execution-jwt /home/ethereum/.secret/jwtsecret \
      --execution-endpoint http://localhost:8551 \
      --checkpoint-sync-url https://sync-mainnet.beaconcha.in \
      --disable-deposit-contract-sync \
      &> "/mnt/disks/chaindata-disk/ethereum/lighthouse/logs/lighthouse.log" &
EOF
'

# ==============================================================================
#                 Task 4: Configure Cloud Operations
# ==============================================================================
echo "--- Task 4: Configuring Cloud operations ---"

# SSH into the VM to configure the Ops Agent
gcloud compute ssh eth-mainnet-rpc-node --zone=ZONE --command='
  # Switch to root to modify ops agent config
  sudo -s <<EOF
    # Configure Cloud Logging
    chmod 666 /etc/google-cloud-ops-agent/config.yaml
    cat <<EOFF >> /etc/google-cloud-ops-agent/config.yaml
logging:
  receivers:
    syslog:
      type: files
      include_paths:
      - /var/log/messages
      - /var/log/syslog
    ethGethLog:
      type: files
      include_paths: ["/mnt/disks/chaindata-disk/ethereum/geth/logs/geth.log"]
      record_log_file_path: true
    ethLighthouseLog:
      type: files
      include_paths: ["/mnt/disks/chaindata-disk/ethereum/lighthouse/logs/lighthouse.log"]
      record_log_file_path: true
    journalLog:
      type: systemd_journald
  service:
    pipelines:
      logging_pipeline:
        receivers:
        - syslog
        - journalLog
        - ethGethLog
        - ethLighthouseLog
EOFF

    # Configure Managed Prometheus
    cat <<EOFF >> /etc/google-cloud-ops-agent/config.yaml
metrics:
  receivers:
    prometheus:
      type: prometheus
      config:
        scrape_configs:
        - job_name: "geth_exporter"
          scrape_interval: 10s
          metrics_path: /debug/metrics/prometheus
          static_configs:
          - targets: ["localhost:6060"]
        - job_name: "lighthouse_exporter"
          scrape_interval: 10s
          metrics_path: /metrics
          static_configs:
          - targets: ["localhost:5054"]
  service:
    pipelines:
      prometheus_pipeline:
        receivers:
        - prometheus
EOFF

    # Restart the Ops Agent
    systemctl stop google-cloud-ops-agent
    systemctl start google-cloud-ops-agent
EOF
'

echo "Skrip selesai. Pastikan untuk mengganti 'REGION' dan 'ZONE' dengan nilai yang sesuai."