#!/bin/bash
# =============================================================================
# update_bedrock.sh - Skrip Pembaruan Otomatis Minecraft Bedrock Server
# Repositori: https://github.com/hilmyah/bedrock-server
# =============================================================================
# Deskripsi:
#   Mengunduh dan memasang versi terbaru binary Minecraft Bedrock Server secara
#   otomatis: mendeteksi versi terkini, mengunduh arsip baru selagi server
#   masih berjalan, menghentikan server via systemd, membackup konfigurasi,
#   mengekstrak binary baru, lalu menjalankan kembali server via systemd.
#
# Prasyarat:
#   curl, wget, unzip, screen, systemctl, flock
#
# Hak akses:
#   Jalankan sebagai user pemilik service (tanpa sudo) atau sebagai root.
#   Bila bukan root, hanya 'systemctl stop/start' yang diteruskan lewat sudo.
#   Bila root sementara service milik user biasa, kepemilikan file hasil
#   update dikembalikan ke user tersebut.
#
# Penggunaan:
#   bash update_bedrock.sh [--force] [--no-restart] [--backup-worlds]
#
# Opsi:
#   --force          Paksa update meskipun versi sudah sama
#   --no-restart     Jangan jalankan ulang server setelah update
#   --backup-worlds  Backup direktori worlds sebelum update
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# KONFIGURASI
# -----------------------------------------------------------------------------
# SERVER_DIR, SCREEN_NAME, SERVICE_NAME, SERVICE_USER, BACKUP_DIR, LOCK_FILE
# TIDAK di-hardcode di sini -- diresolusi oleh resolve_config() dengan urutan
# prioritas yang PERSIS SAMA dengan bedrock-manager.sh: env var BEDROCK_* >
# CONF_FILE > introspeksi systemctl > direktori skrip ini berada > default
# bawaan. Ini wajib disamakan; skrip ini bisa dipanggil baik lewat
# 'bedrock update' maupun langsung ('bedrock-update' / 'bash update_bedrock.sh'),
# dan pada instalasi di luar /opt, path hardcode di sini akan salah sasaran
# secara diam-diam.
CONF_FILE="${BEDROCK_CONF_FILE:-/etc/bedrock-manager/manager.conf}"
SELF_PATH=$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "$0")
SELF_DIR=$(dirname "$SELF_PATH")
CURRENT_USER=$(id -un 2>/dev/null || echo "unknown")
# Log update. Bila /var/log tidak dapat ditulisi (dijalankan tanpa root),
# dialihkan ke SERVER_DIR setelah resolve_config (lihat resolve_update_log).
UPDATE_LOG="${BEDROCK_UPDATE_LOG:-/var/log/bedrock-update.log}"

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

    { echo "[$timestamp] [$level] $message" >> "$UPDATE_LOG"; } 2>/dev/null || true
}

unit_prop() {
    systemctl show -p "$1" --value "${SERVICE_NAME}.service" 2>/dev/null || true
}

resolve_config() {
    SERVER_DIR=""; SCREEN_NAME=""; SERVICE_NAME=""; SERVICE_USER=""
    BACKUP_DIR=""; LOCK_FILE=""

    if [ -f "$CONF_FILE" ]; then
        # shellcheck source=/dev/null
        source "$CONF_FILE"
    fi

    [ -z "$SERVICE_NAME" ] && SERVICE_NAME="bedrock"
    [ -n "${BEDROCK_SERVICE_NAME:-}" ] && SERVICE_NAME="$BEDROCK_SERVICE_NAME"

    local execstart
    execstart=$(unit_prop ExecStart)

    if [ -z "$SERVER_DIR" ]; then
        SERVER_DIR=$(unit_prop WorkingDirectory)
        SERVER_DIR="${SERVER_DIR#[-!]}"
    fi
    if [ -z "$SERVER_DIR" ] && [ -e "${SELF_DIR}/bedrock_server" ]; then
        SERVER_DIR="$SELF_DIR"
    fi
    [ -z "$SERVER_DIR" ] && SERVER_DIR="/opt/bedrock-server"
    [ -n "${BEDROCK_SERVER_DIR:-}" ] && SERVER_DIR="$BEDROCK_SERVER_DIR"

    if [ -z "$SCREEN_NAME" ]; then
        SCREEN_NAME=$(echo "$execstart" | grep -oE '\-DmS[[:space:]]+[^[:space:]]+' | awk '{print $2}' || true)
    fi
    [ -z "$SCREEN_NAME" ] && SCREEN_NAME="mc-server"
    [ -n "${BEDROCK_SCREEN_NAME:-}" ] && SCREEN_NAME="$BEDROCK_SCREEN_NAME"

    [ -z "$SERVICE_USER" ] && SERVICE_USER=$(unit_prop User)
    [ -z "$SERVICE_USER" ] && SERVICE_USER="root"
    [ -n "${BEDROCK_SERVICE_USER:-}" ] && SERVICE_USER="$BEDROCK_SERVICE_USER"
    SERVICE_GROUP=$(id -gn "$SERVICE_USER" 2>/dev/null || echo "$SERVICE_USER")

    [ -z "$BACKUP_DIR" ]            && BACKUP_DIR="${SERVER_DIR}-backup"
    [ -n "${BEDROCK_BACKUP_DIR:-}" ] && BACKUP_DIR="$BEDROCK_BACKUP_DIR"

    [ -z "$LOCK_FILE" ]            && LOCK_FILE="${SERVER_DIR}/.bedrock-manager.lock"
    [ -n "${BEDROCK_LOCK_FILE:-}" ] && LOCK_FILE="$BEDROCK_LOCK_FILE"
    return 0
}

