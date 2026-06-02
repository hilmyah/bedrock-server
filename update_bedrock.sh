#!/bin/bash
# =============================================================================
# update_bedrock.sh — Skrip Pembaruan Otomatis Minecraft Bedrock Server
# Repositori: https://github.com/hilmyah/bedrock-server
# =============================================================================
# Deskripsi:
#   Mengunduh dan memasang versi terbaru binary Minecraft Bedrock Server secara
#   otomatis: mendeteksi versi terkini, menghentikan server via systemd,
#   membackup konfigurasi, mengekstrak binary baru, lalu menjalankan kembali
#   server via systemd.
#
# Prasyarat:
#   curl, wget, unzip, screen, systemctl
#
# Penggunaan:
#   sudo bash update_bedrock.sh [--force] [--no-restart] [--backup-worlds]
#
# Opsi:
#   --force          Paksa update meskipun versi sudah sama
#   --no-restart     Jangan jalankan ulang server setelah update
#   --backup-worlds  Backup direktori worlds sebelum update
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# KONFIGURASI — Sesuaikan jika diperlukan
# -----------------------------------------------------------------------------
SERVER_DIR="/opt/bedrock-server"
SCREEN_NAME="mc-server"
BACKUP_DIR="/opt/bedrock-server-backup"
LOG_FILE="/var/log/bedrock-update.log"
MINECRAFT_DOWNLOAD_URL="https://www.minecraft.net/en-us/download/server/bedrock"

# -----------------------------------------------------------------------------
# WARNA OUTPUT
# -----------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
RESET='\033[0m'

# -----------------------------------------------------------------------------
# FLAG OPSI
# -----------------------------------------------------------------------------
FORCE_UPDATE=false
NO_RESTART=false
BACKUP_WORLDS=false

for arg in "$@"; do
    case "$arg" in
        --force)         FORCE_UPDATE=true ;;
        --no-restart)    NO_RESTART=true ;;
        --backup-worlds) BACKUP_WORLDS=true ;;
        --help|-h)
            grep '^#' "$0" | grep -v '#!/' | sed 's/^# \?//'
            exit 0
            ;;
        *)
            echo -e "${RED}[ERROR]${RESET} Opsi tidak dikenal: $arg"
            echo "Gunakan --help untuk informasi penggunaan."
            exit 1
            ;;
    esac
done

# -----------------------------------------------------------------------------
# FUNGSI UTILITAS
# -----------------------------------------------------------------------------
log() {
    local level="$1"; shift
    local message="$*"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    # Arahkan ke stderr agar tidak ditangkap oleh command substitution $()
    case "$level" in
        INFO)  echo -e "${GREEN}[INFO]${RESET}  $message" >&2 ;;
        WARN)  echo -e "${YELLOW}[WARN]${RESET}  $message" >&2 ;;
        ERROR) echo -e "${RED}[ERROR]${RESET} $message" >&2 ;;
        STEP)  echo -e "\n${BOLD}${BLUE}==> $message${RESET}" >&2 ;;
    esac

    echo "[$timestamp] [$level] $message" >> "$LOG_FILE" 2>/dev/null || true
}

