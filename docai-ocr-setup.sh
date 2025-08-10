#!/usr/bin/env bash
set -Eeuo pipefail

# =========================
# Helpers
# =========================
green() { printf "\033[1;32m%s\033[0m" "$*"; }
blue()  { printf "\033[1;34m%s\033[0m" "$*"; }
red()   { printf "\033[1;31m%s\033[0m" "$*"; }

step() { printf "\n"; blue "[STEP] "; printf "%s\n" "$*"; }
ok()   { green "[OK] "; printf "%s\n" "$*"; }
err()  { red   "[ERR] "; printf "%s\n" "$*"; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { err "Command '$1' tidak ditemukan."; exit 1; }
}

json_get() { # Usage: json_get <json-file> <jq-path> ; fallback ke python jika jq tak ada
  if command -v jq >/dev/null 2>&1; then
    jq -r "$2" "$1"
  else
    python3 - "$1" "$2" <<'PY'
import json,sys
f,p=sys.argv[1],sys.argv[2]
with open(f) as fh:
    j=json.load(fh)
def walk(obj,path):
    # very small subset: .a.b.c only
    parts=[seg for seg in path.strip().split('.') if seg and seg!='.']
    for seg in parts:
        if seg.endswith(']'):
            # not needed here
            pass
        obj=obj.get(seg)
        if obj is None: return ''
    return obj
val=walk(j,sys.argv[2].strip('.'))
print(val if val is not None else '')
PY
  fi
}

# =========================
# Prechecks
# =========================
step "Cek dependencies (gcloud, python3, pip3, curl)"
need_cmd gcloud
need_cmd python3
need_cmd pip3
need_cmd curl
ok "Tools tersedia"

# =========================
# Konfigurasi Project & Lokasi
# =========================
PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value core/project 2>/dev/null || true)}"
if [[ -z "${PROJECT_ID}" ]]; then
  read -rp "Masukkan PROJECT_ID GCP: " PROJECT_ID
fi
if [[ -z "${PROJECT_ID}" ]]; then err "PROJECT_ID wajib diisi."; exit 1; fi

export GOOGLE_CLOUD_PROJECT="${PROJECT_ID}"
gcloud config set project "${PROJECT_ID}" >/dev/null
PROJECT_NUMBER="$(gcloud projects describe "${PROJECT_ID}" --format='value(projectNumber)')"

LOCATION="${LOCATION:-us}" # 'us' atau 'eu'
read -rp "Pilih Document AI LOCATION [us/eu] (default: ${LOCATION}): " TMP_LOC || true
LOCATION="${TMP_LOC:-$LOCATION}"
if [[ "${LOCATION}" != "us" && "${LOCATION}" != "eu" ]]; then
  err "LOCATION harus 'us' atau 'eu'."; exit 1
fi
ok "Project: ${PROJECT_ID} (no: ${PROJECT_NUMBER}), Location: ${LOCATION}"

# =========================
# Enable APIs
# =========================
step "Enable APIs: Document AI & Cloud Storage"
gcloud services enable documentai.googleapis.com storage.googleapis.com
ok "APIs aktif"

# =========================
# Service Account & Kredensial
# =========================
SA_NAME="my-docai-sa"
SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

step "Buat Service Account (jika belum ada): ${SA_EMAIL}"
if ! gcloud iam service-accounts list --format='value(email)' | grep -q "^${SA_EMAIL}$"; then
  gcloud iam service-accounts create "${SA_NAME}" --display-name "my-docai-service-account"
  ok "Service Account dibuat"
else
  ok "Service Account sudah ada"
fi

step "Tambahkan peran ke Service Account (Document AI Admin, Storage Admin, Service Usage Consumer)"
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/documentai.admin" >/dev/null

gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/storage.admin" >/dev/null

gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/serviceusage.serviceUsageConsumer" >/dev/null
ok "IAM binding selesai"

