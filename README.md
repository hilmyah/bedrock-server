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
- [Manajemen Terpadu (bedrock-manager.sh)](#manajemen-terpadu-bedrock-managersh)
- [Backup dan Restore](#backup-dan-restore)
- [Log Aktivitas Pemain](#log-aktivitas-pemain)
- [Pembaruan](#pembaruan)
- [Troubleshooting](#troubleshooting)
- [Lisensi](#lisensi)

---

## Fitur

| Fitur | Deskripsi |
|---|---|
| Instalasi Satu Perintah | Skrip `install.sh` menangani seluruh proses: unduh binary, pasang `bedrock-manager.sh`, konfigurasi systemd service, rotasi log konsol, player activity logger, dan opsional Playit.gg — semua dalam satu perintah. |
| Playit.gg Tunnel | Menyediakan alamat publik permanen untuk server tanpa memerlukan IP statis atau konfigurasi port forwarding pada router. |
| Systemd Service | Server diregistrasikan sebagai systemd service dengan restart otomatis saat crash (`Restart=on-failure`) dan auto-start saat boot. |
| Manajemen Terpadu | `bedrock-manager.sh` (dipanggil sebagai `bedrock`) menyatukan start/stop/restart/status, konsol, kirim perintah in-game, backup mandiri, restore, dan pembacaan log pemain dalam satu CLI. |
| Backup Independen dari Update | `bedrock backup` dapat dijalankan kapan pun tanpa memicu proses update. Backup worlds memakai mekanisme resmi `save hold`/`save query`/`save resume` agar server tidak perlu berhenti. |
| Log Aktivitas Pemain Permanen | Setiap event join/leave pemain di-append ke `player_activity.log`. Tidak ada rotasi atau penghapusan otomatis berdasarkan waktu — riwayat hanya reset jika file dihapus manual. |
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
                                                                                        |
                                                                             +--------------------+
                                                                             | bedrock-manager.sh |
                                                                             | (start/stop/backup/|
                                                                             |  restore/players)  |
                                                                             +--------------------+
```

Server dikelola oleh systemd menggunakan `Type=simple` dengan `screen -DmS` agar systemd dapat melacak PID proses secara akurat. Screen berjalan di foreground dari perspektif systemd sekaligus menyediakan sesi konsol interaktif yang dapat diakses kapan pun. `bedrock-manager.sh` berada di atas lapisan ini: ia mengirim perintah ke sesi screen yang sama, memanggil `systemctl`, dan membaca/menulis log — tanpa mengubah cara systemd mengelola proses.

---

## Struktur Repository

```
bedrock-server/
├── install.sh              Installer satu-perintah: unduh binary, pasang bedrock-manager.sh,
│                            buat systemd service + logrotate, aktifkan player logger, opsional Playit.gg.
├── bedrock-manager.sh       CLI manajemen terpadu (start/stop/backup/restore/players/dst).
│                            Di-symlink ke /usr/local/bin/bedrock saat instalasi.
├── update_bedrock.sh        Skrip pembaruan otomatis binary server dengan backup dan fallback URL.
│                            Dipanggil langsung atau lewat 'bedrock update'.
├── server.properties        Konfigurasi utama server (port, max player, level name, dll.).
├── allowlist.json           Daftar pemain yang diizinkan masuk (whitelist).
├── permissions.json         Pengaturan izin pemain (operator, member, visitor).
├── packetlimitconfig.json   Batas paket jaringan per koneksi.
├── profanity_filter.wlist   Daftar kata yang difilter dari chat.
├── behavior_packs/          Add-on behavior packs.
├── resource_packs/          Add-on resource packs.
├── config/
│   └── default/             Konfigurasi eksperimen bawaan server.
├── data/                    Data server statis.
└── definitions/             Definisi entitas dan biome.
```

Direktori/file berikut dibuat secara otomatis saat runtime (bukan bagian dari version control, lihat `.gitignore`):

| Path | Dibuat oleh | Keterangan |
|---|---|---|
| `worlds/`, `worlds_backup/` | server / manual | Data dunia. Sangat dinamis, tidak boleh masuk Git. |
| `bedrock_server`, `*.zip` | `install.sh` / `update_bedrock.sh` | Binary dan arsip unduhan. |
| `player-logger.sh` | `bedrock logger install` | Digenerate otomatis dari `bedrock-manager.sh`, jangan diedit manual. |
| `player_activity.log` | `bedrock-player-logger.service` | Riwayat join/leave pemain, permanen (lihat bagian [Log Aktivitas Pemain](#log-aktivitas-pemain)). |
| `${SERVER_DIR}-backup/` | `bedrock backup` | Direktori saudara di luar `SERVER_DIR`, berisi seluruh backup bertimestamp. |

---

## Prasyarat

| Komponen | Spesifikasi / Versi | Keterangan |
|---|---|---|
| Sistem Operasi | Debian 11+ / Ubuntu 20.04+ | Library sistem yang kompatibel diperlukan untuk binary Bedrock. |
| Akses | `root` atau `sudo` | Diperlukan untuk menulis ke `/opt`, `/etc/systemd`, dan `/var/log`. |
| `curl`, `wget`, `unzip`, `screen` | Versi paket apt terbaru | Dependensi runtime untuk installer, pengunduhan binary, dan manajemen proses. |
| `bash` >= 4 | Bawaan Debian/Ubuntu | Diperlukan oleh `bedrock-manager.sh` (regex bawaan bash, associative array pada beberapa fungsi). |
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

Instalasi ini otomatis: memasang binary server, `update_bedrock.sh`, `bedrock-manager.sh` (symlink `bedrock`), systemd service, logrotate untuk log konsol, dan mengaktifkan player activity logger.

Untuk instalasi sekaligus dengan Playit.gg:

```bash
curl -fsSL https://raw.githubusercontent.com/hilmyah/bedrock-server/main/install.sh | sudo bash -s -- --with-playit
```

Opsi installer:

| Opsi | Keterangan |
|---|---|
| `--with-playit` | Instal dan konfigurasi Playit.gg secara otomatis. |
| `--skip-playerlog` | Jangan aktifkan player activity logger otomatis (bisa dipasang belakangan dengan `bedrock logger install`). |
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

Pasang `bedrock-manager.sh` secara manual (jika tidak memakai `install.sh`):

```bash
curl -fsSL https://raw.githubusercontent.com/hilmyah/bedrock-server/main/bedrock-manager.sh \
  -o /opt/bedrock-server/bedrock-manager.sh
chmod +x /opt/bedrock-server/bedrock-manager.sh
sudo /opt/bedrock-server/bedrock-manager.sh self-install
sudo bedrock logger install
```

---

## Manajemen Terpadu (bedrock-manager.sh)

Setelah instalasi, seluruh operasi harian dilakukan lewat perintah `bedrock` (symlink ke `bedrock-manager.sh`). Skrip ini bersifat universal: path server, nama screen, dan nama service TIDAK di-hardcode, melainkan diresolusi berurutan dari environment variable → `/etc/bedrock-manager/manager.conf` → introspeksi `systemctl show` pada unit yang terpasang → nilai default. Ini berarti skrip yang sama bekerja di instalasi manapun yang mengikuti pola `install.sh` di atas, tanpa perlu diedit.

### Kontrol Service

| Perintah | Fungsi |
|---|---|
| `bedrock start` / `stop` / `restart` | Kontrol systemd service `bedrock`. |
| `bedrock status` | Status service, versi terpasang, RAM (RSS) proses `bedrock_server` yang sebenarnya, ukuran `worlds/`, dan ringkasan log pemain. |
| `bedrock console` | Attach ke sesi screen (`Ctrl+A` lalu `D` untuk keluar tanpa menghentikan server). |
| `bedrock send "<perintah>"` | Kirim satu perintah in-game langsung tanpa perlu attach ke konsol, misal `bedrock send "say Server restart 5 menit lagi"`. |
| `bedrock online` | Kirim `list` ke konsol dan baca hasilnya dari log. |
| `bedrock version` | Bandingkan versi terpasang vs versi terbaru di server Mojang, **tanpa** menghentikan atau mengunduh apa pun. |

> **Catatan jujur soal keterbatasan:** Bedrock Dedicated Server tidak memiliki RCON bawaan. `send` dan `online` bekerja dengan menyuntikkan teks ke sesi `screen`, bukan lewat protokol terstruktur. Jika sesi screen tidak ditemukan (server mati atau nama screen tidak cocok), perintah akan gagal dengan pesan eksplisit — bukan output yang dipalsukan.

### Konfigurasi Override (opsional)

Jika direktori/nama service berbeda dari default, isi `/etc/bedrock-manager/manager.conf`:

```bash
SERVER_DIR="/opt/bedrock-server"
SCREEN_NAME="mc-server"
SERVICE_NAME="bedrock"
LOG_FILE="/var/log/bedrock-server.log"
PLAYER_LOG="/opt/bedrock-server/player_activity.log"
BACKUP_DIR="/opt/bedrock-server-backup"
```

Atau lewat environment variable dengan prefiks `BEDROCK_` (mis. `BEDROCK_SERVER_DIR`, `BEDROCK_BACKUP_RETAIN`).

---

## Backup dan Restore

Backup **tidak lagi terikat pada proses update**. Jalankan kapan pun:

```bash
bedrock backup                      # hanya server.properties, allowlist.json, permissions.json
bedrock backup --worlds             # + folder worlds, live snapshot jika server berjalan
bedrock backup --worlds --stop      # + folder worlds, server dihentikan dulu (paling aman)
bedrock backup --worlds --debug     # sama seperti di atas, plus log mentah konsol untuk diagnosis
```

### Mekanisme Live Snapshot (tanpa `--stop`)

Saat server berjalan dan `--stop` tidak diberikan, backup worlds memakai mekanisme resmi Bedrock Dedicated Server:

1. `save hold` — server bersiap, kembali segera (asinkron).
2. `save query` — dipanggil berulang (maks. 24 kali, jeda 5 detik) sampai server membalas `Data saved. Files are now ready to be copied.` beserta daftar `path:panjang_byte`.
3. Setiap file pada daftar tersebut disalin dan **dipotong (truncate)** persis sesuai panjang byte yang dilaporkan — bukan sekadar `cp -r` mentah — sehingga hasilnya tetap konsisten meski server terus menulis data di background.
4. `save resume` — selalu dikirim di akhir, termasuk saat terjadi timeout/error (dijamin lewat `trap`), agar dunia tidak "tertahan".

Jika server tidak membalas dalam batas waktu, proses **dibatalkan dengan pesan eksplisit** (bukan backup yang dipalsukan sebagai berhasil). Untuk kepastian 100%, gunakan `--stop`, yang menghentikan server sesaat sebelum menyalin `worlds/` lalu menjalankannya kembali.

### Melihat dan Memulihkan Backup

```bash
bedrock backup-list
```
```
TIMESTAMP            UKURAN     ISI
20260923_140000      812M       allowlist.json,permissions.json,server.properties,worlds
```

```bash
bedrock restore 20260923_140000                  # pulihkan worlds + config sekaligus
bedrock restore 20260923_140000 --worlds         # hanya worlds (server dihentikan lalu dijalankan lagi otomatis)
bedrock restore 20260923_140000 --configs        # hanya config; jika server aktif, allowlist/permissions
                                                  # dimuat ulang langsung (whitelist reload, permissions reload)
                                                  # tanpa perlu restart
```

### Retensi Backup

Secara default backup disimpan **selamanya** (`BACKUP_DIR`, sejajar dengan `SERVER_DIR`). Jika ingin membatasi jumlahnya, set environment variable `BEDROCK_BACKUP_RETAIN` (misal `=10` untuk menyimpan 10 backup terakhir saja). Batasan ini **tidak berlaku** untuk `player_activity.log` — log pemain selalu permanen terlepas dari pengaturan ini.

---

## Log Aktivitas Pemain

`bedrock logger install` memasang service `bedrock-player-logger` yang memantau `/var/log/bedrock-server.log` secara terus-menerus (`tail -F`, tahan terhadap rotasi/restart) dan mencatat setiap event `Player connected:` / `Player disconnected:` ke:

```
${SERVER_DIR}/player_activity.log
```

dengan format append-only:

```
2026-09-23 14:03:11|JOIN|Hilmy|2535419xxxxxxxxx
2026-09-23 15:41:02|LEAVE|Hilmy|2535419xxxxxxxxx
```

**Retensi tidak terbatas.** Tidak ada logrotate, tidak ada auto-trim berdasarkan usia entri (berbeda dengan `/var/log/bedrock-server.log` yang dirotasi mingguan oleh `install_logrotate`). Satu-satunya cara mengulang riwayat dari awal adalah menghapus file ini secara manual — `bedrock logger uninstall` sengaja **tidak** menghapusnya.

| Perintah | Fungsi |
|---|---|
| `bedrock logger install` | Pasang & aktifkan service logger (berjalan otomatis, `Restart=always`). |
| `bedrock logger uninstall` | Lepas service. Data historis tetap disimpan. |
| `bedrock logger status` | Status service + 5 entri terakhir. |
| `bedrock players [n]` | `n` baris terakhir (default 50). |
| `bedrock players today` | Aktivitas hari ini saja. |
| `bedrock players search <nama>` | Seluruh riwayat satu nama pemain. |
| `bedrock players count` | Jumlah entri & ukuran file. |
| `bedrock players stats` | Total sesi & total lama bermain (join→leave) per pemain, terurut dari yang terlama. |

---

## Pembaruan

```bash
bedrock update
```

Perintah ini meneruskan langsung ke `update_bedrock.sh` di `SERVER_DIR` (dapat juga dipanggil langsung: `sudo bedrock-update` atau `sudo /opt/bedrock-server/update_bedrock.sh`). Karena backup kini sudah mandiri (lihat [Backup dan Restore](#backup-dan-restore)), langkah backup di dalam `update_bedrock.sh` hanya menyalin tiga file konfigurasi kecil sebagai jaring pengaman sebelum overwrite binary — bukan pengganti `bedrock backup --worlds`.

### Opsi Update

| Opsi | Keterangan |
|---|---|
| *(tanpa opsi)* | Cek dan update jika ada versi baru. |
| `--force` | Paksa instalasi ulang meskipun versi sama. |
| `--no-restart` | Jangan jalankan ulang server setelah update. |
| `--backup-worlds` | Backup direktori `worlds` sebelum update (opsional; setara dengan menjalankan `bedrock backup --worlds --stop` sebelum update). |

Contoh penggunaan dengan opsi:

```bash
sudo bedrock-update --backup-worlds --force
```

Cek versi tanpa side effect apa pun:

```bash
bedrock version
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

**`bedrock backup --worlds` macet lama lalu menampilkan peringatan konsistensi**

Server belum membalas `Data saved. Files are now ready to be copied.` dalam ~2 menit (24 percobaan). Diagnosis dengan:

```bash
bedrock backup --worlds --debug
```

Ini menampilkan output mentah konsol pada setiap percobaan `save query`, sehingga terlihat jelas apakah server merespons dengan format berbeda atau tidak merespons sama sekali. Jika deteksi tetap gagal, gunakan `bedrock backup --worlds --stop` yang tidak bergantung pada parsing log sama sekali.

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

Atau langsung: `bedrock console` (menampilkan pesan eksplisit jika sesi tidak ditemukan, bukan macet tanpa keterangan).

**Server terdeteksi mati padahal sebenarnya berjalan**

Pastikan menggunakan `Type=simple` dan `screen -DmS` (huruf besar `D`) pada konfigurasi systemd. Konfigurasi lama `Type=forking` dengan `screen -dmS` menyebabkan systemd kehilangan jejak PID sehingga melaporkan status yang tidak akurat.

**`bedrock status` menampilkan penggunaan memori yang terasa terlalu kecil**

`MainPID` yang dilacak systemd untuk unit ini adalah proses `screen` pembungkus (~beberapa MB), bukan proses `bedrock_server` yang sebenarnya (dijalankan sebagai cucu proses lewat `bash -c`). `bedrock-manager.sh` versi terkini mencari PID `bedrock_server` secara langsung lewat `pgrep` untuk pengukuran RSS yang akurat; pastikan menggunakan versi terbaru skrip ini.

---

## Lisensi

Konfigurasi dan skrip dalam repositori ini bebas digunakan dan dimodifikasi. Binary Minecraft Bedrock Server adalah milik Microsoft/Mojang dan tunduk pada [Minecraft End User License Agreement](https://www.minecraft.net/en-us/eula).