resolve_update_log() {
    if { : >> "$UPDATE_LOG"; } 2>/dev/null; then
        return 0
    fi
    UPDATE_LOG="${SERVER_DIR}/bedrock-update.log"
    return 0
}

# systemctl stop/start butuh hak root. Bila dipanggil user biasa, diteruskan
# lewat sudo (meminta password sesuai kebijakan sudoers).
svc_ctl() {
    if [ "$EUID" -eq 0 ]; then
        systemctl "$@"
        return
    fi
    if ! command -v sudo >/dev/null 2>&1; then
        log ERROR "'systemctl $*' butuh hak root dan sudo tidak tersedia."
        return 1
    fi
    sudo systemctl "$@"
}

# Mengembalikan kepemilikan ke user service. Hanya berefek bila skrip jalan
# sebagai root sementara service milik user lain; selain itu no-op.
fix_owner() {
    [ "$EUID" -eq 0 ] || return 0
    [ "$SERVICE_USER" = "root" ] && return 0
    local p
    for p in "$@"; do
        if [ -e "$p" ]; then
            chown -R "${SERVICE_USER}:${SERVICE_GROUP}" "$p"
        fi
    done
    return 0
}

fix_owner_top() {
    [ "$EUID" -eq 0 ] || return 0
    [ "$SERVICE_USER" = "root" ] && return 0
    local p
    for p in "$@"; do
        if [ -e "$p" ]; then
            chown "${SERVICE_USER}:${SERVICE_GROUP}" "$p"
        fi
    done
    return 0
}

# Lock yang SAMA dipakai bedrock-manager.sh (LOCK_FILE identik, lihat
# resolve_config di atas), agar update tidak bisa tumpang tindih dengan
# backup/restore/restart yang dijalankan lewat 'bedrock', dari jalur manapun
# skrip ini dipanggil.
#
# Kasus 'bedrock update': cmd_update() di bedrock-manager.sh sudah memegang
# fd 200 ter-flock pada LOCK_FILE lalu 'exec bash update_bedrock.sh' -- exec
# mewarisi fd tsb ke proses ini. Jika di sini fd 200 langsung ditimpa lewat
# 'exec 200>file', file descriptor lama (dan lock-nya) ikut tertutup sesaat
# sebelum yang baru dibuka -- celah race meski singkat. Maka: kalau fd 200
# sudah terbuka dan menunjuk ke LOCK_FILE yang sama, anggap lock sudah
# dipegang pemanggil, jangan disentuh ulang.
#
# Kasus panggilan langsung ('bedrock-update' / 'bash update_bedrock.sh'):
# fd 200 belum terbuka sama sekali -- lakukan flock -n seperti biasa.
acquire_lock() {
    if [ -e "/proc/$$/fd/200" ]; then
        local held_target want_target
        held_target=$(readlink -f "/proc/$$/fd/200" 2>/dev/null || true)
        want_target=$(readlink -f "$LOCK_FILE" 2>/dev/null || echo "$LOCK_FILE")
        if [ -n "$held_target" ] && [ "$held_target" = "$want_target" ]; then
            log INFO "Lock sudah dipegang oleh proses pemanggil (bedrock update)."
            return 0
        fi
    fi

    mkdir -p "$(dirname "$LOCK_FILE")" 2>/dev/null || true
    if ! { exec 200>>"$LOCK_FILE"; } 2>/dev/null; then
        log ERROR "Tidak dapat membuka file lock: $LOCK_FILE"
        log ERROR "Jalankan sebagai '$SERVICE_USER' atau lewat sudo."
        exit 1
    fi
    fix_owner_top "$LOCK_FILE"
    if ! flock -n 200; then
        log ERROR "Operasi lain (backup/restore/update/restart) sedang berjalan."
        log ERROR "Tunggu sampai selesai, lalu coba lagi."
        log ERROR "Kalau yakin tidak ada proses lain yang berjalan: rm -f $LOCK_FILE"
        exit 1
    fi
}