KEY_PATH="$HOME/key.json"
step "Buat key file JSON untuk Service Account di ${KEY_PATH} (jika belum ada)"
if [[ ! -f "${KEY_PATH}" ]]; then
  gcloud iam service-accounts keys create "${KEY_PATH}" --iam-account "${SA_EMAIL}"
  ok "Key dibuat"
else
  ok "Key sudah ada"
fi

export GOOGLE_APPLICATION_CREDENTIALS="${KEY_PATH}"
ok "GOOGLE_APPLICATION_CREDENTIALS diset ke ${KEY_PATH}"

# =========================
# Instal library Python
# =========================
step "Instal library Python: google-cloud-documentai, google-cloud-storage"
pip3 install --user --upgrade google-cloud-documentai google-cloud-storage >/dev/null
ok "Library terinstal"

# Pastikan PATH user site-packages bisa diakses (khusus pip --user di Cloud Shell biasanya OK)
export PYTHONPATH="${PYTHONPATH:-}"

# =========================
# Buat Processor OCR (otomatis)
# =========================
DOC_AI_EP="https://${LOCATION}-documentai.googleapis.com"
AUTH_HDR="Authorization: Bearer $(gcloud auth print-access-token)"

step "Cek apakah processor 'lab-ocr' sudah ada"
TMP_LIST="$(mktemp)"
curl -sS -H "${AUTH_HDR}" \
  "${DOC_AI_EP}/v1/projects/${PROJECT_ID}/locations/${LOCATION}/processors" > "${TMP_LIST}"

# Cari processor 'lab-ocr' bertipe OCR_PROCESSOR
PROCESSOR_NAME="$(python3 - "$TMP_LIST" <<'PY'
import json,sys
data=json.load(open(sys.argv[1]))
for p in data.get("processors",[]):
    if p.get("displayName")=="lab-ocr" and p.get("type")=="OCR_PROCESSOR":
        print(p.get("name",""))
        break
PY
)"
if [[ -z "${PROCESSOR_NAME}" ]]; then
  step "Membuat processor OCR 'lab-ocr' via REST"
  BODY_FILE="$(mktemp)"
  cat > "${BODY_FILE}" <<JSON
{"displayName":"lab-ocr","type":"OCR_PROCESSOR"}
JSON
  CREATE_OUT="$(mktemp)"
  set +e
  curl -sS -X POST -H "Content-Type: application/json" -H "${AUTH_HDR}" \
    -d @"${BODY_FILE}" \
    "${DOC_AI_EP}/v1/projects/${PROJECT_ID}/locations/${LOCATION}/processors" > "${CREATE_OUT}"
  RC=$?
  set -e
  if [[ $RC -ne 0 ]]; then
    err "Gagal membuat processor via REST"; cat "${CREATE_OUT}" || true; exit 1
  fi
  PROCESSOR_NAME="$(json_get "${CREATE_OUT}" '.name')"
  if [[ -z "${PROCESSOR_NAME}" ]]; then
    err "Tidak mendapatkan nama processor dari respons."; cat "${CREATE_OUT}" || true; exit 1
  fi
  ok "Processor dibuat: ${PROCESSOR_NAME}"
else
  ok "Processor sudah ada: ${PROCESSOR_NAME}"
fi

# Ambil PROCESSOR_ID dari resource name: projects/..../processors/XXXXX
PROCESSOR_ID="${PROCESSOR_NAME##*/}"
ok "PROCESSOR_ID = ${PROCESSOR_ID}"

# =========================
# Siapkan sample data & bucket
# =========================
WORKDIR="$HOME/docai-ocr-lab"
mkdir -p "${WORKDIR}"; cd "${WORKDIR}"

step "Cek / buat bucket gs://${PROJECT_ID}"
if ! gcloud storage buckets list --format='value(name)' | grep -q "^${PROJECT_ID}$"; then
  # Lokasi bucket diselaraskan dengan LOCATION (us/eu -> region multi)
  BUCKET_LOC=$([[ "${LOCATION}" == "eu" ]] && echo "EU" || echo "US")
  gcloud storage buckets create "gs://${PROJECT_ID}" --location="${BUCKET_LOC}"
  ok "Bucket dibuat: gs://${PROJECT_ID}"
