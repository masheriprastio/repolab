#!/usr/bin/env bash
set -Eeuo pipefail

# ========= helper =========
log() { printf "\n\033[1;32m[OK]\033[0m %s\n" "$*"; }
step() { printf "\n\033[1;34m[STEP]\033[0m %s\n" "$*"; }
err() { printf "\n\033[1;31m[ERR]\033[0m %s\n" "$*"; }

need_cmd() { command -v "$1" >/dev/null 2>&1 || { err "Command '$1' tidak ditemukan. Pastikan tersedia di Cloud Shell."; exit 1; }; }

# ========= precheck =========
need_cmd node
need_cmd npm
need_cmd python3
need_cmd gsutil || true   # opsional; ada fallback jika bucket tidak bisa diakses
need_cmd base64

# ========= setup project =========
PROJECT_DIR="$HOME/webpack-lab"
step "Menyiapkan folder proyek di $PROJECT_DIR"
rm -rf "$PROJECT_DIR"
mkdir -p "$PROJECT_DIR/src/assets" "$PROJECT_DIR/dist"
cd "$PROJECT_DIR"

# ========= package.json =========
step "Membuat package.json + scripts (build & serve)"
cat > package.json <<'JSON'
{
  "name": "webpack-lab",
  "version": "1.0.0",
  "private": true,
  "license": "UNLICENSED",
  "scripts": {
    "build": "webpack",
    "serve": "python3 -m http.server 8080 --directory dist"
  },
  "devDependencies": {}
}
JSON
log "package.json dibuat"

# ========= file sumber (HTML template, JS, CSS) =========
step "Membuat HTML template (src/template.html)"
cat > src/template.html <<'HTML'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0"/>
  <title>Webpack Lab</title>
</head>
<body>
  <div class="main-content">
    <img id="imgBrand" alt="Brand Image"/>
    <header>
      <h3>Hectares to Acres</h3>
    </header>
    <form>
      <input placeholder="Hectares" type="number" maxlength="255">
      <button class="btn">Convert</button>
    </form>
    <p id="conversion"></p>
  </div>
  <!-- Karena HtmlWebpackPlugin kita set inject:false, script ini penting -->
  <script src="main.js"></script>
</body>
</html>
HTML
log "src/template.html dibuat"

step "Membuat src/style.css"
cat > src/style.css <<'CSS'
* { box-sizing: border-box; }

body {
  background-color: #ffffff;
  font-family: 'Roboto', sans-serif;
  display: flex; flex-direction: column; align-items: center; justify-content: center;
  height: 100vh; overflow: hidden; margin: 0; padding: 20px;
}

.main-content {
  background-color: #f4f4f4;
  border-radius: 10px;
  box-shadow: 0 10px 20px rgba(0,0,0,0.1), 0 6px 6px rgba(0,0,0,0.1);
  padding: 50px 20px;
  text-align: center;
  max-width: 100%;
  width: 800px;
}

h1 { font-size: 32px; margin-bottom: 16px; }
h3 { margin: 0; opacity: 0.5; letter-spacing: 2px; }

img { width: 100px; margin-bottom: 20px; }

.btn {
  background-color: #2fa8cc; color: #f4f4f4; border: 0; border-radius: 10px;
  box-shadow: 0 5px 15px rgba(0,0,0,0.1), 0 6px 6px rgba(0,0,0,0.1);
  padding: 14px 40px; font-size: 16px; cursor: pointer;
}
CSS
log "src/style.css dibuat"

step "Membuat src/index.js"
cat > src/index.js <<'JS'
import './style.css';
import measure from './assets/house-design.png';

// Ambil elemen dari DOM
const formControl = document.querySelector('form');
const inputControl = document.querySelector('input');
const outputControl = document.querySelector('#conversion');
const imgBrand = document.getElementById('imgBrand');

// Set image brand
imgBrand.src = measure;

// Clear output saat load
outputControl.textContent = '';

// Handle submit
formControl.addEventListener('submit', (event) => {
  event.preventDefault();

  const val = parseFloat(inputControl.value);
  if (!Number.isNaN(val)) {
    const calcResult = (val * 2.4711).toFixed(2);
    outputControl.textContent = `${val} Hectares is ${calcResult} Acres`;
  } else {
    outputControl.textContent = 'Masukkan angka yang valid.';
  }
});
JS
log "src/index.js dibuat"

# ========= aset gambar =========
step "Mengambil aset gambar (via gsutil dari bucket lab); akan fallback bila tidak tersedia"
if gsutil cp gs://spls/gsp1133/blueprint.png src/assets/house-design.png 2>/dev/null; then
  log "Gambar diunduh dari gs://spls/gsp1133/blueprint.png"
else
  log "Bucket tidak dapat diakses; membuat placeholder PNG 1x1 sebagai fallback"
  base64 -d > src/assets/house-design.png <<'B64'
iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMBAFvE9sQAAAAASUVORK5CYII=
B64
fi

# ========= webpack.config.js =========
step "Membuat webpack.config.js"
cat > webpack.config.js <<'JS'
const path = require('path');
const HtmlWebpackPlugin = require('html-webpack-plugin');

module.exports = {
  mode: 'development',
  entry: { main: path.resolve(__dirname, 'src/index.js') },
  output: {
    path: path.resolve(__dirname, 'dist'),
    filename: '[name].js',
    assetModuleFilename: '[name][ext]'
  },
  module: {
    rules: [
      { test: /\.css$/i, use: ['style-loader', 'css-loader'] },
      {
        test: /\.js$/,
        exclude: /node_modules/,
        use: {
          loader: 'babel-loader',
          options: { presets: ['@babel/preset-env'] }
        }
      },
      { test: /\.(png|svg|jpe?g)$/i, type: 'asset/resource' }
    ]
  },
  plugins: [
    new HtmlWebpackPlugin({
      template: 'src/template.html',
      filename: 'index.html',
      inject: false
    })
  ]
};
JS
log "webpack.config.js dibuat"

# ========= install deps =========
step "Menginstal devDependencies Webpack, Babel, dan loaders"
npm install --save-dev \
  webpack webpack-cli \
  html-webpack-plugin \
  style-loader css-loader \
  @babel/core @babel/preset-env babel-loader

log "Instalasi dependencies selesai"

# ========= build =========
step "Menjalankan build (npm run build)"
npm run build

# Verifikasi artefak
[[ -f "dist/main.js" ]] || { err "dist/main.js tidak ditemukan (build gagal)"; exit 1; }
[[ -f "dist/index.html" ]] || { err "dist/index.html tidak ditemukan (HtmlWebpackPlugin gagal?)"; exit 1; }
log "Artefak build terverifikasi"

# ========= serve =========
step "Menjalankan server static di background pada port 8080"
# Hentikan server lama jika ada
if [[ -f .server_pid ]]; then
  OLD_PID="$(cat .server_pid || true)" || true
  if [[ -n "${OLD_PID:-}" ]] && ps -p "$OLD_PID" >/dev/null 2>&1; then
    kill "$OLD_PID" || true
  fi
fi
nohup python3 -m http.server 8080 --directory dist >/dev/null 2>&1 &
echo $! > .server_pid

log "Server jalan. Gunakan Web Preview (port 8080) di Cloud Shell untuk melihat aplikasi."
log "Untuk menghentikan server: kill \$(cat .server_pid)"
