#!/bin/bash
# ==========================================
# Security Command Center Lab Automation
# ==========================================
# Pastikan Cloud SDK sudah terinstal & aktif
# Jalankan di Google Cloud Shell

# ------------------------------
# 1. Set project & autentikasi
# ------------------------------
# Ganti <PROJECT_ID> sesuai lab Anda
PROJECT_ID="qwiklabs-gcp-01-1f6d016925ba"
gcloud config set project "$PROJECT_ID"

# (Opsional) cek akun aktif
gcloud auth list

# ------------------------------
# 2. Aktifkan Security Command Center & modul
# ------------------------------
# Mengaktifkan Security Health Analytics module: VPC_FLOW_LOGS_SETTINGS_NOT_RECOMMENDED
gcloud scc settings services enable --service=SECURITY_HEALTH_ANALYTICS --project="$PROJECT_ID"

gcloud scc settings modules update VPC_FLOW_LOGS_SETTINGS_NOT_RECOMMENDED \
    --enable \
    --service=SECURITY_HEALTH_ANALYTICS \
    --project="$PROJECT_ID"

# ------------------------------
# 3. Filter & ubah state finding
# ------------------------------
# Set state finding Default network jadi INACTIVE
gcloud scc findings update \
    "<SOURCE_NAME>" \
    "<FINDING_ID>" \
    --state="INACTIVE" \
    --project="$PROJECT_ID"

# Note:
# - <SOURCE_NAME> biasanya formatnya: organizations/<ORG_ID>/sources/<SOURCE_ID>
# - <FINDING_ID> didapat dari hasil list findings di bawah

# List findings kategori DEFAULT_NETWORK
gcloud scc findings list "<SOURCE_NAME>" \
    --filter='category="DEFAULT_NETWORK"' \
    --project="$PROJECT_ID"

# ------------------------------
# 4. Membuat mute rule untuk FLOW_LOGS_DISABLED
# ------------------------------
gcloud scc mute-configs create muting-pga-findings \
    --description="Mute rule for VPC Flow Logs" \
    --filter='category="FLOW_LOGS_DISABLED"' \
    --project="$PROJECT_ID"

# ------------------------------
# 5. Membuat VPC network baru (uji mute rule)
# ------------------------------
gcloud compute networks create scc-lab-net --subnet-mode=auto

# ------------------------------
# 6. Perbaikan temuan High Severity
# ------------------------------
# Update firewall rule untuk Open RDP port
# Ganti <RULE_NAME_RDP> dengan nama rule yang muncul di SCC (contoh: default-allow-rdp)
gcloud compute firewall-rules update <RULE_NAME_RDP> \
    --source-ranges=35.235.240.0/20

# Update firewall rule untuk Open SSH port
# Ganti <RULE_NAME_SSH> dengan nama rule yang muncul di SCC (contoh: default-allow-ssh)
gcloud compute firewall-rules update <RULE_NAME_SSH> \
    --source-ranges=35.235.240.0/20

# ------------------------------
# 7. Verifikasi temuan
# ------------------------------
# Cek semua temuan aktif yang belum dimute
gcloud scc findings list "<SOURCE_NAME>" \
    --filter='state="ACTIVE" AND NOT mute="MUTED"' \
    --project="$PROJECT_ID"