check_dependencies() {
    local missing=()
    for cmd in curl wget unzip screen systemctl; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done

    if [ ${#missing[@]} -gt 0 ]; then
        log ERROR "Dependensi berikut tidak ditemukan: ${missing[*]}"
        log ERROR "Instal dengan: apt install ${missing[*]}"
        exit 1
    fi
}

is_server_running() {
    systemctl is-active --quiet bedrock
}

get_current_version() {
    # Bungkus dalam subshell + || true agar set -e tidak fatal saat file zip tidak ada
    local zip_file
    zip_file=$( (ls "${SERVER_DIR}"/bedrock-server-*.zip 2>/dev/null | sort -V | tail -n 1) || true )
    if [ -n "$zip_file" ]; then
        basename "$zip_file" .zip | sed 's/bedrock-server-//'
    else
        echo "tidak_diketahui"
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

# -----------------------------------------------------------------------------
# MULAI EKSEKUSI
# -----------------------------------------------------------------------------
echo -e "${BOLD}"
echo "============================================================"
echo "   Minecraft Bedrock Server — Skrip Pembaruan Otomatis"
echo "============================================================"
echo -e "${RESET}"

# Periksa hak akses root
if [ "$EUID" -ne 0 ]; then
    log ERROR "Skrip ini harus dijalankan sebagai root atau dengan sudo."
    exit 1
fi

# Periksa dependensi
check_dependencies

# Masuk ke direktori server
if [ ! -d "$SERVER_DIR" ]; then
    log ERROR "Direktori server tidak ditemukan: $SERVER_DIR"
    exit 1
fi
cd "$SERVER_DIR"

# -----------------------------------------------------------------------------
# LANGKAH 1: Deteksi Versi
# -----------------------------------------------------------------------------
log STEP "Memeriksa Versi"

LATEST_URL=$(fetch_latest_url)
FILE_NAME=$(basename "$LATEST_URL")
LATEST_VERSION=$(echo "$FILE_NAME" | sed 's/bedrock-server-//' | sed 's/\.zip//')
CURRENT_VERSION=$(get_current_version)

log INFO "Versi terpasang : ${CURRENT_VERSION}"
log INFO "Versi terbaru   : ${LATEST_VERSION}"

if [ "$CURRENT_VERSION" = "$LATEST_VERSION" ] && [ "$FORCE_UPDATE" = false ]; then
    log INFO "Server sudah menggunakan versi terbaru. Tidak ada pembaruan diperlukan."
    log INFO "Gunakan flag --force untuk memaksa instalasi ulang."
    exit 0
fi

if [ "$FORCE_UPDATE" = true ] && [ "$CURRENT_VERSION" = "$LATEST_VERSION" ]; then
    log WARN "Mode --force aktif. Melanjutkan instalasi ulang versi yang sama."
fi

# -----------------------------------------------------------------------------
# LANGKAH 2: Hentikan Server
# -----------------------------------------------------------------------------
log STEP "Menghentikan Server"

if is_server_running; then
    log INFO "Memerintahkan systemd untuk mematikan server secara sinkron..."
    # systemctl stop menunggu ExecStop selesai sebelum kembali, sehingga
    # tidak diperlukan sleep manual — server dijamin sudah berhenti penuh.
    systemctl stop bedrock
    log INFO "Server berhasil dihentikan."
else
    log INFO "Server tidak sedang berjalan. Melanjutkan pembaruan."
fi

# -----------------------------------------------------------------------------
# LANGKAH 3: Backup
# -----------------------------------------------------------------------------
log STEP "Membuat Backup Konfigurasi"

TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
mkdir -p "$BACKUP_DIR/$TIMESTAMP"

CONFIG_FILES=("server.properties" "allowlist.json" "permissions.json")
for f in "${CONFIG_FILES[@]}"; do
    if [ -f "$SERVER_DIR/$f" ]; then
        cp "$SERVER_DIR/$f" "$BACKUP_DIR/$TIMESTAMP/$f"
        log INFO "Backup: $f"
    fi
done

if [ "$BACKUP_WORLDS" = true ]; then
    if [ -d "$SERVER_DIR/worlds" ]; then
        log INFO "Backup direktori worlds (ini mungkin memakan waktu)..."
        cp -r "$SERVER_DIR/worlds" "$BACKUP_DIR/$TIMESTAMP/worlds"
        log INFO "Backup worlds selesai."
    fi
fi

log INFO "Backup tersimpan di: $BACKUP_DIR/$TIMESTAMP"

# -----------------------------------------------------------------------------
# LANGKAH 4: Unduh Binary Baru
# -----------------------------------------------------------------------------
log STEP "Mengunduh Binary Terbaru"

# Hapus zip lama untuk menghemat ruang disk
log INFO "Menghapus installer lama..."
rm -f bedrock-server-*.zip

log INFO "Mengunduh $FILE_NAME..."
if ! wget \
    --show-progress \
    --retry-connrefused \
    --waitretry=5 \
    --tries=3 \
    -O "$FILE_NAME" \
    "$LATEST_URL"; then
    log ERROR "Gagal mengunduh binary. Periksa koneksi internet."
    log INFO "Mengembalikan server ke kondisi sebelumnya..."
    for f in "${CONFIG_FILES[@]}"; do
        [ -f "$BACKUP_DIR/$TIMESTAMP/$f" ] && cp "$BACKUP_DIR/$TIMESTAMP/$f" "$SERVER_DIR/$f"
    done
    exit 1
fi

# Verifikasi file yang diunduh tidak kosong
if [ ! -s "$FILE_NAME" ]; then
    log ERROR "File yang diunduh kosong atau rusak."
    rm -f "$FILE_NAME"
    exit 1
fi

log INFO "Unduhan berhasil: $FILE_NAME ($(du -h "$FILE_NAME" | cut -f1))"

# -----------------------------------------------------------------------------
# LANGKAH 5: Ekstrak dan Pasang
# -----------------------------------------------------------------------------
log STEP "Mengekstrak dan Memasang Pembaruan"

log INFO "Mengekstrak arsip (mode overwrite)..."
if ! unzip -o -q "$FILE_NAME"; then
    log ERROR "Gagal mengekstrak arsip. File mungkin rusak."
    exit 1
fi

# Pulihkan file konfigurasi yang mungkin tertimpa
log INFO "Memulihkan konfigurasi server..."
for f in "${CONFIG_FILES[@]}"; do
    if [ -f "$BACKUP_DIR/$TIMESTAMP/$f" ]; then
        cp "$BACKUP_DIR/$TIMESTAMP/$f" "$SERVER_DIR/$f"
        log INFO "Dipulihkan: $f"
    fi
done

# Set izin eksekusi
chmod +x bedrock_server
log INFO "Izin eksekusi berhasil disetel."

# -----------------------------------------------------------------------------
# LANGKAH 6: Jalankan Ulang Server
# -----------------------------------------------------------------------------
if [ "$NO_RESTART" = true ]; then
    log WARN "Flag --no-restart aktif. Server tidak akan dijalankan ulang secara otomatis."
    log INFO "Jalankan server secara manual dengan:"
    log INFO "  systemctl start bedrock"
else
    log STEP "Menjalankan Ulang Server"
    systemctl start bedrock
    sleep 3

    if is_server_running; then
        log INFO "Server berhasil dihidupkan melalui systemd."
        log INFO "Lihat konsol dengan: screen -r $SCREEN_NAME"
    else
        log ERROR "Server gagal dijalankan. Periksa log dengan:"
        log ERROR "  systemctl status bedrock"
        log ERROR "  journalctl -u bedrock -n 50"
        exit 1
    fi
fi

# -----------------------------------------------------------------------------
# RINGKASAN
# -----------------------------------------------------------------------------
echo -e "\n${GREEN}${BOLD}============================================================"
echo "   Pembaruan Berhasil Diselesaikan!"
echo -e "============================================================${RESET}"
echo -e "  Versi sebelumnya : ${RED}${CURRENT_VERSION}${RESET}"
echo -e "  Versi terpasang  : ${GREEN}${LATEST_VERSION}${RESET}"
echo -e "  Backup tersimpan : ${BACKUP_DIR}/${TIMESTAMP}"
echo -e "  Log tersedia di  : ${LOG_FILE}"
if [ "$NO_RESTART" = false ]; then
    echo -e "  Konsol server    : screen -r ${SCREEN_NAME}"
fi
echo ""
