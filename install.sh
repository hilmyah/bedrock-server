#!/bin/bash
# =============================================================================
# install.sh - Installer Otomatis Minecraft Bedrock Server
# Repositori: https://github.com/hilmyah/bedrock-server
# =============================================================================
# Penggunaan (instalasi satu baris dari GitHub):
#   curl -fsSL https://raw.githubusercontent.com/hilmyah/bedrock-server/main/install.sh | sudo bash
#
# Atau dengan opsi:
#   curl -fsSL https://raw.githubusercontent.com/hilmyah/bedrock-server/main/install.sh | sudo bash -s -- --with-playit
#
# Menjalankan server sebagai user biasa di direktori home (bukan root, bukan /opt):
#   curl -fsSL https://raw.githubusercontent.com/hilmyah/bedrock-server/main/install.sh \
#     | sudo bash -s -- --user=hilmy --dir=/home/hilmy/projects/bedrock/bedrock-server
#
# Installer tetap harus dijalankan lewat sudo karena menulis unit systemd,
# konfigurasi logrotate, dan symlink di /usr/local/bin. Setelah itu server
# dan seluruh file datanya dimiliki oleh user yang dipilih lewat --user.
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# KONFIGURASI
# -----------------------------------------------------------------------------
SERVER_DIR=""
SERVICE_USER="root"
SCREEN_NAME="mc-server"
SERVER_LOG="/var/log/bedrock-server.log"
REPO_RAW="https://raw.githubusercontent.com/hilmyah/bedrock-server/main"
MINECRAFT_DOWNLOAD_URL="https://www.minecraft.net/en-us/download/server/bedrock"

# WARNA
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; RESET='\033[0m'

# FLAG OPSI
WITH_PLAYIT=false
SKIP_PLAYERLOG=false
PORT=19132

for arg in "$@"; do
    case "$arg" in
        --with-playit)   WITH_PLAYIT=true ;;
        --skip-playerlog) SKIP_PLAYERLOG=true ;;
        --port=*)
            PORT="${arg#*=}"
            if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65534 ]; then
                echo -e "${RED}[ERROR]${RESET} --port harus angka 1-65534 (server-portv6 dipakai = port+1, harus <=65535)."
                exit 1
            fi
            ;;
        --dir=*)         SERVER_DIR="${arg#*=}" ;;
        --user=*)        SERVICE_USER="${arg#*=}" ;;
        --help|-h)
            echo "Penggunaan: install.sh [opsi]"
            echo ""
            echo "Opsi:"
            echo "  --with-playit     Instal dan konfigurasi Playit.gg tunnel"
            echo "  --skip-playerlog  Jangan aktifkan player activity logger otomatis"
            echo "  --port=PORT       Port UDP server IPv4 (default: 19132). server-portv6 ikut diset ke PORT+1."
            echo "  --user=NAMA       User yang menjalankan server dan memiliki file-nya (default: root)"
            echo "  --dir=PATH        Direktori instalasi. Default: /opt/bedrock-server bila --user=root,"
            echo "                    selain itu <home user>/bedrock-server"
            exit 0
            ;;
        *)
            echo -e "${RED}[ERROR]${RESET} Opsi tidak dikenal: $arg. Gunakan --help."
            exit 1
            ;;
    esac
done

# -----------------------------------------------------------------------------
# FUNGSI
# -----------------------------------------------------------------------------
log() {
    local level="$1"; shift
    # Arahkan ke stderr agar tidak ditangkap oleh command substitution $()
    case "$level" in
        INFO)  echo -e "${GREEN}[INFO]${RESET}  $*" >&2 ;;
        WARN)  echo -e "${YELLOW}[WARN]${RESET}  $*" >&2 ;;
        ERROR) echo -e "${RED}[ERROR]${RESET} $*" >&2 ;;
        STEP)  echo -e "\n${BOLD}${BLUE}==> $*${RESET}" >&2 ;;
    esac
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        log ERROR "Installer harus dijalankan sebagai root atau dengan sudo."
        exit 1
    fi
}

