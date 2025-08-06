#!/bin/bash

# === Task 1: Create Swap File and Mount Disk ===
echo "[INFO] Creating swap file..."
sudo dd if=/dev/zero of=/swapfile bs=1M count=40960
sudo chmod 0600 /swapfile
sudo mkswap /swapfile
echo "/swapfile swap swap defaults 0 0" | sudo tee -a /etc/fstab
sudo swapon -a
free -g

echo "[INFO] Formatting and mounting disk..."
sudo mkfs.ext4 -m 0 -E lazy_itable_init=0,lazy_journal_init=0,discard /dev/sdb
sudo mkdir -p /mnt/disks/chaindata-disk
sudo mount -o discard,defaults /dev/sdb /mnt/disks/chaindata-disk
sudo chmod a+w /mnt/disks/chaindata-disk
DISK_UUID=$(findmnt -n -o UUID /dev/sdb)
echo "UUID=$DISK_UUID /mnt/disks/chaindata-disk ext4 discard,defaults,nofail 0 2" | sudo tee -a /etc/fstab
df -h

# === Task 2: Create Ethereum User ===
echo "[INFO] Creating ethereum user..."
sudo useradd -m ethereum
sudo usermod -aG sudo ethereum
sudo usermod -aG google-sudoers ethereum

# === Task 3: Setup Ethereum Environment ===
echo "[INFO] Switching to ethereum user..."
sudo su - ethereum <<'EOF'

# Update system and install dependencies
sudo apt update -y
sudo apt-get update -y
sudo apt install -y dstat jq curl

# Install Google Cloud Ops Agent
curl -sSO https://dl.google.com/cloudagents/add-google-cloud-ops-agent-repo.sh
sudo bash add-google-cloud-ops-agent-repo.sh --also-install
rm add-google-cloud-ops-agent-repo.sh

# Create directories for Geth and Lighthouse
mkdir -p /mnt/disks/chaindata-disk/ethereum/geth/chaindata
mkdir -p /mnt/disks/chaindata-disk/ethereum/geth/logs
mkdir -p /mnt/disks/chaindata-disk/ethereum/lighthouse/chaindata
mkdir -p /mnt/disks/chaindata-disk/ethereum/lighthouse/logs

# Install Geth
sudo add-apt-repository -y ppa:ethereum/ethereum
sudo apt-get update -y
sudo apt-get -y install ethereum
geth version

# Install Lighthouse
RELEASE_URL="https://api.github.com/repos/sigp/lighthouse/releases/latest"
LATEST_VERSION=$(curl -s $RELEASE_URL | jq -r '.tag_name')
DOWNLOAD_URL=$(curl -s $RELEASE_URL | jq -r '.assets[] | select(.name | endswith("x86_64-unknown-linux-gnu.tar.gz")) | .browser_download_url')
curl -L "$DOWNLOAD_URL" -o "lighthouse-${LATEST_VERSION}.tar.gz"
tar -xvf "lighthouse-${LATEST_VERSION}.tar.gz"
rm "lighthouse-${LATEST_VERSION}.tar.gz"
sudo mv lighthouse /usr/bin
lighthouse --version

# Create JWT secret
mkdir ~/.secret
openssl rand -hex 32 > ~/.secret/jwtsecret
chmod 440 ~/.secret/jwtsecret

EOF

echo "[INFO] Setup complete. You can now run Geth and Lighthouse manually or script their startup."

#!/bin/bash

# === Validasi dan Setup IP Statis ===
CHAIN="eth"
NETWORK="mainnet"
EXT_IP_NAME="$CHAIN-$NETWORK-rpc-ip"
REGION="us-central1"  # Ubah jika pakai region lain

echo "[INFO] Memeriksa apakah IP statis '$EXT_IP_NAME' sudah ada..."
IP_EXIST=$(gcloud compute addresses list --filter="name=$EXT_IP_NAME" --regions=$REGION --format="value(address)")

if [[ -z "$IP_EXIST" ]]; then
  echo "[WARNING] IP statis belum ada. Membuat IP statis '$EXT_IP_NAME'..."
  gcloud compute addresses create $EXT_IP_NAME \
    --region=$REGION \
    --network-tier=PREMIUM
  if [[ $? -ne 0 ]]; then
    echo "[ERROR] Gagal membuat IP statis. Periksa kredensial dan hak akses akun Anda."
    exit 1
  fi
else
  echo "[INFO] IP statis ditemukan: $IP_EXIST"
fi

# Ambil IP dan set sebagai variabel lingkungan
EXT_IP_ADDRESS=$(gcloud compute addresses describe $EXT_IP_NAME --region=$REGION --format="value(address)")
export EXT_IP_ADDRESS
echo "[INFO] IP statis yang digunakan: $EXT_IP_ADDRESS"