check_dependencies() {
    local missing=()
    for cmd in curl wget unzip screen systemctl flock; do
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
    systemctl is-active --quiet "$SERVICE_NAME"
}

get_current_version() {
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
        log ERROR "Solusi darurat: unduh bedrock-server-<versi>.zip secara manual ke direktori server, lalu jalankan ulang dengan --force."
        exit 1
    fi

    echo "$url"
}

# -----------------------------------------------------------------------------
# MULAI EKSEKUSI
# -----------------------------------------------------------------------------
echo -e "${BOLD}"
echo "============================================================"
echo "   Minecraft Bedrock Server - Skrip Pembaruan Otomatis"
echo "============================================================"
echo -e "${RESET}"

resolve_config

if [ "$EUID" -ne 0 ] && [ "$CURRENT_USER" != "$SERVICE_USER" ]; then
    log ERROR "Service '$SERVICE_NAME' berjalan sebagai user '$SERVICE_USER', sedangkan Anda '$CURRENT_USER'."
    log ERROR "Jalankan sebagai '$SERVICE_USER' atau lewat sudo."
    exit 1
fi

check_dependencies

if [ ! -d "$SERVER_DIR" ]; then
    log ERROR "Direktori server tidak ditemukan: $SERVER_DIR"
    exit 1
fi

resolve_update_log
acquire_lock

cd "$SERVER_DIR"

# -----------------------------------------------------------------------------
# LANGKAH 1: Deteksi Versi
# -----------------------------------------------------------------------------
log STEP "Memeriksa Versi"
log INFO "Direktori server: ${SERVER_DIR} (user service: ${SERVICE_USER})"

# Jalur darurat: bila seluruh metode deteksi URL gagal, --force memakai arsip
# 'bedrock-server-<versi>.zip' terbaru yang sudah diletakkan manual di
# SERVER_DIR, tanpa mengunduh.
LOCAL_ZIP=""
if ! LATEST_URL=$(fetch_latest_url); then
    LOCAL_ZIP=$( (ls "${SERVER_DIR}"/bedrock-server-*.zip 2>/dev/null | sort -V | tail -n 1) || true )
    if [ "$FORCE_UPDATE" = true ] && [ -n "$LOCAL_ZIP" ]; then
        log WARN "Memakai arsip lokal karena --force aktif: $LOCAL_ZIP"
        LATEST_URL="$LOCAL_ZIP"
    else
        exit 1
    fi
fi
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
# LANGKAH 2: Unduh Binary Baru (server MASIH berjalan)
# -----------------------------------------------------------------------------
# Unduhan dilakukan SEBELUM server dihentikan dan ke nama file sementara.
# Bila unduhan gagal, server tidak pernah berhenti dan arsip versi lama (yang
# menjadi penanda versi terpasang) tidak tersentuh. Nama sementara sengaja
# tidak cocok dengan pola 'bedrock-server-*.zip' agar tidak terbaca sebagai
# versi terpasang oleh get_current_version.
log STEP "Mengunduh Binary Terbaru"

DOWNLOAD_TMP="${SERVER_DIR}/.bedrock-download.part"
rm -f "$DOWNLOAD_TMP"

if [ -n "$LOCAL_ZIP" ]; then
    log INFO "Melewati unduhan, menyalin arsip lokal..."
    cp "$LOCAL_ZIP" "$DOWNLOAD_TMP"
