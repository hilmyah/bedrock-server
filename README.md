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
- [Memindahkan Server atau Mengganti User](#memindahkan-server-atau-mengganti-user)
- [Troubleshooting](#troubleshooting)
- [Lisensi](#lisensi)

---

## Fitur

| Fitur | Deskripsi |
|---|---|
| Instalasi Satu Perintah | Skrip `install.sh` menangani seluruh proses: unduh binary, pasang `bedrock-manager.sh`, konfigurasi systemd service, rotasi log konsol, player activity logger, dan opsional Playit.gg - semua dalam satu perintah. |
| Playit.gg Tunnel | Menyediakan alamat publik permanen untuk server tanpa memerlukan IP statis atau konfigurasi port forwarding pada router. |
| Lokasi dan User Bebas | Server boleh berada di direktori mana saja (`/opt`, `~/projects`, dan lain-lain) dan boleh berjalan sebagai `root` maupun user biasa. Skrip membaca lokasi dan user langsung dari unit systemd, tanpa file konfigurasi tambahan. |
| Systemd Service | Server diregistrasikan sebagai systemd service dengan restart otomatis saat crash (`Restart=on-failure`) dan auto-start saat boot. |
| Manajemen Terpadu | `bedrock-manager.sh` (dipanggil sebagai `bedrock`) menyatukan start/stop/restart/status, konsol, kirim perintah in-game, backup mandiri, restore, dan pembacaan log pemain dalam satu CLI. |
| Backup Independen dari Update | `bedrock backup` dapat dijalankan kapan pun tanpa memicu proses update. Backup worlds memakai mekanisme resmi `save hold`/`save query`/`save resume` agar server tidak perlu berhenti. |
| Log Aktivitas Pemain Permanen | Setiap event join/leave pemain di-append ke `player_activity.log`. Tidak ada rotasi atau penghapusan otomatis berdasarkan waktu - riwayat hanya reset jika file dihapus manual. |
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

Server dikelola oleh systemd menggunakan `Type=simple` dengan `screen -DmS` agar systemd dapat melacak PID proses secara akurat. Screen berjalan di foreground dari perspektif systemd sekaligus menyediakan sesi konsol interaktif yang dapat diakses kapan pun. `bedrock-manager.sh` berada di atas lapisan ini: ia mengirim perintah ke sesi screen yang sama, memanggil `systemctl`, dan membaca/menulis log - tanpa mengubah cara systemd mengelola proses.

---

## Struktur Repository

```
bedrock-server/
├── install.sh              Installer satu-perintah: unduh binary, pasang bedrock-manager.sh,
│                            buat systemd service + logrotate, aktifkan player logger, opsional Playit.gg.
├── bedrock-manager.sh       CLI manajemen terpadu (start/stop/backup/restore/players/dst).
│                            Di-symlink ke /usr/local/bin/bedrock saat instalasi.
│                            Tidak terikat lokasi: boleh dipindah bersama direktori server.
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
| `.bedrock-manager.lock` | `bedrock` / `bedrock-update` | File lock bersama (lihat [Locking](#locking-eksklusi-mutual)). Aman dihapus bila tidak ada operasi yang berjalan. |
| `bedrock-update.log` | `update_bedrock.sh` | Log update bila skrip dijalankan tanpa root. Bila dijalankan sebagai root, log berada di `/var/log/bedrock-update.log`. |
| `worlds.before-restore-*/`, `.config-before-restore-*/` | `bedrock restore` | Salinan pengaman data sebelum restore. Dihapus manual. |

---

## Prasyarat

| Komponen | Spesifikasi / Versi | Keterangan |
|---|---|---|
| Sistem Operasi | Debian 11+ / Ubuntu 20.04+ | Library sistem yang kompatibel diperlukan untuk binary Bedrock. |
| Akses | `sudo` saat instalasi | Installer menulis unit ke `/etc/systemd/system`, konfigurasi ke `/etc/logrotate.d`, dan symlink ke `/usr/local/bin`. Setelah terpasang, operasi harian cukup dijalankan sebagai user pemilik service (lihat [Hak Akses](#hak-akses)). |
| `curl`, `wget`, `unzip`, `screen` | Versi paket apt terbaru | Dependensi runtime untuk installer, pengunduhan binary, dan manajemen proses. |
| `flock`, `runuser`, `script` | Paket `util-linux` / `bsdutils` (bawaan) | Dipakai `bedrock-manager.sh` untuk locking dan untuk mengakses sesi screen milik user service saat dipanggil lewat `sudo`. |
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

Untuk menjalankan server sebagai user biasa di direktori home, tanpa `/opt` dan tanpa proses yang berjalan sebagai root:

```bash
curl -fsSL https://raw.githubusercontent.com/hilmyah/bedrock-server/main/install.sh \
  | sudo bash -s -- --user=hilmy --dir=/home/hilmy/projects/bedrock/bedrock-server
```

Opsi installer:

| Opsi | Keterangan |
|---|---|
| `--with-playit` | Instal dan konfigurasi Playit.gg secara otomatis. |
| `--skip-playerlog` | Jangan aktifkan player activity logger otomatis (bisa dipasang belakangan dengan `sudo bedrock logger install`). |
| `--port=PORT` | Tentukan port UDP server (default: `19132`). |
| `--user=NAMA` | User yang menjalankan server dan memiliki seluruh file-nya (default: `root`). User harus sudah ada. |
| `--dir=PATH` | Direktori instalasi, wajib path absolut. Default: `/opt/bedrock-server` bila `--user=root`, selain itu `<home user>/bedrock-server`. |

Dengan `--user`, installer menulis `User=` dan `Group=` pada unit systemd, menyerahkan kepemilikan direktori server dan `/var/log/bedrock-server.log` ke user tersebut, lalu memasang player logger dengan user yang sama.

### Instalasi Manual

Contoh di bawah memakai `/opt/bedrock-server` dan `User=root`. Untuk lokasi atau user lain, ganti path tersebut dan nilai `User=` pada unit, lalu pastikan direktori server serta `/var/log/bedrock-server.log` dimiliki user itu (`chown`).

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

`self-install` juga membuat symlink `bedrock-update` bila `update_bedrock.sh` berada di direktori yang sama.

---

## Manajemen Terpadu (bedrock-manager.sh)

Setelah instalasi, seluruh operasi harian dilakukan lewat perintah `bedrock` (symlink ke `bedrock-manager.sh`). Skrip ini bersifat universal: path server, nama screen, user service, dan path log TIDAK di-hardcode, melainkan diresolusi berurutan dari:

1. environment variable `BEDROCK_*`,
2. `/etc/bedrock-manager/manager.conf` (opsional, tidak perlu dibuat),
3. introspeksi `systemctl show` pada unit yang terpasang (`WorkingDirectory`, `User`, nama screen dan path log dari `ExecStart`),
4. direktori tempat skrip itu sendiri berada, bila berisi `bedrock_server`,
5. nilai default (`/opt/bedrock-server`, `root`, `mc-server`).

Akibatnya skrip yang sama bekerja di lokasi mana pun tanpa diedit. Periksa hasil resolusi kapan saja dengan:

```bash
bedrock _print-config
```

### Hak Akses

Jalankan `bedrock` sebagai **user pemilik service** tanpa `sudo`, atau sebagai root. User lain ditolak dengan pesan eksplisit.

| Perintah | Sebagai user service | Catatan |
|---|---|---|
| `status`, `version`, `logs`, `players`, `backup-list` | Langsung | Hanya membaca. |
| `console`, `send`, `online` | Langsung | Sesi screen dimiliki user service. |
| `backup`, `backup --worlds` | Langsung | Live snapshot tidak menghentikan server. |
| `start`, `stop`, `restart`, `backup --stop`, `restore --worlds`, `update` | Meminta password `sudo` | Hanya pemanggilan `systemctl` yang dinaikkan haknya; penyalinan file tetap dilakukan sebagai user service. |
| `logger install`, `logger uninstall`, `self-install` | Wajib `sudo bedrock ...` | Menulis ke `/etc/systemd/system` atau `/usr/local/bin`. |

Bila `bedrock` dipanggil lewat `sudo` sementara service milik user biasa, skrip menjalankan perintah `screen` sebagai user tersebut (`runuser`) dan mengembalikan kepemilikan file hasil backup, restore, dan update ke user tersebut, sehingga tidak ada file milik root yang tertinggal di direktori server.

### Kontrol Service

| Perintah | Fungsi |
|---|---|
| `bedrock start` / `stop` / `restart` | Kontrol systemd service `bedrock`. |
| `bedrock status` | Status service, versi terpasang, RAM (RSS) proses `bedrock_server` yang sebenarnya, ukuran `worlds/`, dan ringkasan log pemain. |
| `bedrock console` | Attach ke sesi screen (`Ctrl+A` lalu `D` untuk keluar tanpa menghentikan server). |
| `bedrock send "<perintah>"` | Kirim satu perintah in-game langsung tanpa perlu attach ke konsol, misal `bedrock send "say Server restart 5 menit lagi"`. |
| `bedrock online` | Kirim `list` ke konsol dan baca hasilnya dari log. |
| `bedrock version` | Bandingkan versi terpasang vs versi terbaru di server Mojang, **tanpa** menghentikan atau mengunduh apa pun. |

> **Catatan jujur soal keterbatasan:** Bedrock Dedicated Server tidak memiliki RCON bawaan. `send` dan `online` bekerja dengan menyuntikkan teks ke sesi `screen`, bukan lewat protokol terstruktur. Jika sesi screen tidak ditemukan (server mati atau nama screen tidak cocok), perintah akan gagal dengan pesan eksplisit - bukan output yang dipalsukan.

### Locking (Eksklusi Mutual)

`backup`, `restore`, `update`, dan `restart` saling mengunci lewat `flock` pada satu `LOCK_FILE` (default: `<SERVER_DIR>/.bedrock-manager.lock`), agar dua operasi ini tidak pernah berjalan bersamaan dan saling menimpa `worlds/` atau `BACKUP_DIR` di tengah jalan. Kalau salah satunya sedang berjalan dan operasi lain dari perintah yang sama dicoba, yang belakangan langsung ditolak dengan pesan eksplisit, bukan menunggu tanpa batas:

```
[ERROR] Operasi lain (backup/restore/update/restart) sedang berjalan.
[ERROR] Tunggu sampai selesai, lalu coba lagi.
[ERROR] Kalau yakin tidak ada proses lain yang berjalan: rm -f <SERVER_DIR>/.bedrock-manager.lock
```

Lock sengaja disimpan di dalam `SERVER_DIR`, bukan `/var/lock`. Direktori sticky yang world-writable seperti `/run/lock` menolak pembukaan file milik user lain (`fs.protected_regular`), termasuk oleh root, sehingga lock yang dibuat user service tidak dapat dipakai bersama pemanggilan lewat `sudo`.

`start`, `stop`, `status`, `console`, `send`, `online`, `logs`, `players`, `version`, dan `logger` TIDAK memerlukan lock ini: baik karena murni membaca (`logs`, `players`, `status`), maupun karena secara desain dianggap tidak berisiko menimpa data (`start`/`stop` individual, berbeda dari `restart`).

`update_bedrock.sh` ikut serta di lock yang sama, dari jalur manapun ia dipanggil:
- Lewat `bedrock update`: lock sudah dipegang oleh `bedrock-manager.sh` sebelum `exec` ke `update_bedrock.sh`, dan diwariskan lewat file descriptor yang sama (bukan dibuka ulang, untuk menghindari celah lepas-kunci sesaat).
- Lewat pemanggilan langsung (`bedrock-update` atau `bash update_bedrock.sh`): lock diperoleh sendiri di awal skrip dengan mekanisme `flock -n` yang identik.

Baik dipanggil lewat `bedrock update` maupun langsung, update tidak akan pernah berjalan bersamaan dengan `bedrock backup`/`restore`/`restart` yang sedang aktif.

### Konfigurasi Override (opsional)

File ini **tidak diperlukan** pada instalasi biasa, termasuk setelah server dipindah atau berganti user, karena nilainya dibaca dari unit systemd. Buat `/etc/bedrock-manager/manager.conf` hanya bila ingin menimpa hasil resolusi otomatis, dan isi hanya baris yang ingin ditimpa:

```bash
SERVICE_NAME="bedrock"
SERVER_DIR="/home/hilmy/projects/bedrock/bedrock-server"
SERVICE_USER="hilmy"
SCREEN_NAME="mc-server"
LOG_FILE="/var/log/bedrock-server.log"
PLAYER_LOG="/home/hilmy/projects/bedrock/bedrock-server/player_activity.log"
BACKUP_DIR="/home/hilmy/projects/bedrock/bedrock-server-backup"
BACKUP_RETAIN=0
LOCK_FILE="/home/hilmy/projects/bedrock/bedrock-server/.bedrock-manager.lock"
```

`BACKUP_RETAIN=0` berarti tanpa batas (simpan semua backup selamanya, lihat [Retensi Backup](#retensi-backup)); `LOCK_FILE` adalah path lock yang dipakai bersama oleh `backup`/`restore`/`update`/`restart` (lihat [Locking](#locking-eksklusi-mutual)).

Atau lewat environment variable dengan prefiks `BEDROCK_` (mis. `BEDROCK_SERVER_DIR`, `BEDROCK_SERVICE_USER`, `BEDROCK_BACKUP_RETAIN`, `BEDROCK_LOCK_FILE`). Lokasi file konfigurasi sendiri dapat diganti dengan `BEDROCK_CONF_FILE`.

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

1. `save hold` - server bersiap, kembali segera (asinkron).
2. `save query` - dipanggil berulang (maks. 24 kali, jeda 5 detik) sampai server membalas `Data saved. Files are now ready to be copied.` beserta daftar `path:panjang_byte`.
3. Setiap file pada daftar tersebut disalin dan **dipotong (truncate)** persis sesuai panjang byte yang dilaporkan - bukan sekadar `cp -r` mentah - sehingga hasilnya tetap konsisten meski server terus menulis data di background.
4. `save resume` - selalu dikirim di akhir, termasuk saat terjadi timeout/error (dijamin lewat `trap`), agar dunia tidak "tertahan".

Parser daftar file toleran terhadap variasi format antar versi server (pemisah `,` atau `, `, path dengan atau tanpa awalan `worlds/`, daftar di baris sendiri atau menyambung setelah kalimat `ready to be copied.`). Hasilnya selalu ditulis sebagai `<backup>/worlds/<nama level>/...`. Bila satu saja entri pada daftar gagal disalin, seluruh backup dibatalkan.

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

### Mekanisme Restore (atomik + rollback lokal)

Restore tidak pernah menghapus data aktif sebelum data pengganti terbukti utuh:

- **Worlds**: data dari backup disalin dulu ke direktori staging sementara (`worlds/` yang aktif sama sekali tidak disentuh selama proses ini). Hasil salinan diverifikasi tidak kosong, baru `worlds/` lama dan staging DITUKAR lewat dua operasi `mv` (rename, bukan copy: nyaris instan, jauh lebih kecil risiko gagal di tengah jalan dibanding menyalin ratusan MB data). `worlds/` lama **tidak dihapus**, hanya di-rename menjadi `worlds.before-restore-<timestamp-restore>` di `SERVER_DIR` sebagai rollback manual kalau ternyata backup yang dipilih salah.
- **Config**: `server.properties`, `allowlist.json`, `permissions.json` yang aktif disalin dulu ke `.config-before-restore-<timestamp-restore>` sebelum ditimpa.
- Kalau penyalinan ke staging gagal atau hasilnya kosong, restore **dibatalkan** dan data aktif tidak diubah sama sekali, bukan separuh jadi.
- `<timestamp-restore>` adalah waktu saat perintah `restore` dijalankan, berbeda dari `<ts>` argumen (timestamp backup yang dipulihkan).

Bersihkan manual setelah yakin hasil restore benar:

```bash
rm -rf <SERVER_DIR>/worlds.before-restore-<timestamp-restore>
rm -rf <SERVER_DIR>/.config-before-restore-<timestamp-restore>
```

### Retensi Backup

Secara default backup disimpan **selamanya** (`BACKUP_DIR`, sejajar dengan `SERVER_DIR`). Jika ingin membatasi jumlahnya, set environment variable `BEDROCK_BACKUP_RETAIN` (misal `=10` untuk menyimpan 10 backup terakhir saja). Batasan ini **tidak berlaku** untuk `player_activity.log` - log pemain selalu permanen terlepas dari pengaturan ini.

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

**Retensi tidak terbatas.** Tidak ada logrotate, tidak ada auto-trim berdasarkan usia entri (berbeda dengan `/var/log/bedrock-server.log` yang dirotasi mingguan oleh `install_logrotate`). Satu-satunya cara mengulang riwayat dari awal adalah menghapus file ini secara manual - `bedrock logger uninstall` sengaja **tidak** menghapusnya.

| Perintah | Fungsi |
|---|---|
| `sudo bedrock logger install` | Pasang & aktifkan service logger (berjalan otomatis, `Restart=always`, sebagai user yang sama dengan service server). Jalankan ulang setelah server dipindah atau berganti user. |
| `sudo bedrock logger uninstall` | Lepas service. Data historis tetap disimpan. |
| `bedrock logger status` | Status service + 5 entri terakhir. |
| `bedrock players [n]` | `n` baris terakhir (default 50). |
| `bedrock players today` | Aktivitas hari ini saja. |
| `bedrock players search <nama>` | Seluruh riwayat satu nama pemain. |
| `bedrock players count` | Jumlah entri & ukuran file. |
| `bedrock players stats` | Total sesi & total lama bermain (join→leave), dikelompokkan per **XUID** (bukan per nama: nama bisa berganti, XUID tetap; nama yang ditampilkan adalah nama terakhir tercatat untuk XUID tsb), terurut dari yang terlama. |

---

## Pembaruan

```bash
bedrock update
```

Perintah ini meneruskan langsung ke `update_bedrock.sh` di `SERVER_DIR` (dapat juga dipanggil langsung: `bedrock-update` atau `bash <SERVER_DIR>/update_bedrock.sh`). Jalankan sebagai user pemilik service; skrip meminta password `sudo` hanya untuk `systemctl stop` dan `systemctl start`. Karena backup kini sudah mandiri (lihat [Backup dan Restore](#backup-dan-restore)), langkah backup di dalam `update_bedrock.sh` hanya menyalin tiga file konfigurasi kecil sebagai jaring pengaman sebelum overwrite binary - bukan pengganti `bedrock backup --worlds`.

### Opsi Update

| Opsi | Keterangan |
|---|---|
| *(tanpa opsi)* | Cek dan update jika ada versi baru. |
| `--force` | Paksa instalasi ulang meskipun versi sama. |
| `--no-restart` | Jangan jalankan ulang server setelah update. |
| `--backup-worlds` | Backup direktori `worlds` sebelum update (opsional; setara dengan menjalankan `bedrock backup --worlds --stop` sebelum update). |

Contoh penggunaan dengan opsi:

```bash
bedrock-update --backup-worlds --force
```

Cek versi tanpa side effect apa pun:

```bash
bedrock version
```

### Mekanisme Kerja Skrip

1. **Deteksi versi** - Membandingkan versi terpasang dengan versi terbaru dari situs resmi Minecraft, dengan sistem fallback 3 lapis.
2. **Unduh** - Mengunduh arsip baru ke file sementara dengan retry otomatis, lalu menguji integritasnya (`unzip -t`). Tahap ini berlangsung **selagi server masih berjalan**: bila unduhan gagal atau arsip rusak, update dibatalkan tanpa menghentikan server dan tanpa mengubah file apa pun.
3. **Penghentian aman** - Mendelegasikan shutdown ke `systemctl stop bedrock`, yang mengirim perintah `stop` ke konsol dan menunggu server menyimpan data dunia sebelum dilanjutkan.
4. **Backup konfigurasi** - Menyalin `server.properties`, `allowlist.json`, dan `permissions.json` ke direktori backup bertimestamp (`<SERVER_DIR>-backup/YYYYMMDD_HHMMSS/`).
5. **Ekstrak dan pemulihan konfigurasi** - Mengekstrak dengan mode overwrite (`unzip -o`), lalu mengembalikan file konfigurasi dari backup agar pengaturan tidak hilang.
6. **Jalankan ulang** - Memulai kembali server via `systemctl start bedrock` dan memverifikasi bahwa service aktif.

Log update ditulis ke `/var/log/bedrock-update.log` bila skrip dijalankan sebagai root, atau ke `<SERVER_DIR>/bedrock-update.log` bila dijalankan sebagai user biasa.

---

## Memindahkan Server atau Mengganti User

Karena skrip membaca lokasi dan user dari unit systemd, memindahkan instalasi (misalnya dari `/opt/bedrock-server` milik root ke `~/projects/bedrock/bedrock-server` milik user biasa) hanya membutuhkan perubahan pada unit, tanpa mengedit skrip dan tanpa file konfigurasi baru.

Contoh untuk user `hilmy`, dijalankan sebagai root:

```bash
NEW=/home/hilmy/projects/bedrock/bedrock-server
OLD=/opt/bedrock-server

# 1. Hentikan server SEBELUM menyalin, agar database world konsisten
systemctl stop bedrock-player-logger bedrock

# 2. Salin dengan atribut utuh, lalu serahkan kepemilikan
mkdir -p "$(dirname "$NEW")"
cp -a "$OLD" "$NEW"
cp -a "${OLD}-backup" "${NEW}-backup"
chown -R hilmy:hilmy "$NEW" "${NEW}-backup" /var/log/bedrock-server.log

# 3. Arahkan unit ke lokasi dan user baru
sed -i -e "s#^WorkingDirectory=.*#WorkingDirectory=${NEW}#" -e 's#^User=.*#User=hilmy#' \
  /etc/systemd/system/bedrock.service
systemctl daemon-reload

# 4. Perbarui symlink dan pasang ulang player logger dari lokasi baru
bash "$NEW/bedrock-manager.sh" self-install
systemctl start bedrock
bedrock logger install

# 5. Verifikasi, baru hapus lokasi lama
bedrock _print-config
ps -o user,cmd -C bedrock_server
rm -rf "$OLD" "${OLD}-backup"
```

Setelah itu seluruh perintah harian dijalankan sebagai `hilmy` tanpa `sudo` (lihat [Hak Akses](#hak-akses)).

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

Skrip menggunakan sistem fallback 3 lapis: endpoint API JSON internal Minecraft, repositori tracker pihak ketiga di GitHub (`raw.githubusercontent.com`), dan penyamaran sebagai user-agent browser valid. Jika ketiga metode gagal, unduh `bedrock-server-<versi>.zip` secara manual ke direktori server lalu jalankan:

```bash
bedrock-update --force
```

Dengan `--force`, skrip memakai arsip lokal terbaru di direktori server tanpa mengunduh.

**`Sesi screen 'mc-server' tidak ditemukan` padahal server berjalan**

Sesi screen hanya terlihat oleh user yang menjalankan service. `screen -ls` sebagai root tidak menampilkan sesi milik user lain. Periksa user service dan pemanggil:

```bash
bedrock _print-config | grep -E 'SERVICE_USER|CURRENT_USER'
```

Jalankan `bedrock` sebagai user service, atau lewat `sudo bedrock ...` (skrip beralih ke user service secara otomatis untuk perintah screen).

**`logrotate.service` berstatus failed dengan pesan `Ignoring bedrock-server because it is writable by group or others`**

File `/etc/logrotate.d/bedrock-server` dibuat dengan umask 002 sehingga group-writable, dan logrotate menolak seluruh isinya. Perbaiki:

```bash
sudo chown root:root /etc/logrotate.d/bedrock-server
sudo chmod 644 /etc/logrotate.d/bedrock-server
sudo systemctl start logrotate.service
```

Installer versi terkini sudah menyetel mode ini secara eksplisit.

**Server gagal start setelah berganti user (`tee: /var/log/bedrock-server.log: Permission denied`)**

Log konsol ditulis oleh proses service. Serahkan kepemilikannya ke user service:

```bash
sudo chown <user>:<user> /var/log/bedrock-server.log
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