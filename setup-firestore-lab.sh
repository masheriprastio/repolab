#!/usr/bin/env bash
set -Eeuo pipefail

# =========================
# Helpers
# =========================
step() { printf "\n\033[1;34m[STEP]\033[0m %s\n" "$*"; }
ok()   { printf "\033[1;32m[OK]\033[0m %s\n" "$*\n"; }
err()  { printf "\033[1;31m[ERR]\033[0m %s\n" "$*\n" >&2; }

need_cmd() { command -v "$1" >/dev/null 2>&1 || { err "Command '$1' tidak ditemukan."; exit 1; }; }

# =========================
# Precheck tools
# =========================
step "Cek dependencies (node, npm, python3, gcloud)"
need_cmd node
need_cmd npm
need_cmd python3
need_cmd gcloud
ok "Dependencies tersedia"

# Install firebase-tools bila belum ada
if ! command -v firebase >/dev/null 2>&1; then
  step "Menginstal Firebase CLI (firebase-tools)"
  npm i -g firebase-tools
  ok "Firebase CLI terinstal"
fi

# Pastikan login Firebase (akan membuka flow --no-localhost bila belum login)
if ! firebase login:list >/dev/null 2>&1; then
  step "Login ke Firebase CLI (ikuti URL yang muncul, paste code ke Cloud Shell)"
  firebase login --no-localhost
  ok "Login Firebase berhasil"
else
  ok "Firebase CLI sudah login"
fi

# =========================
# Input Project & App Config
# =========================
PROJECT_ID="${PROJECT_ID:-}"
if [[ -z "${PROJECT_ID}" ]]; then
  read -rp "Masukkan GCP PROJECT_ID: " PROJECT_ID
fi
if [[ -z "${PROJECT_ID}" ]]; then err "PROJECT_ID wajib diisi."; exit 1; fi

# Set project aktif di gcloud
step "Set gcloud project => ${PROJECT_ID}"
gcloud config set project "${PROJECT_ID}" >/dev/null
ok "gcloud project diset"

# Minta Firebase Web App config (nilai dari Console -> Project settings -> Your apps)
# Wajib: apiKey, authDomain, projectId, appId. Lainnya opsional.
read -rp "Firebase apiKey: " FB_API_KEY
read -rp "Firebase authDomain (contoh: ${PROJECT_ID}.firebaseapp.com): " FB_AUTH_DOMAIN
read -rp "Firebase projectId [${PROJECT_ID}]: " FB_PROJECT_ID
FB_PROJECT_ID="${FB_PROJECT_ID:-$PROJECT_ID}"
read -rp "Firebase storageBucket (contoh: ${PROJECT_ID}.appspot.com) [opsional]: " FB_STORAGE_BUCKET
read -rp "Firebase messagingSenderId [opsional]: " FB_MSG_SENDER
read -rp "Firebase appId: " FB_APP_ID
read -rp "Firebase measurementId [opsional]: " FB_MEASUREMENT_ID

if [[ -z "${FB_API_KEY}" || -z "${FB_AUTH_DOMAIN}" || -z "${FB_PROJECT_ID}" || -z "${FB_APP_ID}" ]]; then
  err "apiKey, authDomain, projectId, dan appId wajib diisi."
  exit 1
fi

# =========================
# Siapkan struktur proyek
# =========================
ROOT_DIR="$HOME/firebase-project"
step "Membuat folder proyek di ${ROOT_DIR}"
rm -rf "${ROOT_DIR}"
mkdir -p "${ROOT_DIR}/src"
cd "${ROOT_DIR}"

# .firebaserc untuk mengikat project default
cat > .firebaserc <<JSON
{
  "projects": {
    "default": "${PROJECT_ID}"
  }
}
JSON

# firebase.json + rules + indexes (Task 1)
step "Membuat firebase.json, firestore.rules, firestore.indexes.json"
cat > firebase.json <<'JSON'
{
  "firestore": {
    "rules": "firestore.rules",
    "indexes": "firestore.indexes.json"
  }
}
JSON

cat > firestore.rules <<'RULES'
rules_version = '2';
service cloud.firestore {
  match /databases/{database}/documents {
    match /{document=**} {
      // Development mode (lihat dokumen lab)
      allow read, write: if true;
    }
  }
}
RULES

cat > firestore.indexes.json <<'JSON'
{
  "indexes": [],
  "fieldOverrides": []
}
JSON
ok "Konfigurasi Firestore dibuat"

# Deploy rules (mungkin muncul prompt AUTHORIZE di Cloud Shell)
step "Deploy Firestore rules ke project ${PROJECT_ID}"
firebase deploy --only firestore:rules --project "${PROJECT_ID}"
ok "Rules ter-deploy"

# =========================
# Konfigurasi Web + Firebase SDK (Task 2 & 3)
# =========================
step "Membuat package.json dan menginstal dependencies"
# Buat package.json sesuai guideline lab + script build (Task 4)
cat > package.json <<JSON
{
  "name": "firebase-project",
  "version": "1.0.0",
  "description": "",
  "private": "true",
  "scripts": {
    "build": "webpack",
    "serve": "python3 -m http.server 8080 --directory dist"
  },
  "keywords": [],
  "author": "",
  "license": "ISC",
  "dependencies": {
    "firebase": "^10.12.4"
  },
  "devDependencies": {
    "html-webpack-plugin": "^5.6.0",
    "webpack": "^5.91.0",
    "webpack-cli": "^5.1.4"
  }
}
JSON