else
  ok "Bucket sudah ada: gs://${PROJECT_ID}"
fi

step "Unduh sample PDF"
gcloud storage cp gs://cloud-samples-data/documentai/codelabs/ocr/Winnie_the_Pooh_3_Pages.pdf .
gcloud storage cp gs://cloud-samples-data/documentai/codelabs/ocr/Winnie_the_Pooh.pdf .

# Upload untuk batch
step "Upload novel penuh ke bucket kamu"
gcloud storage cp Winnie_the_Pooh.pdf "gs://${PROJECT_ID}/"

# =========================
# Buat & jalankan ONLINE (synchronous) processing
# =========================
step "Tulis online_processing.py"
cat > online_processing.py <<PY
from google.api_core.client_options import ClientOptions
from google.cloud import documentai_v1 as documentai
import os, sys

PROJECT_ID = os.environ.get("GOOGLE_CLOUD_PROJECT")
LOCATION = "${LOCATION}"
PROCESSOR_ID = "${PROCESSOR_ID}"
FILE_PATH = "Winnie_the_Pooh_3_Pages.pdf"
MIME_TYPE = "application/pdf"

if not PROJECT_ID:
    print("GOOGLE_CLOUD_PROJECT tidak ter-set.", file=sys.stderr); sys.exit(1)

docai_client = documentai.DocumentProcessorServiceClient(
    client_options=ClientOptions(api_endpoint=f"{LOCATION}-documentai.googleapis.com")
)

resource_name = docai_client.processor_path(PROJECT_ID, LOCATION, PROCESSOR_ID)

with open(FILE_PATH, "rb") as f:
    image_content = f.read()

raw_document = documentai.RawDocument(content=image_content, mime_type=MIME_TYPE)
request = documentai.ProcessRequest(name=resource_name, raw_document=raw_document)
result = docai_client.process_document(request=request)
document_object = result.document

print("Document processing complete.")
print("=== First 500 chars ===")
print((document_object.text or "")[:500])
PY

step "Jalankan ONLINE processing"
python3 online_processing.py
ok "ONLINE processing selesai"

# =========================
# Buat & jalankan BATCH (asynchronous) untuk 1 file
# =========================
step "Tulis batch_processing.py"
cat > batch_processing.py <<PY
import re
from typing import List
from google.api_core.client_options import ClientOptions
from google.cloud import documentai_v1 as documentai
from google.cloud import storage
import os

PROJECT_ID = os.environ.get("GOOGLE_CLOUD_PROJECT")
LOCATION = "${LOCATION}"
PROCESSOR_ID = "${PROCESSOR_ID}"

GCS_INPUT_URI = f"gs://{PROJECT_ID}/Winnie_the_Pooh.pdf"
GCS_OUTPUT_URI = f"gs://{PROJECT_ID}/docai-output"
INPUT_MIME_TYPE = "application/pdf"

docai_client = documentai.DocumentProcessorServiceClient(
    client_options=ClientOptions(api_endpoint=f"{LOCATION}-documentai.googleapis.com")
)

resource_name = docai_client.processor_path(PROJECT_ID, LOCATION, PROCESSOR_ID)

input_document = documentai.GcsDocument(gcs_uri=GCS_INPUT_URI, mime_type=INPUT_MIME_TYPE)
input_config = documentai.BatchDocumentsInputConfig(
    gcs_documents=documentai.GcsDocuments(documents=[input_document])
)

gcs_output_config = documentai.DocumentOutputConfig.GcsOutputConfig(gcs_uri=GCS_OUTPUT_URI)
output_config = documentai.DocumentOutputConfig(gcs_output_config=gcs_output_config)

request = documentai.BatchProcessRequest(
    name=resource_name,
    input_documents=input_config,
    document_output_config=output_config,
)

operation = docai_client.batch_process_docume_
