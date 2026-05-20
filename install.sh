#!/bin/bash
# =============================================================================
# install.sh — Installer Otomatis Minecraft Bedrock Server
# Repositori: https://github.com/hilmyah/bedrock-server
# =============================================================================
# Penggunaan (instalasi satu baris dari GitHub):
#   curl -fsSL https://raw.githubusercontent.com/hilmyah/bedrock-server/main/install.sh | sudo bash
#
# Atau dengan opsi:
#   curl -fsSL https://raw.githubusercontent.com/hilmyah/bedrock-server/main/install.sh | sudo bash -s -- --with-playit
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# KONFIGURASI
# -----------------------------------------------------------------------------
SERVER_DIR="/opt/bedrock-server"
SCREEN_NAME="mc-server"
REPO_RAW="https://raw.githubusercontent.com/hilmyah/bedrock-server/main"
MINECRAFT_DOWNLOAD_URL="https://www.minecraft.net/en-us/download/server/bedrock"

# WARNA
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; RESET='\033[0m'

# FLAG OPSI
WITH_PLAYIT=false
PORT=19132

for arg in "$@"; do
    case "$arg" in
        --with-playit)   WITH_PLAYIT=true ;;
        --port=*)        PORT="${arg#*=}" ;;
        --dir=*)         SERVER_DIR="${arg#*=}" ;;
        --help|-h)
            echo "Penggunaan: install.sh [opsi]"
            echo ""
            echo "Opsi:"
            echo "  --with-playit    Instal dan konfigurasi Playit.gg tunnel"
            echo "  --port=PORT      Port UDP server (default: 19132)"
            echo "  --dir=PATH       Direktori instalasi (default: /opt/bedrock-server)"
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

check_os() {
    if ! grep -qiE 'debian|ubuntu' /etc/os-release 2>/dev/null; then
        log WARN "Sistem operasi tidak terdeteksi sebagai Debian/Ubuntu."
        log WARN "Instalasi mungkin tidak berfungsi dengan benar. Melanjutkan..."
    fi
}

install_dependencies() {
    log STEP "Memasang Dependensi"
    local packages=("curl" "wget" "unzip" "screen")
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
    # Unduh konfigurasi default dari repositori
    for config_file in server.properties allowlist.json permissions.json; do
        if curl --silent --max-time 10 -o "/tmp/${config_file}" \
            "${REPO_RAW}/${config_file}" 2>/dev/null; then
            # Hanya timpa jika belum ada
            if [ ! -f "${SERVER_DIR}/${config_file}" ]; then
                cp "/tmp/${config_file}" "${SERVER_DIR}/${config_file}"
                log INFO "Dipasang: $config_file"
            else
                log WARN "Melewati $config_file (sudah ada)."
            fi
        fi
    done
}

install_update_script() {
    log STEP "Memasang Skrip Update Otomatis"

    curl --silent --max-time 30 \
        -o "${SERVER_DIR}/update_bedrock.sh" \
        "${REPO_RAW}/update_bedrock.sh"

    chmod +x "${SERVER_DIR}/update_bedrock.sh"
    log INFO "Skrip update dipasang: ${SERVER_DIR}/update_bedrock.sh"

    # Buat symlink di /usr/local/bin agar bisa dijalankan dari mana saja
    ln -sf "${SERVER_DIR}/update_bedrock.sh" /usr/local/bin/bedrock-update
    log INFO "Symlink dibuat: bedrock-update (jalankan dari direktori mana saja)"
}

install_systemd_service() {
    log STEP "Mengonfigurasi Systemd Service (Opsional)"

    cat > /etc/systemd/system/bedrock-server.service << EOF
[Unit]
Description=Minecraft Bedrock Server
After=network.target

[Service]
Type=forking
User=root
WorkingDirectory=${SERVER_DIR}
ExecStart=/usr/bin/screen -dmS ${SCREEN_NAME} bash -c 'LD_LIBRARY_PATH=. ./bedrock_server | tee -a /var/log/bedrock-server.log'
ExecStop=/usr/bin/screen -S ${SCREEN_NAME} -p 0 -X stuff "stop\r"
RemainAfterExit=yes
Restart=on-failure
RestartSec=10s

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable bedrock-server.service
    log INFO "Systemd service terdaftar dan diaktifkan (auto-start saat boot)."
    log INFO "Kontrol service: systemctl [start|stop|status] bedrock-server"
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

# -----------------------------------------------------------------------------
# EKSEKUSI UTAMA
# -----------------------------------------------------------------------------
echo -e "${BOLD}"
echo "============================================================"
echo "   Minecraft Bedrock Server — Installer Otomatis"
echo "============================================================"
echo -e "${RESET}"
echo "  Direktori target : $SERVER_DIR"
echo "  Screen session   : $SCREEN_NAME"
echo "  Playit.gg        : $([ "$WITH_PLAYIT" = true ] && echo "Ya" || echo "Tidak")"
echo ""

check_root
check_os
install_dependencies
install_server
install_update_script
install_systemd_service

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
echo "  1. Jalankan server:"
echo -e "     ${BLUE}systemctl start bedrock-server${RESET}"
echo "     atau manual:"
echo -e "     ${BLUE}screen -S $SCREEN_NAME bash -c 'cd $SERVER_DIR && LD_LIBRARY_PATH=. ./bedrock_server'${RESET}"
echo ""
echo "  2. Lihat konsol server:"
echo -e "     ${BLUE}screen -r $SCREEN_NAME${RESET}  (keluar: Ctrl+A lalu D)"
echo ""
if [ "$WITH_PLAYIT" = true ]; then
    echo "  3. Konfigurasi Playit.gg:"
    echo -e "     ${BLUE}playit${RESET}  (buka link yang muncul, tambahkan tunnel Minecraft Bedrock UDP:$PORT)"
    echo ""
fi
echo "  4. Update server di masa mendatang:"
echo -e "     ${BLUE}sudo bedrock-update${RESET}"
echo -e "     atau: ${BLUE}sudo $SERVER_DIR/update_bedrock.sh${RESET}"
echo ""
echo -e "  Log server  : ${BLUE}tail -f /var/log/bedrock-server.log${RESET}"
echo -e "  Log update  : ${BLUE}tail -f /var/log/bedrock-update.log${RESET}"
echo ""