npm install

# Buat src/index.html (mengikuti struktur lab)
step "Membuat src/index.html"
cat > src/index.html <<'HTML'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <meta http-equiv="X-UA-Compatible" content="IE=edge" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <title>Getting Started with Firebase Cloud Firestore</title>
  <script src="https://cdn.tailwindcss.com"></script>
</head>
<body class="bg-gray-100 flex flex-col items-center justify-center min-h-screen p-4">
  <div class="bg-white p-8 rounded-lg shadow-md max-w-md w-full">
    <h1 class="text-3xl font-bold text-gray-800 mb-4 text-center">Getting started with Firebase Cloud Firestore</h1>
    <p class="text-gray-600 mb-6 text-center">Check the JavaScript console for logs.</p>
    <p id="dbTitle" class="text-lg font-semibold text-blue-600 mb-2"></p>
    <p id="dbDescription" class="text-gray-700"></p>
  </div>
  <script src="main.js"></script>
</body>
</html>
HTML

# Buat src/index.js: init app, tulis lalu baca dokumen (Task 5 & 6)
step "Membuat src/index.js"
cat > src/index.js <<JS
import { initializeApp } from 'firebase/app'
import { getFirestore, doc, setDoc, getDoc } from 'firebase/firestore'

const titleControl = document.querySelector('#dbTitle')
const descriptionControl = document.querySelector('#dbDescription')
titleControl.textContent = ''
descriptionControl.textContent = ''

// Firebase Web App config (diisi dari input shell)
const firebaseConfig = {
  apiKey: "${FB_API_KEY}",
  authDomain: "${FB_AUTH_DOMAIN}",
  projectId: "${FB_PROJECT_ID}",
  storageBucket: "${FB_STORAGE_BUCKET}",
  messagingSenderId: "${FB_MSG_SENDER}",
  appId: "${FB_APP_ID}",
  measurementId: "${FB_MEASUREMENT_ID}"
};

// Init Firebase & Firestore
const firebaseApp = initializeApp(firebaseConfig)
const firestore = getFirestore()

// Ref dokumen contoh
const firestoreIntroDb = doc(firestore, 'firestoreDemo/lab-demo-0001')

// Tulis ke Firestore (Task 5)
async function writeFirestoreDemo() {
  const docData = {
    title: 'Firebase Fundamentals Demo',
    description: 'Getting started with Cloud Firestore'
  }
  await setDoc(firestoreIntroDb, docData)
  console.log('Write done')
}

// Baca dari Firestore (Task 6)
async function readASingleDocument() {
  const mySnapshot = await getDoc(firestoreIntroDb)
  if (mySnapshot.exists()) {
    const docData = mySnapshot.data()
    console.log('Data:', JSON.stringify(docData))
    titleControl.textContent = "Title: " + (docData.title ?? '')
    descriptionControl.textContent = "Description: " + (docData.description ?? '')
  } else {
    console.log('Document not found. Pastikan writeFirestoreDemo() sudah dijalankan minimal sekali.')
  }
}

// Jalankan tulis lalu baca
(async () => {
  await writeFirestoreDemo()
  await readASingleDocument()
})()

console.log('Hello, Firestore!')
JS

# Webpack config (Task 4) — gunakan path yang valid (tanpa leading slash)
step "Membuat webpack.config.js"
cat > webpack.config.js <<'JS'
const path = require('path');
const HtmlWebpackPlugin = require('html-webpack-plugin');

module.exports = {
  mode: 'development',
  devtool: 'eval-source-map',
  entry: path.resolve(__dirname, 'src/index.js'),
  output: {
    path: path.resolve(__dirname, 'dist'),
    filename: '[name].js',
    assetModuleFilename: '[name][ext]',
    clean: true
  },
  plugins: [
    new HtmlWebpackPlugin({
      template: 'src/index.html',
      filename: 'index.html',
      inject: false
    })
  ]
}
JS

# =========================
# Build & Serve
# =========================
step "Build aplikasi (webpack)"
npm run build

# Verifikasi hasil build
[[ -f "dist/index.html" ]] || { err "dist/index.html tidak ditemukan"; exit 1; }
[[ -f "dist/main.js" ]]   || { err "dist/main.js tidak ditemukan"; exit 1; }
ok "Artefak build OK"

# Jalankan static server di background pada port 8080
step "Menjalankan server statis di port 8080"
if [[ -f .server_pid ]]; then
  OLD_PID="$(cat .server_pid || true)" || true
  if [[ -n "${OLD_PID:-}" ]] && ps -p "$OLD_PID" >/dev/null 2>&1; then
    kill "$OLD_PID" || true
  fi
fi
nohup python3 -m http.server 8080 --directory dist >/dev/null 2>&1 &
echo $! > .server_pid
ok "Server jalan. Gunakan Web Preview (port 8080) di Cloud Shell untuk melihat aplikasi."

cat <<'TIP'

==== Ringkasan ====
- Rules Firestore ter-deploy ke project Anda.
- App web dibundle dengan webpack -> dist/
- Server lokal port 8080 sudah berjalan.
- App menulis dokumen 'firestoreDemo/lab-demo-0001' lalu membacanya dan menampilkan Title/Description.

Tips:
- Hentikan server: kill $(cat .server_pid)
- Lihat data di Console: Firestore -> Collections -> firestoreDemo -> lab-demo-0001
===================
TIP