# Validasi --user dan penentuan direktori instalasi. Dipanggil setelah
# check_root karena 'getent'/'id' tidak butuh root tetapi pembuatan direktori
# di tahap berikutnya butuh.
resolve_target() {
    if ! id "$SERVICE_USER" &>/dev/null; then
        log ERROR "User '$SERVICE_USER' tidak ditemukan. Buat dulu, mis.: adduser $SERVICE_USER"
        exit 1
    fi
    SERVICE_GROUP=$(id -gn "$SERVICE_USER")

    if [ -z "$SERVER_DIR" ]; then
        if [ "$SERVICE_USER" = "root" ]; then
            SERVER_DIR="/opt/bedrock-server"
        else
            local home
            home=$(getent passwd "$SERVICE_USER" | cut -d: -f6)
            if [ -z "$home" ] || [ ! -d "$home" ]; then
                log ERROR "Direktori home user '$SERVICE_USER' tidak ditemukan. Tentukan lokasi dengan --dir=PATH."
                exit 1
            fi
            SERVER_DIR="${home}/bedrock-server"
        fi
    fi

    case "$SERVER_DIR" in
        /*) ;;
        *)
            log ERROR "--dir harus path absolut (diawali '/'): $SERVER_DIR"
            exit 1
            ;;
    esac
    SERVER_DIR="${SERVER_DIR%/}"
}

# Menyerahkan kepemilikan ke user service. No-op bila service berjalan sebagai root.
own() {
    [ "$SERVICE_USER" = "root" ] && return 0
    chown -R "${SERVICE_USER}:${SERVICE_GROUP}" "$@"
}

check_os() {
    if ! grep -qiE 'debian|ubuntu' /etc/os-release 2>/dev/null; then
        log WARN "Sistem operasi tidak terdeteksi sebagai Debian/Ubuntu."
        log WARN "Instalasi mungkin tidak berfungsi dengan benar. Melanjutkan..."
    fi
}

install_dependencies() {
    log STEP "Memasang Dependensi"
    local packages=("curl" "wget" "unzip" "screen")
    # flock, runuser, dan script (dipakai bedrock-manager.sh) berasal dari paket
    # util-linux/bsdutils yang berstatus Essential di Debian/Ubuntu.
    local to_install=()

    for pkg in "${packages[@]}"; do
        if ! command -v "$pkg" &>/dev/null; then
            to_install+=("$pkg")
        fi
    done

    if [ ${#to_install[@]} -gt 0 ]; then
        log INFO "Memperbarui daftar paket..."
        apt-get update -qq
        log INFO "Memasang: ${to_install[*]}"
        apt-get install -y -qq "${to_install[@]}"
    else
        log INFO "Semua dependensi sudah terpasang."
    fi
}

fetch_latest_url() {
    local url=""

    log INFO "Mengambil informasi versi terbaru..."

    # Metode 1: API JSON Resmi Minecraft Services (Paling stabil, lolos anti-bot)
    url=$(curl -sL https://net-secondary.web.minecraft-services.net/api/v1.0/download/links | grep -Eo 'https://[^"]+bin-linux/bedrock-server-[0-9.]+\.zip' | head -n 1 || true)

    if [ -z "$url" ]; then
        log WARN "API resmi diblokir. Mencoba repositori tracker JSON GitHub..."
        # Metode 2: Tracker GitHub (Update harian otomatis via Github Actions)
        url=$(curl -sL https://raw.githubusercontent.com/kittizz/bedrock-server-downloads/main/bedrock-server-downloads.json | grep -Eo 'https://[^"]+bin-linux/bedrock-server-[0-9.]+\.zip' | head -n 1 || true)
    fi

    if [ -z "$url" ]; then
        log WARN "Tracker gagal. Mencoba web scraping HTML (Sering ditolak VPS)..."
        # Metode 3: Web scraping lama
        url=$(curl -Ls -A "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36" \
            -H "Accept-Language: en-US,en;q=0.9" \
            "https://www.minecraft.net/en-us/download/server/bedrock" \
        | sed 's/\\//g' | grep -Eo 'https://[^"'\''\\]+bin-linux/bedrock-server-[0-9.]+\.zip' | head -n 1 || true)
    fi

    if [ -z "$url" ]; then
        log ERROR "Gagal mendapatkan URL unduhan dinamis dari semua metode."
        log ERROR "Solusi Darurat: Unduh file zip secara manual ke dalam direktori server, lalu jalankan ulang perintah ./update_bedrock.sh --force"
        exit 1
    fi

    echo "$url"
}

install_server() {
    log STEP "Menginstal Minecraft Bedrock Server"

    mkdir -p "$SERVER_DIR"
    cd "$SERVER_DIR"

    local url file_name
    url=$(fetch_latest_url)
    file_name=$(basename "$url")

    log INFO "Versi yang akan diinstal: $(echo "$file_name" | sed 's/bedrock-server-//;s/\.zip//')"
    log INFO "Mengunduh $file_name..."

    wget --show-progress --retry-connrefused --waitretry=5 --tries=3 \
        -O "$file_name" "$url"

    log INFO "Mengekstrak arsip..."
    unzip -o -q "$file_name"
    chmod +x bedrock_server

    log INFO "Memasang file konfigurasi dari repositori..."
    # Unduh konfigurasi default dari repositori. --fail wajib: tanpa ini,
    # curl menganggap respons HTTP 404 sebagai sukses (exit 0) dan menulis
    # badan halaman error ("404: Not Found") sebagai isi file -- terverifikasi
    # langsung terhadap raw.githubusercontent.com. Kegagalan di sini TIDAK
    # fatal: bedrock_server resmi membuat server.properties/allowlist.json/
    # permissions.json dengan default Mojang sendiri saat pertama kali
    # dijalankan jika file tersebut belum ada.
    local tmp_cfg
    tmp_cfg=$(mktemp -d)
    for config_file in server.properties allowlist.json permissions.json; do
        if curl --fail --silent --max-time 10 -o "${tmp_cfg}/${config_file}" \
            "${REPO_RAW}/${config_file}" 2>/dev/null; then
            if [ ! -f "${SERVER_DIR}/${config_file}" ]; then
                cp "${tmp_cfg}/${config_file}" "${SERVER_DIR}/${config_file}"
                log INFO "Dipasang: $config_file"
            else
                log WARN "Melewati $config_file (sudah ada)."
            fi
        else
            log WARN "Gagal mengunduh $config_file dari repositori (dilewati, tidak fatal)."
            log WARN "bedrock_server akan membuat default Mojang sendiri saat pertama kali dijalankan."
        fi
    done
    rm -rf "$tmp_cfg"
}

install_update_script() {
    log STEP "Memasang Skrip Update Otomatis"

    # --fail wajib (lihat catatan di install_server): tanpa ini, HTTP 404
    # ditulis sebagai isi file dan dianggap sukses. Ini komponen inti (bukan
    # config opsional seperti server.properties), jadi kegagalan HARUS fatal
    # dengan pesan eksplisit -- bukan diam-diam lanjut lalu 'bedrock-update'
    # gagal dieksekusi tanpa penjelasan.
    if ! curl --fail --silent --show-error --max-time 30 \
        -o "${SERVER_DIR}/update_bedrock.sh" \
        "${REPO_RAW}/update_bedrock.sh"; then
        log ERROR "Gagal mengunduh update_bedrock.sh dari ${REPO_RAW}/update_bedrock.sh"
        log ERROR "Instalasi dibatalkan -- skrip update adalah komponen inti, bukan opsional."
        exit 1
    fi

    chmod +x "${SERVER_DIR}/update_bedrock.sh"
    log INFO "Skrip update dipasang: ${SERVER_DIR}/update_bedrock.sh"

    # Buat symlink di /usr/local/bin agar bisa dijalankan dari mana saja
    ln -sfn "${SERVER_DIR}/update_bedrock.sh" /usr/local/bin/bedrock-update
    log INFO "Symlink dibuat: bedrock-update (jalankan dari direktori mana saja)"
}

install_manager_script() {
    log STEP "Memasang Skrip Manajemen Terpadu (bedrock-manager.sh)"

    if ! curl --fail --silent --show-error --max-time 30 \
        -o "${SERVER_DIR}/bedrock-manager.sh" \
        "${REPO_RAW}/bedrock-manager.sh"; then
        log ERROR "Gagal mengunduh bedrock-manager.sh dari ${REPO_RAW}/bedrock-manager.sh"
        log ERROR "Instalasi dibatalkan -- CLI 'bedrock' adalah komponen inti, bukan opsional."
        exit 1
    fi

    chmod +x "${SERVER_DIR}/bedrock-manager.sh"
    ln -sfn "${SERVER_DIR}/bedrock-manager.sh" /usr/local/bin/bedrock
    log INFO "Skrip manajemen dipasang: ${SERVER_DIR}/bedrock-manager.sh"
    log INFO "Symlink dibuat: bedrock (mis. 'bedrock status', 'bedrock backup --worlds')"
}

install_systemd_service() {
    log STEP "Mengonfigurasi Systemd Service"

    # Type=simple dengan screen -DmS (D kapital) memaksa screen berjalan di
    # foreground sehingga systemd dapat melacak PID dengan akurasi penuh.
    # set -o pipefail memastikan crash pada binary server memicu Restart=on-failure,
    # tidak ditutupi oleh perintah tee.
    #
    # User=${SERVICE_USER}: proses server, sesi screen, dan 'tee' ke log konsol
    # semuanya berjalan sebagai user ini. Karena itu file log konsol dibuat di
    # sini dan diserahkan kepemilikannya; tanpa ini 'tee' gagal menulis ke
    # /var/log saat service berjalan bukan sebagai root.
    touch "$SERVER_LOG"
    chmod 644 "$SERVER_LOG"
    own "$SERVER_LOG"

    cat > /etc/systemd/system/bedrock.service << EOF
[Unit]
Description=Minecraft Bedrock Server
After=network.target

[Service]
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_GROUP}
WorkingDirectory=${SERVER_DIR}
ExecStart=/usr/bin/screen -DmS ${SCREEN_NAME} bash -c 'set -o pipefail; LD_LIBRARY_PATH=. ./bedrock_server | tee -a ${SERVER_LOG}'
ExecStop=/usr/bin/screen -S ${SCREEN_NAME} -p 0 -X stuff "stop\r"
TimeoutStopSec=30
Restart=on-failure
RestartSec=10s

[Install]
WantedBy=multi-user.target
EOF
    # Eksplisit 644: bila umask pemanggil 002, file menjadi group-writable.
    chmod 644 /etc/systemd/system/bedrock.service

    systemctl daemon-reload
    systemctl enable bedrock.service
    log INFO "Systemd service terdaftar dan diaktifkan (auto-start saat boot)."
    log INFO "Kontrol service: systemctl [start|stop|status] bedrock"
}

install_logrotate() {
    log STEP "Memasang Rotasi Log Konsol Server"
    # PENTING: hanya berlaku untuk /var/log/bedrock-server.log (output mentah
    # konsol server). File player_activity.log SENGAJA TIDAK diberi rotasi
    # apa pun agar riwayat join/leave pemain permanen sesuai spesifikasi.
    #
    # 'copytruncate' dipakai (bukan 'create'/postrotate kill -HUP) karena
    # proses 'tee -a' pada bedrock.service memegang file descriptor terbuka
    # terus-menerus; tanpa copytruncate, tee akan tetap menulis ke file lama
    # yang sudah di-rename dan file baru akan selalu kosong.
    cat > /etc/logrotate.d/bedrock-server << EOF
${SERVER_LOG} {
    weekly
    rotate 8
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
EOF
    # WAJIB 644 milik root: logrotate menolak seluruh file konfigurasi yang
    # group-writable ("Ignoring bedrock-server because it is writable by group
    # or others") dan logrotate.service berakhir failed. Terjadi bila umask
    # pemanggil 002.
    chown root:root /etc/logrotate.d/bedrock-server
    chmod 644 /etc/logrotate.d/bedrock-server
    log INFO "Rotasi dipasang: ${SERVER_LOG} (mingguan, simpan 8 arsip, copytruncate)."
    log INFO "player_activity.log TIDAK terpengaruh, tetap permanen tanpa rotasi."
}

install_playerlog() {
    log STEP "Mengaktifkan Player Activity Logger"
    if bash "${SERVER_DIR}/bedrock-manager.sh" logger install; then
        log INFO "Player activity logger aktif sejak instalasi awal."
    else
        log WARN "Gagal mengaktifkan player logger otomatis."
        log WARN "Jalankan manual nanti dengan: bedrock logger install"
    fi
}

install_playit() {
    log STEP "Memasang Playit.gg"

    curl -SsL https://playit-cloud.github.io/ppa/key.gpg \
        | gpg --dearmor \
        | tee /etc/apt/trusted.gpg.d/playit.gpg >/dev/null

    echo "deb [signed-by=/etc/apt/trusted.gpg.d/playit.gpg] https://playit-cloud.github.io/ppa/data ./" \
        | tee /etc/apt/sources.list.d/playit-cloud.list

    apt-get update -qq
    apt-get install -y -qq playit

    log INFO "Playit.gg berhasil diinstal."
    log WARN "Jalankan 'playit' untuk mendapatkan link klaim tunnel Anda."
}

# Sebelumnya variabel PORT hanya dipakai di pesan ringkasan akhir, TIDAK
# pernah benar-benar ditulis ke server.properties -- --port=PORT dari
# pengguna diam-diam tidak berpengaruh. Fungsi ini menulis server-port dan
# server-portv6 (=PORT+1, mengikuti pola gap +1 pada default resmi Mojang
# 19132/19133) langsung ke server.properties, harus dipanggil SEBELUM
# 'systemctl start bedrock.service' pertama kali agar berlaku tanpa restart.
configure_port() {
    local props="${SERVER_DIR}/server.properties"
    if [ ! -f "$props" ]; then
        log WARN "server.properties belum ada -- opsi --port=${PORT} tidak diterapkan."
        log WARN "Set manual (server-port, server-portv6) setelah server pertama kali dijalankan."
        return 0
    fi

    local portv6=$((PORT + 1))
    if grep -q '^server-port=' "$props"; then
        sed -i "s/^server-port=.*/server-port=${PORT}/" "$props"
    else
        echo "server-port=${PORT}" >> "$props"
    fi
    if grep -q '^server-portv6=' "$props"; then
        sed -i "s/^server-portv6=.*/server-portv6=${portv6}/" "$props"
    else
        echo "server-portv6=${portv6}" >> "$props"
    fi
    log INFO "server-port=${PORT}, server-portv6=${portv6} diterapkan ke server.properties."
}

