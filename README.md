<div align="center">
  <h1>Minecraft Bedrock Server Setup</h1>
  <p>Konfigurasi, skrip manajemen, dan panduan operasional untuk menjalankan Minecraft Bedrock Server di Linux menggunakan Playit.gg sebagai tunnel jaringan publik.</p>
</div>

<p align="center">
  <img src="https://img.shields.io/badge/Platform-Debian%20%7C%20Ubuntu-A81D33?logo=ubuntu&logoColor=white" alt="Platform">
  <img src="https://img.shields.io/badge/Script-Bash-4EAA25?logo=gnu-bash&logoColor=white" alt="Shell">
  <img src="https://img.shields.io/badge/Network-Playit.gg-0052CC" alt="Network">
</p>

---

Repositori ini berisi konfigurasi, skrip manajemen, dan panduan lengkap untuk menjalankan Minecraft Bedrock Server di Debian/Ubuntu menggunakan [Playit.gg](https://playit.gg) sebagai tunnel publik tanpa memerlukan IP publik atau konfigurasi port forwarding.

## Daftar Isi

- [Fitur](#fitur)
- [Konsep dan Arsitektur](#konsep-dan-arsitektur)
- [Struktur Repository](#struktur-repository)
- [Prasyarat](#prasyarat)
- [Instalasi](#instalasi)
- [Manajemen dan Operasional](#manajemen-dan-operasional)
- [Pembaruan](#pembaruan)
- [Troubleshooting](#troubleshooting)
- [Lisensi](#lisensi)

---

## Fitur

| Fitur | Deskripsi |
|---|---|
| Instalasi Satu Perintah | Skrip `install.sh` menangani seluruh proses: unduh binary, konfigurasi systemd service, dan opsional instalasi Playit.gg dalam satu perintah. |
| Playit.gg Tunnel | Menyediakan alamat publik permanen untuk server tanpa memerlukan IP statis atau konfigurasi port forwarding pada router. |
| Systemd Service | Server diregistrasikan sebagai systemd service dengan restart otomatis saat crash (`Restart=on-failure`) dan auto-start saat boot. |
| Konsol Interaktif | Screen session bernama `mc-server` memungkinkan akses konsol server secara interaktif tanpa menghentikan proses. |
| Pembaruan Otomatis | Skrip `update_bedrock.sh` mendeteksi versi terbaru, menghentikan server dengan aman, mem-backup konfigurasi, lalu memperbarui binary secara otomatis dengan sistem fallback 3 lapis. |

---

## Konsep dan Arsitektur

Server berjalan di host Linux dan diekspos ke internet melalui Playit.gg tanpa memerlukan IP publik atau konfigurasi firewall router. Playit.gg bertindak sebagai relay UDP antara pemain dan server lokal.

```text
+--------------------+       UDP       +--------------------+       UDP       +--------------------+
|  Pemain (Publik)   | <-------------> |    Playit.gg       | <-------------> |  Bedrock Server    |
|  Klien Minecraft   |                 |  Relay (Cloud)     |                 |  (Linux Host)      |
+--------------------+                 +--------------------+                 +--------------------+
                                                                                        |
                                                                             +--------------------+
                                                                             |  systemd + screen  |
                                                                             |  (Process Mgmt)    |
                                                                             +--------------------+
```

Server dikelola oleh systemd menggunakan `Type=simple` dengan `screen -DmS` agar systemd dapat melacak PID proses secara akurat. Screen berjalan di foreground dari perspektif systemd sekaligus menyediakan sesi konsol interaktif yang dapat diakses kapan pun.

---

## Struktur Repository

```
bedrock-server/
├── install.sh              Installer satu-perintah: unduh binary, buat systemd service, opsional Playit.gg.
├── update_bedrock.sh       Skrip pembaruan otomatis binary server dengan backup dan fallback URL.
├── server.properties       Konfigurasi utama server (port, max player, level name, dll.).
├── allowlist.json          Daftar pemain yang diizinkan masuk (whitelist).
├── permissions.json        Pengaturan izin pemain (operator, member, visitor).
├── packetlimitconfig.json  Batas paket jaringan per koneksi.
├── profanity_filter.wlist  Daftar kata yang difilter dari chat.
├── behavior_packs/         Add-on behavior packs.
├── resource_packs/         Add-on resource packs.
├── config/
│   └── default/            Konfigurasi eksperimen bawaan server.
├── data/                   Data server statis.
└── definitions/            Definisi entitas dan biome.
```

Direktori `worlds/`, `worlds_backup/`, file binary `bedrock_server`, arsip `.zip`, dan direktori development packs dikecualikan dari version control melalui `.gitignore`.

---

## Prasyarat

| Komponen | Spesifikasi / Versi | Keterangan |
|---|---|---|
| Sistem Operasi | Debian 11+ / Ubuntu 20.04+ | Library sistem yang kompatibel diperlukan untuk binary Bedrock. |
| Akses | `root` atau `sudo` | Diperlukan untuk menulis ke `/opt`, `/etc/systemd`, dan `/var/log`. |
| `curl`, `wget`, `unzip`, `screen` | Versi paket apt terbaru | Dependensi runtime untuk installer, pengunduhan binary, dan manajemen proses. |
| Koneksi internet | Aktif saat instalasi dan update | Diperlukan untuk mengunduh binary Bedrock dan paket Playit.gg. |

Instal seluruh dependensi sekaligus:

```bash
sudo apt update && sudo apt install -y curl wget unzip screen
```

### Port Jaringan

| Port | Protokol | Arah | Deskripsi |
|---|---|---|---|
| `19132` | UDP | Inbound (via Playit.gg) | Port default Minecraft Bedrock. Dapat diubah melalui opsi `--port` pada installer atau langsung di `server.properties`. |

---

## Instalasi

### Instalasi Cepat

```bash
curl -fsSL https://raw.githubusercontent.com/hilmyah/bedrock-server/main/install.sh | sudo bash
```

Untuk instalasi sekaligus dengan Playit.gg:

```bash
curl -fsSL https://raw.githubusercontent.com/hilmyah/bedrock-server/main/install.sh | sudo bash -s -- --with-playit
```

Opsi installer:

| Opsi | Keterangan |
|---|---|
| `--with-playit` | Instal dan konfigurasi Playit.gg secara otomatis. |
| `--port=PORT` | Tentukan port UDP server (default: `19132`). |
| `--dir=PATH` | Tentukan direktori instalasi (default: `/opt/bedrock-server`). |

### Instalasi Manual

#### 1. Instalasi Server

Buat direktori server:

```bash
sudo mkdir -p /opt/bedrock-server
cd /opt/bedrock-server
```

Unduh binary terbaru menggunakan API resmi Minecraft:

```bash
LATEST_URL=$(curl -sL https://net-secondary.web.minecraft-services.net/api/v1.0/download/links \
  | grep -Eo 'https://[^"]+bin-linux/bedrock-server-[0-9.]+\.zip' \
  | head -n 1)

wget "$LATEST_URL"
```

Alternatif: kunjungi [minecraft.net/en-us/download/server/bedrock](https://www.minecraft.net/en-us/download/server/bedrock), salin URL unduhan untuk Linux, lalu jalankan `wget -O bedrock-server-latest.zip "<URL>"`.

Ekstrak dan siapkan binary:

```bash
unzip bedrock-server-*.zip
chmod +x bedrock_server
```

Jalankan server pertama kali untuk membuat file konfigurasi. Tunggu muncul pesan `Server started.`, lalu hentikan dengan `Ctrl+C`:

```bash
LD_LIBRARY_PATH=. ./bedrock_server
```

File `server.properties`, `allowlist.json`, dan `permissions.json` akan terbuat otomatis.

#### 2. Konfigurasi Playit.gg

Tambahkan repositori dan instal Playit:

```bash
curl -SsL https://playit-cloud.github.io/ppa/key.gpg \
  | gpg --dearmor \
  | sudo tee /etc/apt/trusted.gpg.d/playit.gpg >/dev/null

echo "deb [signed-by=/etc/apt/trusted.gpg.d/playit.gpg] https://playit-cloud.github.io/ppa/data ./" \
  | sudo tee /etc/apt/sources.list.d/playit-cloud.list

sudo apt update && sudo apt install -y playit
```

Jalankan Playit untuk mendapatkan link klaim:

```bash
playit
```

Salin link yang muncul di terminal, buka di browser, login ke akun Playit.gg, dan tambahkan tunnel baru dengan konfigurasi:

- **Tipe:** Minecraft Bedrock
- **Protokol:** UDP
- **Port Lokal:** `19132`

Playit.gg akan berjalan sebagai background service secara otomatis setelah konfigurasi selesai.

#### 3. Menjalankan Server

Buat file konfigurasi systemd service:

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

> `Type=simple` dengan `screen -DmS` (huruf besar `D`) memaksa screen berjalan di foreground sehingga systemd dapat melacak PID-nya dengan akurasi penuh. `set -o pipefail` memastikan crash pada binary server memicu `Restart=on-failure` dan tidak ditutupi oleh perintah `tee`.

Aktifkan dan jalankan service:

```bash
systemctl daemon-reload
systemctl enable bedrock
systemctl start bedrock
```

---

## Manajemen dan Operasional

### Perintah Layanan

```bash
sudo systemctl start bedrock
sudo systemctl stop bedrock
sudo systemctl status bedrock
sudo journalctl -u bedrock -f
```

### Konsol Interaktif

| Perintah | Fungsi |
|---|---|
| `screen -r mc-server` | Masuk ke konsol server. |
| `screen -ls` | Lihat semua sesi screen aktif. |
| `Ctrl+A, D` | Keluar dari konsol tanpa menghentikan server. |

### Lokasi Log

| File | Isi |
|---|---|
| `/var/log/bedrock-server.log` | Output konsol server secara berkelanjutan. |
| `/var/log/bedrock-update.log` | Riwayat setiap proses pembaruan. |

---

## Pembaruan

```bash
sudo bedrock-update
```

Atau secara eksplisit:

```bash
sudo /opt/bedrock-server/update_bedrock.sh
```

### Pemasangan Alias (Instalasi Manual)

Jika tidak menggunakan `install.sh`, buat symlink agar perintah dapat dieksekusi secara global:

```bash
sudo chmod +x /opt/bedrock-server/update_bedrock.sh
sudo ln -sf /opt/bedrock-server/update_bedrock.sh /usr/local/bin/bedrock-update
```

### Opsi Update

| Opsi | Keterangan |
|---|---|
| *(tanpa opsi)* | Cek dan update jika ada versi baru. |
| `--force` | Paksa instalasi ulang meskipun versi sama. |
| `--no-restart` | Jangan jalankan ulang server setelah update. |
| `--backup-worlds` | Backup direktori `worlds` sebelum update. |

Contoh penggunaan dengan opsi:

```bash
sudo bedrock-update --backup-worlds --force
```

### Mekanisme Kerja Skrip

1. **Deteksi versi** - Membandingkan versi terpasang dengan versi terbaru dari situs resmi Minecraft, dengan sistem fallback 3 lapis.
2. **Penghentian aman** - Mendelegasikan shutdown ke `systemctl stop bedrock`, yang mengirim perintah `stop` ke konsol dan menunggu server menyimpan data dunia sebelum dilanjutkan.
3. **Backup konfigurasi** - Menyalin `server.properties`, `allowlist.json`, dan `permissions.json` ke direktori backup bertimestamp (`/opt/bedrock-server-backup/YYYYMMDD_HHMMSS/`).
4. **Unduh dan ekstrak** - Mengunduh binary baru dengan retry otomatis, lalu mengekstrak dengan mode overwrite (`unzip -o`).
5. **Pemulihan konfigurasi** - Mengembalikan file konfigurasi dari backup agar pengaturan tidak hilang.
6. **Jalankan ulang** - Memulai kembali server via `systemctl start bedrock` dan memverifikasi bahwa service aktif.

---

## Troubleshooting

**Server tidak dapat ditemukan oleh pemain**

Pastikan tunnel Playit.gg aktif dan alamat tunnel sudah dibagikan ke pemain dengan format `[alamat]:19132`:

```bash
systemctl status playit
```

**Skrip update berhenti diam-diam setelah `==> Memeriksa Versi`**

Disebabkan oleh dua masalah pada interaksi `set -euo pipefail`: `ls bedrock-server-*.zip` mengembalikan exit code 2 saat tidak ada file `.zip` sehingga `set -e` menghentikan skrip tanpa pesan, dan teks `[INFO]` dari fungsi `log` ikut tertangkap ke dalam variabel `LATEST_URL` melalui `$(...)` sehingga URL menjadi rusak. Kedua bug ini sudah diperbaiki pada versi terkini: semua output fungsi `log` diarahkan ke stderr dengan `>&2`, dan `ls` dibungkus dalam subshell dengan `|| true`. Pastikan menggunakan versi terbaru dari repositori ini.

**Skrip update gagal mendapatkan URL unduhan / terkena blokir anti-bot**

Skrip menggunakan sistem fallback 3 lapis: endpoint API JSON internal Minecraft, repositori tracker pihak ketiga di GitHub (`raw.githubusercontent.com`), dan penyamaran sebagai user-agent browser valid. Jika ketiga metode gagal, unduh zip secara manual ke `/opt/bedrock-server/` lalu jalankan:

```bash
sudo bedrock-update --force
```

**Server crash saat startup**

```bash
tail -n 100 /var/log/bedrock-server.log
journalctl -u bedrock -n 100
```

Penyebab umum: library sistem tidak kompatibel. Gunakan Debian 11+ atau Ubuntu 20.04+.

**Tidak bisa masuk ke konsol screen**

Cek sesi aktif terlebih dahulu. Jika sesi tampak `Attached`, paksa detach lalu masuk kembali:

```bash
screen -ls
screen -d mc-server && screen -r mc-server
```

**Server terdeteksi mati padahal sebenarnya berjalan**

Pastikan menggunakan `Type=simple` dan `screen -DmS` (huruf besar `D`) pada konfigurasi systemd. Konfigurasi lama `Type=forking` dengan `screen -dmS` menyebabkan systemd kehilangan jejak PID sehingga melaporkan status yang tidak akurat.

---

## Lisensi

Konfigurasi dan skrip dalam repositori ini bebas digunakan dan dimodifikasi. Binary Minecraft Bedrock Server adalah milik Microsoft/Mojang dan tunduk pada [Minecraft End User License Agreement](https://www.minecraft.net/en-us/eula).
