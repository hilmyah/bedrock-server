# Minecraft Bedrock Server Setup

Repositori ini berisi konfigurasi, skrip manajemen, dan panduan lengkap untuk menjalankan Minecraft Bedrock Server di Debian/Ubuntu menggunakan [Playit.gg](https://playit.gg) sebagai tunnel publik tanpa memerlukan IP publik atau konfigurasi port forwarding.

---

## Daftar Isi

- [Prasyarat](#prasyarat)
- [Instalasi Cepat](#instalasi-cepat)
- [Instalasi Manual](#instalasi-manual)
  - [1. Instalasi Server](#1-instalasi-server)
  - [2. Konfigurasi Playit.gg](#2-konfigurasi-playitgg)
  - [3. Menjalankan Server](#3-menjalankan-server)
- [Manajemen Server](#manajemen-server)
  - [Perintah Screen](#perintah-screen)
  - [Systemd Service](#systemd-service)
- [Pembaruan Otomatis](#pembaruan-otomatis)
- [Struktur Repositori](#struktur-repositori)
- [Pemecahan Masalah](#pemecahan-masalah)

---

## Prasyarat

| Komponen | Keterangan |
|---|---|
| Sistem Operasi | Debian 11+ / Ubuntu 20.04+ |
| Akses | `root` atau `sudo` |
| Paket | `curl`, `wget`, `unzip`, `screen`, `systemctl` |
| Koneksi | Internet aktif saat instalasi dan update |

Instal semua dependensi sekaligus:

```bash
sudo apt update && sudo apt install -y curl wget unzip screen
```

---

## Instalasi Cepat

Instalasi lengkap (server + skrip update) dapat dilakukan dengan **satu perintah**:

```bash
curl -fsSL https://raw.githubusercontent.com/hilmyah/bedrock-server/main/install.sh | sudo bash
```

Untuk instalasi sekaligus dengan Playit.gg:

```bash
curl -fsSL https://raw.githubusercontent.com/hilmyah/bedrock-server/main/install.sh | sudo bash -s -- --with-playit
```

### Opsi Installer

| Opsi | Keterangan |
|---|---|
| `--with-playit` | Instal dan konfigurasi Playit.gg secara otomatis |
| `--port=PORT` | Tentukan port UDP server (default: `19132`) |
| `--dir=PATH` | Tentukan direktori instalasi (default: `/opt/bedrock-server`) |

---

## Instalasi Manual

### 1. Instalasi Server

**a. Buat direktori server:**

```bash
sudo mkdir -p /opt/bedrock-server
cd /opt/bedrock-server
```

**b. Unduh binary terbaru dari situs resmi Minecraft:**

Kunjungi [minecraft.net/en-us/download/server/bedrock](https://www.minecraft.net/en-us/download/server/bedrock), salin URL unduhan untuk Linux, lalu jalankan:

```bash
wget -O bedrock-server-latest.zip "https://[URL_UNDUHAN_LINUX]"
```

Atau gunakan perintah berikut untuk mengambil URL secara otomatis menggunakan API resmi Minecraft:

```bash
LATEST_URL=$(curl -sL https://net-secondary.web.minecraft-services.net/api/v1.0/download/links \
  | grep -Eo 'https://[^"]+bin-linux/bedrock-server-[0-9.]+\.zip' \
  | head -n 1)

wget "$LATEST_URL"
```

**c. Ekstrak dan siapkan binary:**

```bash
unzip bedrock-server-*.zip
chmod +x bedrock_server
```

**d. Jalankan server pertama kali** untuk membuat file konfigurasi:

```bash
LD_LIBRARY_PATH=. ./bedrock_server
```

Tunggu hingga muncul pesan `Server started.`, lalu hentikan dengan menekan `Ctrl+C`. File seperti `server.properties`, `allowlist.json`, dan `permissions.json` akan terbuat otomatis.

---

### 2. Konfigurasi Playit.gg

Playit.gg menyediakan alamat publik permanen tanpa memerlukan IP statis atau konfigurasi router.

**a. Tambahkan repositori Playit.gg:**

```bash
curl -SsL https://playit-cloud.github.io/ppa/key.gpg \
  | gpg --dearmor \
  | sudo tee /etc/apt/trusted.gpg.d/playit.gpg >/dev/null

echo "deb [signed-by=/etc/apt/trusted.gpg.d/playit.gpg] https://playit-cloud.github.io/ppa/data ./" \
  | sudo tee /etc/apt/sources.list.d/playit-cloud.list
```

**b. Instal Playit:**

```bash
sudo apt update && sudo apt install -y playit
```

**c. Dapatkan link klaim:**

```bash
playit
```

Salin link yang muncul di terminal, buka di browser, login ke akun Playit.gg, dan tambahkan tunnel baru dengan konfigurasi:

- **Tipe:** Minecraft Bedrock
- **Protokol:** UDP
- **Port Lokal:** `19132`

Playit.gg akan berjalan sebagai background service secara otomatis setelah konfigurasi selesai.

---

### 3. Menjalankan Server

Server dikelola oleh **systemd** sebagai service, dengan `screen` digunakan sebagai konsol interaktif. Konfigurasi ini memungkinkan server otomatis berjalan saat boot dan dapat dimonitor secara real-time.

**a. Buat file konfigurasi systemd service:**

```bash
cat << 'EOF' > /etc/systemd/system/bedrock.service
[Unit]
Description=Minecraft Bedrock Server
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/bedrock-server
ExecStart=/usr/bin/screen -DmS mc-server bash -c 'set -o pipefail; LD_LIBRARY_PATH=. ./bedrock_server | tee -a /var/log/bedrock-server.log'
ExecStop=/usr/bin/screen -S mc-server -p 0 -X stuff "stop\r"
TimeoutStopSec=30
Restart=on-failure
RestartSec=10s

[Install]
WantedBy=multi-user.target
EOF
```

> **Catatan teknis:** `Type=simple` dengan argumen `screen -DmS` (bukan `-dmS`) memaksa screen berjalan di foreground sehingga systemd dapat melacak PID-nya dengan akurasi penuh. `set -o pipefail` memastikan crash pada binary server memicu `Restart=on-failure` dengan benar, tidak ditutupi oleh perintah `tee`.

**b. Aktifkan dan jalankan service:**

```bash
systemctl daemon-reload
systemctl enable bedrock
systemctl start bedrock
```

---

## Manajemen Server

### Perintah Screen

Walaupun server dikelola oleh systemd, konsol interaktifnya tetap dapat diakses melalui `screen`.

| Perintah | Fungsi |
|---|---|
| `screen -r mc-server` | Masuk ke konsol server |
| `screen -ls` | Lihat semua sesi screen aktif |
| `Ctrl+A, D` | Keluar dari konsol (server tetap berjalan) |

### Systemd Service

Server terdaftar sebagai systemd service dan akan **auto-start saat boot**.

```bash
# Menjalankan server
sudo systemctl start bedrock

# Menghentikan server (graceful shutdown via perintah stop ke konsol)
sudo systemctl stop bedrock

# Melihat status
sudo systemctl status bedrock

# Melihat log real-time
sudo journalctl -u bedrock -f

# Melihat log output server
tail -f /var/log/bedrock-server.log
```

---

## Pembaruan Otomatis

Repositori ini menyertakan skrip `update_bedrock.sh` yang menangani seluruh proses pembaruan secara otomatis, termasuk integrasi penuh dengan systemd untuk shutdown dan startup yang aman.

### Cara Penggunaan

```bash
sudo bedrock-update
```

atau secara eksplisit:

```bash
sudo /opt/bedrock-server/update_bedrock.sh
```

### Pemasangan Alias Command (Khusus Instalasi Manual)

Jika Anda tidak menggunakan skrip instalasi otomatis (`install.sh`) dan mengunduh skrip pembaruan secara manual, buat tautan simbolik (symlink) agar perintah dapat dieksekusi secara global:

```bash
sudo chmod +x /opt/bedrock-server/update_bedrock.sh
sudo ln -sf /opt/bedrock-server/update_bedrock.sh /usr/local/bin/bedrock-update
```

### Opsi Update

| Opsi | Keterangan |
|---|---|
| *(tanpa opsi)* | Cek dan update jika ada versi baru |
| `--force` | Paksa instalasi ulang meskipun versi sama |
| `--no-restart` | Jangan jalankan ulang server setelah update |
| `--backup-worlds` | Backup direktori `worlds` sebelum update |

Contoh penggunaan dengan opsi:

```bash
sudo bedrock-update --backup-worlds --force
```

### Mekanisme Kerja Skrip

1. **Deteksi versi** — Membandingkan versi terpasang dengan versi terbaru dari situs resmi Minecraft, dengan sistem fallback 3 lapis.
2. **Penghentian aman** — Mendelegasikan shutdown ke `systemctl stop bedrock`, yang secara otomatis mengirim perintah `stop` ke konsol dan menunggu server menyimpan data dunia sebelum dilanjutkan.
3. **Backup konfigurasi** — Menyalin `server.properties`, `allowlist.json`, dan `permissions.json` ke direktori backup bertimestamp (`/opt/bedrock-server-backup/YYYYMMDD_HHMMSS/`).
4. **Unduh dan ekstrak** — Mengunduh binary baru dengan retry otomatis, lalu mengekstrak dengan mode overwrite (`unzip -o`).
5. **Pemulihan konfigurasi** — Mengembalikan file konfigurasi dari backup agar pengaturan tidak hilang.
6. **Jalankan ulang** — Memulai kembali server via `systemctl start bedrock` dan memverifikasi bahwa service aktif.

### Log

| File | Isi |
|---|---|
| `/var/log/bedrock-update.log` | Riwayat setiap proses pembaruan |
| `/var/log/bedrock-server.log` | Output konsol server secara berkelanjutan |

---

## Struktur Repositori

```
bedrock-server/
├── install.sh              # Installer satu-baris dari GitHub
├── update_bedrock.sh       # Skrip pembaruan otomatis
├── server.properties       # Konfigurasi utama server
├── allowlist.json          # Daftar pemain yang diizinkan (whitelist)
├── permissions.json        # Pengaturan izin pemain (operator, dll.)
├── packetlimitconfig.json  # Batas paket jaringan
├── profanity_filter.wlist  # Daftar kata yang difilter
├── behavior_packs/         # Add-on behavior packs
├── resource_packs/         # Add-on resource packs
├── config/
│   └── default/            # Konfigurasi eksperimen bawaan
├── data/                   # Data server statis
└── definitions/            # Definisi entitas dan biome
```

> **Catatan:** Direktori `worlds/`, `worlds_backup/`, file binary `bedrock_server`, arsip `.zip`, dan direktori development packs dikecualikan dari version control melalui `.gitignore`.

---

## Pemecahan Masalah

**Server tidak dapat ditemukan oleh pemain**

Pastikan tunnel Playit.gg aktif:
```bash
systemctl status playit
```
Pastikan alamat tunnel yang diberikan Playit.gg sudah dibagikan dengan format `[alamat]:19132`.

**Skrip update berhenti diam-diam setelah `==> Memeriksa Versi`**

Disebabkan oleh dua masalah pada interaksi `set -euo pipefail`:

- `ls bedrock-server-*.zip` mengembalikan exit code 2 saat tidak ada file `.zip` (contoh: setelah instalasi pertama). Aturan `set -e` mendeteksinya sebagai error fatal dan menghentikan skrip tanpa pesan.
- Teks `[INFO]` dari fungsi `log` ikut tertangkap ke dalam variabel `LATEST_URL` saat fungsi `fetch_latest_url` dipanggil melalui `$(...)`, sehingga URL menjadi rusak.

Kedua bug ini sudah diperbaiki pada versi terkini: semua `echo` dalam fungsi `log` diarahkan ke `stderr` dengan `>&2`, dan `ls` dibungkus dalam subshell `(...)` dengan `|| true`. Pastikan Anda menggunakan versi terbaru dari repositori ini.

**Skrip update gagal mendapatkan URL unduhan / Terkena blokir Anti-Bot**

Jika *web scraping* langsung ke situs Minecraft.net diblokir oleh layanan perlindungan (seperti Cloudflare/Akamai) pada IP VPS Anda, skrip telah didesain dengan sistem *fallback* 3 lapis:
1. Mengekstrak dari *Endpoint* API JSON internal Minecraft.
2. Mengekstrak dari repositori tracker pihak ketiga di GitHub (`raw.githubusercontent.com`).
3. Menyamar sebagai *user-agent* browser valid.

Jika ketiga metode ini masih gagal, unduh zip secara manual ke dalam `/opt/bedrock-server/` lalu jalankan `sudo bedrock-update --force`.

**Server crash saat startup**

Periksa log server:
```bash
tail -n 100 /var/log/bedrock-server.log
```
Atau periksa melalui systemd:
```bash
journalctl -u bedrock -n 100
```
Penyebab umum: library sistem tidak kompatibel (gunakan Debian 11+ atau Ubuntu 20.04+).

**Tidak bisa masuk ke konsol screen**

```bash
screen -ls          # Cek apakah sesi aktif
screen -r mc-server # Masuk ke sesi
```
Jika sesi tampak "Attached", paksa detach dengan:
```bash
screen -d mc-server && screen -r mc-server
```

**Server terdeteksi mati padahal sebenarnya berjalan (false negative)**

Pastikan Anda menggunakan konfigurasi systemd dengan `Type=simple` dan `screen -DmS` (huruf besar `D`). Konfigurasi lama dengan `Type=forking` dan `screen -dmS` menyebabkan systemd kehilangan jejak PID sehingga melaporkan status yang tidak akurat.

---

## Lisensi

Konfigurasi dan skrip dalam repositori ini bebas digunakan dan dimodifikasi. Binary Minecraft Bedrock Server adalah milik Microsoft/Mojang dan tunduk pada [Minecraft End User License Agreement](https://www.minecraft.net/en-us/eula).