# -----------------------------------------------------------------------------
# EKSEKUSI UTAMA
# -----------------------------------------------------------------------------
echo -e "${BOLD}"
echo "============================================================"
echo "   Minecraft Bedrock Server - Installer Otomatis"
echo "============================================================"
echo -e "${RESET}"
check_root
resolve_target

echo "  Direktori target : $SERVER_DIR"
echo "  User service     : $SERVICE_USER"
echo "  Screen session   : $SCREEN_NAME"
echo "  Playit.gg        : $([ "$WITH_PLAYIT" = true ] && echo "Ya" || echo "Tidak")"
echo "  Player logger    : $([ "$SKIP_PLAYERLOG" = true ] && echo "Tidak (dilewati)" || echo "Ya (otomatis)")"
echo ""

check_os
install_dependencies
install_server
configure_port
install_update_script
install_manager_script
# Seluruh isi direktori server diserahkan ke user service SEBELUM service
# pertama kali dijalankan, agar server dapat membuat worlds/ dan menulis config.
own "$SERVER_DIR"
install_systemd_service
install_logrotate

systemctl start bedrock.service
sleep 3

if [ "$SKIP_PLAYERLOG" = false ]; then
    install_playerlog
fi

if [ "$WITH_PLAYIT" = true ]; then
    install_playit
