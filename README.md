# Minecraft Bedrock Server

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
| Paket | `curl`, `wget`, `unzip`, `screen` |
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

Gunakan `screen` agar server tetap berjalan saat sesi terminal ditutup.

**a. Buat sesi screen baru dan jalankan server:**

```bash
screen -dmS mc-server bash -c 'cd /opt/bedrock-server && LD_LIBRARY_PATH=. ./bedrock_server | tee -a /var/log/bedrock-server.log'
```

**b. Lihat konsol server secara langsung (re-attach):**

```bash
screen -r mc-server
```

**c. Keluar dari konsol tanpa menghentikan server:**

Tekan `Ctrl+A`, lalu `D` (Detach).

---

## Manajemen Server

### Perintah Screen

| Perintah | Fungsi |
|---|---|
| `screen -r mc-server` | Masuk ke konsol server |
| `screen -ls` | Lihat semua sesi screen aktif |
| `Ctrl+A, D` | Keluar dari konsol (server tetap berjalan) |

### Systemd Service

Jika menggunakan installer otomatis, server terdaftar sebagai systemd service dan akan **auto-start saat boot**.

```bash
# Menjalankan server
sudo systemctl start bedrock-server

# Menghentikan server
sudo systemctl stop bedrock-server

# Melihat status
sudo systemctl status bedrock-server

# Melihat log real-time
sudo journalctl -u bedrock-server -f
```

---

## Pembaruan Otomatis

Repositori ini menyertakan skrip `update_bedrock.sh` yang menangani seluruh proses pembaruan secara otomatis.

### Cara Penggunaan

```bash
sudo bedrock-update
```

atau secara eksplisit:

```bash
sudo /opt/bedrock-server/update_bedrock.sh
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

1. **Deteksi versi** — Membandingkan versi terpasang dengan versi terbaru dari situs resmi Minecraft menggunakan scraping dengan header User-Agent yang sesuai.
2. **Penghentian aman** — Mengirim perintah `stop` ke sesi screen aktif dan menunggu server menyimpan data dunia sebelum dilanjutkan.
3. **Backup konfigurasi** — Menyalin `server.properties`, `allowlist.json`, dan `permissions.json` ke direktori backup bertimestamp (`/opt/bedrock-server-backup/YYYYMMDD_HHMMSS/`).
4. **Unduh dan ekstrak** — Mengunduh binary baru dengan retry otomatis, lalu mengekstrak dengan mode overwrite (`unzip -o`).
5. **Pemulihan konfigurasi** — Mengembalikan file konfigurasi dari backup agar pengaturan tidak hilang.
6. **Jalankan ulang** — Memulai kembali server di sesi screen dan memverifikasi bahwa proses berjalan dengan sukses.

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

**Skrip update gagal mendapatkan URL unduhan**

Situs Minecraft.net terkadang memperbarui struktur halaman. Coba unduh manual dari [minecraft.net/en-us/download/server/bedrock](https://www.minecraft.net/en-us/download/server/bedrock) dan tempatkan file `.zip` di `/opt/bedrock-server/`, kemudian jalankan skrip dengan `--force`.

**Server crash saat startup**

Periksa log server:
```bash
tail -n 100 /var/log/bedrock-server.log
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

---

## Lisensi

Konfigurasi dan skrip dalam repositori ini bebas digunakan dan dimodifikasi. Binary Minecraft Bedrock Server adalah milik Microsoft/Mojang dan tunduk pada [Minecraft End User License Agreement](https://www.minecraft.net/en-us/eula).