elif ! { log INFO "Mengunduh $FILE_NAME..."; wget \
    --show-progress \
    --retry-connrefused \
    --waitretry=5 \
    --tries=3 \
    -O "$DOWNLOAD_TMP" \
    "$LATEST_URL"; }; then
    log ERROR "Gagal mengunduh binary. Periksa koneksi internet."
    log ERROR "Update DIBATALKAN. Server tidak dihentikan dan tidak ada file yang diubah."
    rm -f "$DOWNLOAD_TMP"
    exit 1
fi

if [ ! -s "$DOWNLOAD_TMP" ] || ! unzip -tq "$DOWNLOAD_TMP" >/dev/null 2>&1; then
    log ERROR "File yang diunduh kosong atau bukan arsip zip yang valid."
    log ERROR "Update DIBATALKAN. Server tidak dihentikan dan tidak ada file yang diubah."
    rm -f "$DOWNLOAD_TMP"
    exit 1
fi

log INFO "Arsip siap dan lolos uji integritas: $FILE_NAME ($(du -h "$DOWNLOAD_TMP" | cut -f1))"

# -----------------------------------------------------------------------------
# LANGKAH 3: Hentikan Server
# -----------------------------------------------------------------------------
log STEP "Menghentikan Server"

if is_server_running; then
    log INFO "Memerintahkan systemd untuk mematikan server secara sinkron..."
    if ! svc_ctl stop "$SERVICE_NAME"; then
        log ERROR "Gagal menghentikan server. Update DIBATALKAN, tidak ada file yang diubah."
        rm -f "$DOWNLOAD_TMP"
        exit 1
    fi
    log INFO "Server berhasil dihentikan."
else
    log INFO "Server tidak sedang berjalan. Melanjutkan pembaruan."
fi

# -----------------------------------------------------------------------------
# LANGKAH 4: Backup
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

fix_owner_top "$BACKUP_DIR"
fix_owner "$BACKUP_DIR/$TIMESTAMP"
log INFO "Backup tersimpan di: $BACKUP_DIR/$TIMESTAMP"

# -----------------------------------------------------------------------------
# LANGKAH 5: Ekstrak dan Pasang
# -----------------------------------------------------------------------------
log STEP "Mengekstrak dan Memasang Pembaruan"

# Arsip versi lama baru dihapus di titik ini, setelah arsip baru terbukti utuh.
rm -f bedrock-server-*.zip
mv "$DOWNLOAD_TMP" "$FILE_NAME"

log INFO "Mengekstrak arsip (mode overwrite)..."
if ! unzip -o -q "$FILE_NAME"; then
    log ERROR "Gagal mengekstrak arsip. Server TIDAK dijalankan kembali."
    log ERROR "Konfigurasi tersimpan di: $BACKUP_DIR/$TIMESTAMP"
    fix_owner "$SERVER_DIR"
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

chmod +x bedrock_server
log INFO "Izin eksekusi berhasil disetel."

# Bila dijalankan sebagai root untuk service milik user biasa, file hasil
# ekstraksi menjadi milik root dan server tidak akan bisa menulisinya.
fix_owner "$SERVER_DIR"

# -----------------------------------------------------------------------------
# LANGKAH 6: Jalankan Ulang Server
# -----------------------------------------------------------------------------
if [ "$NO_RESTART" = true ]; then
    log WARN "Flag --no-restart aktif. Server tidak akan dijalankan ulang secara otomatis."
    log INFO "Jalankan server secara manual dengan:"
    log INFO "  systemctl start $SERVICE_NAME"
else
    log STEP "Menjalankan Ulang Server"
    svc_ctl start "$SERVICE_NAME" || true
    sleep 3

    if is_server_running; then
        log INFO "Server berhasil dihidupkan melalui systemd."
        log INFO "Lihat konsol dengan: screen -r $SCREEN_NAME (sebagai user '$SERVICE_USER')"
    else
        log ERROR "Server gagal dijalankan. Periksa log dengan:"
        log ERROR "  systemctl status $SERVICE_NAME"
        log ERROR "  journalctl -u $SERVICE_NAME -n 50"
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
echo -e "  Log tersedia di  : ${UPDATE_LOG}"
if [ "$NO_RESTART" = false ]; then
    echo -e "  Konsol server    : screen -r ${SCREEN_NAME}"
fi
echo ""