fi

# -----------------------------------------------------------------------------
# RINGKASAN & LANGKAH SELANJUTNYA
# -----------------------------------------------------------------------------
echo -e "\n${GREEN}${BOLD}============================================================"
echo "   Instalasi Berhasil!"
echo "============================================================${RESET}"
echo ""
echo -e "${BOLD}Langkah selanjutnya:${RESET}"
echo ""
echo "  1. Cek status server:"
echo -e "     ${BLUE}bedrock status${RESET}"
echo ""
echo "  2. Lihat konsol server:"
echo -e "     ${BLUE}bedrock console${RESET}  (keluar: Ctrl+A lalu D)"
echo ""
if [ "$WITH_PLAYIT" = true ]; then
    echo "  3. Konfigurasi Playit.gg:"
    echo -e "     ${BLUE}playit${RESET}  (buka link yang muncul, tambahkan tunnel Minecraft Bedrock UDP:$PORT)"
    echo ""
fi
echo "  4. Backup mandiri (tidak memicu update):"
echo -e "     ${BLUE}bedrock backup --worlds${RESET}"
echo ""
echo "  5. Update server di masa mendatang:"
echo -e "     ${BLUE}bedrock update${RESET}  (atau: bedrock-update)"
echo ""
echo "  6. Riwayat pemain (permanen, tanpa rotasi):"
echo -e "     ${BLUE}bedrock players stats${RESET}"
echo ""
echo -e "  Status service  : ${BLUE}systemctl status bedrock${RESET}"
echo -e "  Log server      : ${BLUE}tail -f ${SERVER_LOG}${RESET}"
if [ "$SERVICE_USER" != "root" ]; then
    echo ""
    echo -e "  Server berjalan sebagai user ${BOLD}${SERVICE_USER}${RESET}. Jalankan perintah 'bedrock' sebagai user"
    echo "  tersebut tanpa sudo; hanya start/stop/restart yang akan meminta password sudo."
fi
echo -e "  Semua perintah  : ${BLUE}bedrock help${RESET}"
echo ""