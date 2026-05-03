# Minecraft Bedrock Server Setup

Repositori ini berisi konfigurasi server Minecraft Bedrock. Data dunia (worlds) dan file binary (executable) diabaikan dari version control.

## Prasyarat
Sistem operasi Debian/Ubuntu. Paket yang dibutuhkan:
- wget
- unzip
- curl
- screen

## 1. Instalasi Bedrock Server dari Awal
1. Buat direktori server: `mkdir -p /opt/bedrock-server && cd /opt/bedrock-server`
2. Unduh versi terbaru dari situs resmi Minecraft: `wget [URL_DOWNLOAD_UBUNTU]`
3. Ekstrak file: `unzip bedrock-server-*.zip`
4. Beri izin eksekusi: `chmod +x bedrock_server`
5. Jalankan server pertama kali untuk meng-generate file konfigurasi: `LD_LIBRARY_PATH=. ./bedrock_server`

## 2. Instalasi dan Konfigurasi Playit.gg
1. Unduh Playit: `curl -SsL https://playit-cloud.github.io/ppa/key.gpg | gpg --dearmor | sudo tee /etc/apt/trusted.gpg.d/playit.gpg >/dev/null`
2. Tambahkan repositori: `echo "deb [signed-by=/etc/apt/trusted.gpg.d/playit.gpg] https://playit-cloud.github.io/ppa/data ./" | sudo tee /etc/apt/sources.list.d/playit-cloud.list`
3. Update dan install: `sudo apt update && sudo apt install playit`
4. Jalankan Playit untuk mendapatkan link klaim: `playit`
5. Buka link yang muncul di terminal pada browser, login, dan tambahkan tunnel "Minecraft Bedrock" (UDP, port lokal 19132).
6. Playit akan berjalan sebagai service di latar belakang.

## 3. Cara Menjalankan Server
Gunakan `screen` agar server tetap berjalan saat terminal ditutup:
1. Buat sesi screen: `screen -S mc-server`
2. Masuk direktori: `cd /opt/bedrock-server`
3. Jalankan: `LD_LIBRARY_PATH=. ./bedrock_server`
4. Detach dari screen: Tekan `Ctrl + A`, lalu `D`.
5. Re-attach ke screen: `screen -r mc-server`

## 4. Cara Update Server
1. Hentikan proses server (`stop` di konsol).
2. Backup direktori `worlds` dan file konfigurasi (`server.properties`, `allowlist.json`, `permissions.json`).
3. Unduh versi zip terbaru.
4. Ekstrak dan timpa file lama: `unzip -o bedrock-server-*.zip`
5. Jika ditanya untuk menimpa `server.properties`, ketik `N` (atau timpa lalu restore dari backup).
6. Setel ulang izin eksekusi: `chmod +x bedrock_server`
7. Jalankan server kembali.
EOF
