#!/bin/bash
# =============================================================================
# bedrock-manager.sh - Skrip Manajemen Terpadu Minecraft Bedrock Server
# Repositori acuan: https://github.com/hilmyah/bedrock-server
# =============================================================================
# Deskripsi:
#   Skrip kontrol tunggal untuk siklus hidup Bedrock Dedicated Server:
#   start/stop/restart, status, akses konsol, pengiriman perintah in-game,
#   backup independen (TIDAK terikat pada proses update), pemicu update,
#   pemasangan/pengelolaan player activity logger permanen (join/leave),
#   serta pembacaan riwayat pemain.
#
# Sifat universal (tidak terikat lokasi maupun user tertentu):
#   Direktori server, nama screen, user service, dan path log TIDAK di-hardcode.
#   Urutan resolusi: env var BEDROCK_* > manager.conf (opsional) > introspeksi
#   unit systemd (WorkingDirectory, User, ExecStart) > direktori skrip ini
#   berada > default bawaan. Server boleh berada di mana saja (mis. /opt atau
#   ~/projects) dan boleh berjalan sebagai root maupun user biasa.
#
# Hak akses:
#   - Jalankan sebagai user pemilik service (tanpa sudo) atau sebagai root.
#   - start/stop/restart dan backup/restore yang perlu menghentikan server
#     memanggil 'sudo systemctl' bila dijalankan bukan sebagai root.
#   - 'logger install', 'logger uninstall', 'self-install' menulis ke
#     /etc/systemd/system atau /usr/local/bin sehingga wajib lewat sudo.
#   - Bila dijalankan lewat sudo sementara service milik user biasa, perintah
#     screen dijalankan sebagai user tersebut dan file hasil backup/restore
#     dikembalikan kepemilikannya ke user tersebut.
#
# Prasyarat: bash >= 4, systemd, screen, util-linux (flock, runuser, script),
#            coreutils (ps, du, tail, sed, grep)
#
# Instalasi skrip ini sendiri (opsional, agar bisa dipanggil sebagai "bedrock"):
#   sudo bash bedrock-manager.sh self-install
#
# Penggunaan:
#   bedrock-manager.sh <perintah> [opsi]
#
# Daftar perintah:
#   start                       Jalankan server
#   stop                        Hentikan server
#   restart                     Restart server
#   status                      Status service, versi, memori, ukuran worlds, log pemain
#   console                     Lampirkan ke sesi screen (Ctrl+A lalu D untuk keluar)
#   send "<perintah>"           Kirim satu perintah in-game tanpa attach ke console
#   online                      Minta daftar pemain online (kirim "list", baca log)
#   backup [--worlds] [--stop] [--debug]
#                                Backup config (dan opsional worlds) TANPA menjalankan update
#                                 --worlds  : sertakan folder worlds
#                                 --stop    : hentikan server dulu untuk snapshot terjamin
#                                 --debug   : tampilkan output mentah konsol saat live snapshot
#                                 tanpa --stop, jika server berjalan dipakai mekanisme resmi
#                                 "save hold" / "save query" / "save resume" dengan truncation
#                                 per-file sesuai daftar yang dikembalikan server (live snapshot)
#   backup-list                  Daftar seluruh backup yang tersimpan di BACKUP_DIR
#   restore <ts> [--worlds] [--configs]
#                                Pulihkan dari backup bertimestamp <ts> (lihat backup-list).
#                                Tanpa opsi, worlds dan config dipulihkan sekaligus.
#   update [opsi]                Teruskan ke update_bedrock.sh di SERVER_DIR (opsi: --force, dst.)
#   version                      Bandingkan versi terpasang vs terbaru TANPA stop/download
#   logger install                Pasang & aktifkan systemd service player-activity-logger
#   logger uninstall              Copot service logger (file log pemain TIDAK dihapus)
#   logger status                 Status service logger + jumlah entri
#   players [n]                   Tampilkan n baris terakhir player_activity.log (default 50)
#   players today                 Tampilkan aktivitas pemain hari ini
#   players search <nama>         Cari seluruh riwayat satu nama pemain
#   players count                 Jumlah entri & ukuran file log pemain
#   players stats                 Total sesi & lama bermain (join-leave) per pemain
#   logs [n]                      Tampilkan n baris terakhir log mentah server (default 50)
#   self-install                  Symlink skrip ini ke /usr/local/bin/bedrock
#                                 (dan update_bedrock.sh ke /usr/local/bin/bedrock-update)
#   help                          Tampilkan bantuan ini
#
# =============================================================================

set -uo pipefail

# -----------------------------------------------------------------------------
# WARNA OUTPUT
# -----------------------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; RESET='\033[0m'

log() {
    local level="$1"; shift
    case "$level" in
        INFO)  echo -e "${GREEN}[INFO]${RESET}  $*" >&2 ;;
        WARN)  echo -e "${YELLOW}[WARN]${RESET}  $*" >&2 ;;
        ERROR) echo -e "${RED}[ERROR]${RESET} $*" >&2 ;;
        STEP)  echo -e "\n${BOLD}${BLUE}==> $*${RESET}" >&2 ;;
    esac
}

# -----------------------------------------------------------------------------
# RESOLUSI KONFIGURASI (lihat blok "Sifat universal" di header)
# -----------------------------------------------------------------------------
CONF_FILE="${BEDROCK_CONF_FILE:-/etc/bedrock-manager/manager.conf}"
SELF_PATH=$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "$0")
SELF_DIR=$(dirname "$SELF_PATH")
CURRENT_USER=$(id -un 2>/dev/null || echo "unknown")

unit_prop() {
    systemctl show -p "$1" --value "${SERVICE_NAME}.service" 2>/dev/null || true
}

resolve_config() {
    SERVER_DIR=""; SCREEN_NAME=""; SERVICE_NAME=""; SERVICE_USER=""
    LOG_FILE=""; PLAYER_LOG=""; BACKUP_DIR=""; BACKUP_RETAIN=""; LOCK_FILE=""

    if [ -f "$CONF_FILE" ]; then
        # shellcheck source=/dev/null
        source "$CONF_FILE"
    fi

    [ -z "$SERVICE_NAME" ] && SERVICE_NAME="bedrock"
    [ -n "${BEDROCK_SERVICE_NAME:-}" ] && SERVICE_NAME="$BEDROCK_SERVICE_NAME"

    local execstart
    execstart=$(unit_prop ExecStart)

    # Direktori server: unit systemd > direktori tempat skrip ini berada (bila
    # berisi binary server) > default lama. Dengan urutan ini skrip tetap benar
    # setelah direktori server dipindah, selama WorkingDirectory unit ikut diubah.
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
        SCREEN_NAME=$(echo "$execstart" | grep -oE '\-DmS[[:space:]]+[^[:space:]]+' | awk '{print $2}')
    fi
    [ -z "$SCREEN_NAME" ] && SCREEN_NAME="mc-server"
    [ -n "${BEDROCK_SCREEN_NAME:-}" ] && SCREEN_NAME="$BEDROCK_SCREEN_NAME"

    # User yang menjalankan service. Sesi screen hanya terlihat oleh user ini,
    # dan seluruh file di SERVER_DIR harus tetap menjadi miliknya.
    [ -z "$SERVICE_USER" ] && SERVICE_USER=$(unit_prop User)
    [ -z "$SERVICE_USER" ] && SERVICE_USER="root"
    [ -n "${BEDROCK_SERVICE_USER:-}" ] && SERVICE_USER="$BEDROCK_SERVICE_USER"
    SERVICE_GROUP=$(id -gn "$SERVICE_USER" 2>/dev/null || echo "$SERVICE_USER")

    # Log konsol: diambil dari argumen 'tee -a' pada ExecStart bila ada.
    if [ -z "$LOG_FILE" ]; then
        LOG_FILE=$(echo "$execstart" | grep -oE "tee -a[[:space:]]+[^[:space:];']+" | awk '{print $3}' | head -n 1)
    fi
    [ -z "$LOG_FILE" ]      && LOG_FILE="/var/log/bedrock-server.log"
    [ -z "$PLAYER_LOG" ]    && PLAYER_LOG="${SERVER_DIR}/player_activity.log"
    [ -z "$BACKUP_DIR" ]    && BACKUP_DIR="${SERVER_DIR}-backup"
    [ -z "$BACKUP_RETAIN" ] && BACKUP_RETAIN=0
    # Lock disimpan di dalam SERVER_DIR, bukan /var/lock: direktori sticky
    # world-writable seperti /run/lock menolak (fs.protected_regular) pembukaan
    # file milik user lain, termasuk oleh root, sehingga lock yang dibuat user
    # service tidak bisa dipakai bersama pemanggilan lewat sudo dan sebaliknya.
    [ -z "$LOCK_FILE" ]     && LOCK_FILE="${SERVER_DIR}/.bedrock-manager.lock"

    [ -n "${BEDROCK_LOG_FILE:-}" ]      && LOG_FILE="$BEDROCK_LOG_FILE"
    [ -n "${BEDROCK_PLAYER_LOG:-}" ]    && PLAYER_LOG="$BEDROCK_PLAYER_LOG"
    [ -n "${BEDROCK_BACKUP_DIR:-}" ]    && BACKUP_DIR="$BEDROCK_BACKUP_DIR"
    [ -n "${BEDROCK_BACKUP_RETAIN:-}" ] && BACKUP_RETAIN="$BEDROCK_BACKUP_RETAIN"
    [ -n "${BEDROCK_LOCK_FILE:-}" ]     && LOCK_FILE="$BEDROCK_LOCK_FILE"

    UPDATE_SCRIPT="${SERVER_DIR}/update_bedrock.sh"
}

# -----------------------------------------------------------------------------
# UTILITAS
# -----------------------------------------------------------------------------
# Hanya untuk perintah yang menulis ke lokasi sistem (/etc/systemd/system,
# /usr/local/bin). Perintah lain cukup memakai require_operator.
check_root() {
    if [ "$EUID" -ne 0 ]; then
        log ERROR "Perintah ini menulis ke lokasi sistem. Jalankan dengan sudo."
        exit 1
    fi
}

is_service_user() {
    [ "$CURRENT_USER" = "$SERVICE_USER" ]
}

# Operasi yang menyentuh file server atau sesi screen hanya sah untuk user
# pemilik service atau root.
require_operator() {
    if [ "$EUID" -eq 0 ] || is_service_user; then
        return 0
    fi
    log ERROR "Service '$SERVICE_NAME' berjalan sebagai user '$SERVICE_USER', sedangkan Anda '$CURRENT_USER'."
    log ERROR "Jalankan sebagai '$SERVICE_USER' atau lewat sudo."
    exit 1
}

# systemctl start/stop/restart butuh hak root. Bila dipanggil user biasa,
# diteruskan lewat sudo (meminta password sesuai kebijakan sudoers).
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

# Menjalankan perintah sebagai user service. Dipakai untuk screen: socket sesi
# berada di direktori milik user yang menjalankan service, sehingga root pun
# tidak melihat sesi tersebut lewat 'screen -list' biasa.
as_service_user() {
    if is_service_user; then
        "$@"
    elif [ "$EUID" -eq 0 ]; then
        runuser -u "$SERVICE_USER" -- "$@"
    else
        return 1
    fi
}

screen_cmd() {
    as_service_user screen "$@"
}

# Mengembalikan kepemilikan ke user service. Hanya berefek bila skrip jalan
# sebagai root sementara service milik user lain; selain itu no-op.
fix_owner() {
    [ "$EUID" -eq 0 ] || return 0
    [ "$SERVICE_USER" = "root" ] && return 0
    local p
    for p in "$@"; do
        [ -e "$p" ] && chown -R "${SERVICE_USER}:${SERVICE_GROUP}" "$p"
    done
    return 0
}

fix_owner_top() {
    [ "$EUID" -eq 0 ] || return 0
    [ "$SERVICE_USER" = "root" ] && return 0
    local p
    for p in "$@"; do
        [ -e "$p" ] && chown "${SERVICE_USER}:${SERVICE_GROUP}" "$p"
    done
    return 0
}

require_installed() {
    if [ ! -d "$SERVER_DIR" ] || [ ! -x "$SERVER_DIR/bedrock_server" ]; then
        log ERROR "Instalasi server tidak ditemukan di: $SERVER_DIR"
        log ERROR "Periksa WorkingDirectory pada unit ${SERVICE_NAME}.service, atau set BEDROCK_SERVER_DIR."
        exit 1
    fi
}

is_server_running() {
    systemctl is-active --quiet "$SERVICE_NAME"
}

require_running() {
    if ! is_server_running; then
        log ERROR "Server tidak sedang berjalan (service: $SERVICE_NAME)."
        exit 1
    fi
}

screen_exists() {
    screen_cmd -list 2>/dev/null | grep -q "\.${SCREEN_NAME}[[:space:]]"
}

# Mencegah 'backup', 'restore', 'update', dan 'restart' berjalan bersamaan --
# kalau dua di antaranya jalan bareng (misal cron backup vs restore manual di
# terminal lain), keduanya bisa saling menimpa worlds/ atau BACKUP_DIR di
# tengah jalan. fd 200 sengaja dibiarkan terbuka sepanjang hidup proses ini,
# termasuk melewati 'exec bash update_bedrock.sh' pada cmd_update -- exec
# mewarisi file descriptor yang terbuka (sudah diuji empiris: lock tetap
# terpegang sepanjang proses update berjalan, bukan cuma sesaat sebelum
# exec, dan otomatis terlepas begitu proses ini exit dengan cara apa pun).
# 'logs', 'players', 'status' TIDAK memanggil ini karena murni baca.
acquire_lock() {
    mkdir -p "$(dirname "$LOCK_FILE")" 2>/dev/null || true
    # '>>' (bukan '>'): cukup membuka/membuat file tanpa memotong isinya.
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

get_current_version() {
    local zip_file
    zip_file=$( (ls "${SERVER_DIR}"/bedrock-server-*.zip 2>/dev/null | sort -V | tail -n 1) || true )
    if [ -n "$zip_file" ]; then
        basename "$zip_file" .zip | sed 's/bedrock-server-//'
    else
        echo "tidak_diketahui"
    fi
}

fetch_latest_version_string() {
    local url=""
    url=$(curl -sL https://net-secondary.web.minecraft-services.net/api/v1.0/download/links \
        | grep -Eo 'https://[^"]+bin-linux/bedrock-server-[0-9.]+\.zip' | head -n 1 || true)
    if [ -z "$url" ]; then
        url=$(curl -sL https://raw.githubusercontent.com/kittizz/bedrock-server-downloads/main/bedrock-server-downloads.json \
            | grep -Eo 'https://[^"]+bin-linux/bedrock-server-[0-9.]+\.zip' | head -n 1 || true)
    fi
    if [ -z "$url" ]; then
        url=$(curl -Ls -A "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36" \
            -H "Accept-Language: en-US,en;q=0.9" \
            "https://www.minecraft.net/en-us/download/server/bedrock" \
            | sed 's/\\//g' | grep -Eo 'https://[^"'\''\\]+bin-linux/bedrock-server-[0-9.]+\.zip' | head -n 1 || true)
    fi
    [ -n "$url" ] || return 1
    basename "$url" | sed 's/bedrock-server-//;s/\.zip//'
}

cmd_version() {
    require_installed
    local current latest
    current=$(get_current_version)
    log INFO "Memeriksa versi terbaru (tanpa mengunduh/menghentikan server)..."
    latest=$(fetch_latest_version_string) || { log ERROR "Gagal mengambil versi terbaru dari semua metode."; exit 1; }
    echo -e "${BOLD}Versi terpasang :${RESET} $current"
    echo -e "${BOLD}Versi terbaru   :${RESET} $latest"
    if [ "$current" = "$latest" ]; then
        echo -e "${BOLD}Status          :${RESET} ${GREEN}up to date${RESET}"
    else
        echo -e "${BOLD}Status          :${RESET} ${YELLOW}update tersedia${RESET} (jalankan: $(basename "$0") update)"
    fi
}

# -----------------------------------------------------------------------------
# KONTROL SERVICE
# -----------------------------------------------------------------------------
cmd_start() {
    require_installed
    if is_server_running; then
        log WARN "Server sudah berjalan."
        return 0
    fi
    svc_ctl start "$SERVICE_NAME" || { log ERROR "Gagal menjalankan service."; exit 1; }
    log INFO "Perintah start dikirim ke systemd."
}

cmd_stop() {
    if ! is_server_running; then
        log WARN "Server tidak sedang berjalan."
        return 0
    fi
    svc_ctl stop "$SERVICE_NAME" || { log ERROR "Gagal menghentikan service."; exit 1; }
    log INFO "Server dihentikan."
}

cmd_restart() {
    require_operator
    require_installed
    acquire_lock
    svc_ctl restart "$SERVICE_NAME" || { log ERROR "Gagal me-restart service."; exit 1; }
    log INFO "Server di-restart."
}

cmd_status() {
    require_installed
    echo -e "${BOLD}Status service (${SERVICE_NAME}):${RESET}"
    systemctl status "$SERVICE_NAME" --no-pager -l 2>/dev/null | head -n 10
    echo ""
    echo -e "${BOLD}Direktori server :${RESET} $SERVER_DIR"
    echo -e "${BOLD}User service     :${RESET} $SERVICE_USER"
    echo -e "${BOLD}Versi terpasang  :${RESET} $(get_current_version)"

    if is_server_running; then
        local pid
        pid=$(pgrep -f "${SERVER_DIR}/bedrock_server" 2>/dev/null | head -n 1)
        [ -z "$pid" ] && pid=$(pgrep -x bedrock_server 2>/dev/null | head -n 1)
        if [ -n "$pid" ]; then
            local rss
            rss=$(ps -o rss= -p "$pid" 2>/dev/null | awk '{printf "%.1f MB", $1/1024}')
            [ -n "$rss" ] && echo -e "${BOLD}Memori (RSS)     :${RESET} $rss (PID $pid, proses bedrock_server)"
        else
            log WARN "Tidak dapat menemukan PID proses bedrock_server untuk pengukuran memori."
        fi
    fi

    if [ -d "$SERVER_DIR/worlds" ]; then
        echo -e "${BOLD}Ukuran worlds    :${RESET} $(du -sh "$SERVER_DIR/worlds" 2>/dev/null | cut -f1)"
    fi

    if [ -f "$PLAYER_LOG" ]; then
        echo -e "${BOLD}Log pemain       :${RESET} $(wc -l < "$PLAYER_LOG") entri, $(du -h "$PLAYER_LOG" 2>/dev/null | cut -f1)"
    else
        echo -e "${BOLD}Log pemain       :${RESET} belum dipasang (jalankan: logger install)"
    fi
}

cmd_console() {
    require_operator
    require_installed
    if ! screen_exists; then
        log ERROR "Sesi screen '$SCREEN_NAME' milik user '$SERVICE_USER' tidak ditemukan. Server mungkin tidak berjalan."
        exit 1
    fi
    log INFO "Melampirkan ke sesi screen '$SCREEN_NAME'. Keluar tanpa menghentikan server: Ctrl+A lalu D."
    if is_service_user; then
        exec screen -r "$SCREEN_NAME"
    fi
    # Root yang attach ke sesi user lain: terminal saat ini bukan milik user
    # tersebut sehingga screen menolak ("Cannot open your terminal").
    # 'script' membuat pty baru yang dimiliki user service.
    exec runuser -u "$SERVICE_USER" -- script -q -c "screen -r $SCREEN_NAME" /dev/null
}

cmd_send() {
    local cmdtext="${1:-}"
    if [ -z "$cmdtext" ]; then
        log ERROR "Gunakan: $(basename "$0") send \"<perintah in-game>\""
        exit 1
    fi
    require_operator
    require_running
    if ! screen_exists; then
        log ERROR "Sesi screen '$SCREEN_NAME' tidak ditemukan."
        exit 1
    fi
    screen_cmd -S "$SCREEN_NAME" -p 0 -X stuff "${cmdtext}\r"
    log INFO "Perintah terkirim: $cmdtext"
}

cmd_online() {
    require_operator
    require_running
    if ! screen_exists; then
        log ERROR "Sesi screen '$SCREEN_NAME' tidak ditemukan."
        exit 1
    fi
    log INFO "Mengirim perintah 'list' dan membaca respons dari log..."
    screen_cmd -S "$SCREEN_NAME" -p 0 -X stuff "list\r"
    sleep 2
    local result
    result=$(tail -n 30 "$LOG_FILE" 2>/dev/null | grep "There are" | tail -n 1)
    if [ -z "$result" ]; then
        log WARN "Tidak menemukan respons 'list' pada log dalam jendela waktu ini."
        log WARN "Coba jalankan ulang, atau periksa manual: tail -n 50 $LOG_FILE"
        exit 1
    fi
    echo "$result"
}


live_backup_worlds() {
    local dest="$1" debug="${2:-false}"
    mkdir -p "$dest"

    local hold_issued=false
    resume_if_held() {
        if [ "$hold_issued" = true ]; then
            screen_cmd -S "$SCREEN_NAME" -p 0 -X stuff "save resume$(printf '\r')" 2>/dev/null || true
            hold_issued=false
        fi
    }
    trap resume_if_held RETURN

    log INFO "Mengirim 'save hold' ke konsol server..."
    screen_cmd -S "$SCREEN_NAME" -p 0 -X stuff "save hold$(printf '\r')"
    hold_issued=true

    local attempt=0 max_attempts=24 interval=5
    local query_output="" file_list=""

    while [ "$attempt" -lt "$max_attempts" ]; do
        sleep "$interval"
        screen_cmd -S "$SCREEN_NAME" -p 0 -X stuff "save query$(printf '\r')"
        sleep 1
        query_output=$(tail -n 20 "$LOG_FILE" 2>/dev/null || true)

        if [ "$debug" = true ]; then
            log INFO "[debug] output konsol terbaru:
$query_output"
        fi

        if echo "$query_output" | grep -q "Data saved."; then
            # Daftar file berbentuk 'path:panjang_byte' dipisah koma. Parser
            # sengaja toleran terhadap variasi antar versi server:
            #   - pemisah ',' maupun ', ' (spasi di-trim per entri, BUKAN
            #     dipakai sebagai pemisah: level-name default "Bedrock level"
            #     sendiri mengandung spasi),
            #   - path diawali 'worlds/' maupun langsung nama level,
            #   - daftar berada di baris sendiri maupun menyambung setelah
            #     kalimat "Files are now ready to be copied.".
            # Hanya baris sejak "Data saved." TERAKHIR yang dipertimbangkan,
            # agar baris log lain di jendela tail tidak salah terbaca.
            file_list=$(echo "$query_output" \
                | awk '/Data saved\./{buf=""} {buf=buf $0 "\n"} END{printf "%s", buf}' \
                | grep -E '/[^,]*:[0-9]+' | tail -n 1 \
                | sed -E 's/.*ready to be copied\.?[[:space:]]*//; s/^\[[^]]*\][[:space:]]*//')
            [ -n "$file_list" ] && break
        fi
        attempt=$((attempt + 1))
        log INFO "Menunggu server siap untuk backup (percobaan $attempt/$max_attempts)..."
    done

    if [ -z "$file_list" ]; then
        log ERROR "Timeout menunggu respons 'save query' yang valid. Backup live worlds dibatalkan."
        log ERROR "Jalankan dengan --debug untuk memeriksa output mentah konsol."
        log ERROR "Alternatif terjamin: backup --worlds --stop"
        return 1
    fi

    log INFO "Menyalin file world sesuai daftar dari 'save query' (dengan truncation)..."
    local count=0 skipped=0
    IFS=',' read -ra entries <<< "$file_list"
    for entry in "${entries[@]}"; do
        entry=$(echo "$entry" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [ -z "$entry" ] && continue
        local rel_path="${entry%:*}"
        local length="${entry##*:}"
        if ! [[ "$length" =~ ^[0-9]+$ ]]; then
            log WARN "Melewati entri tidak sesuai format: $entry"
            skipped=$((skipped + 1))
            continue
        fi
        # Normalisasi: path tujuan selalu relatif terhadap worlds/ ('dest'
        # sudah menunjuk ke <backup>/worlds), apa pun bentuk path dari server.
        rel_path="${rel_path#worlds/}"
        local src="${SERVER_DIR}/worlds/${rel_path}"
        local dst="${dest}/${rel_path}"
        if [ -f "$src" ]; then
            mkdir -p "$(dirname "$dst")"
            if head -c "$length" "$src" > "$dst"; then
                count=$((count + 1))
            else
                log WARN "Gagal menyalin: $src"
                skipped=$((skipped + 1))
            fi
        else
            log WARN "File sumber tidak ditemukan, dilewati: $src"
            skipped=$((skipped + 1))
        fi
    done
    log INFO "Backup worlds live selesai. File disalin: $count, dilewati: $skipped"

    trap - RETURN
    resume_if_held
    # Satu entri saja yang gagal berarti snapshot tidak utuh: dianggap GAGAL,
    # bukan dilaporkan sukses dengan isi sebagian.
    if [ "$skipped" -gt 0 ]; then
        log ERROR "$skipped entri dari daftar 'save query' tidak dapat disalin."
        return 1
    fi
    [ "$count" -gt 0 ]
}

# -----------------------------------------------------------------------------
# BACKUP (independen dari update)
# -----------------------------------------------------------------------------
# PERBAIKAN (atomik): versi sebelumnya menulis langsung ke $BACKUP_DIR/$ts dan,
# kalau live_backup_worlds gagal, hanya mencatat WARN lalu tetap melanjutkan
# sampai "Backup tersimpan di: ..." - folder gagal-sebagian itu terlihat sah
# di 'backup-list' padahal isinya tidak lengkap. Sekarang seluruh proses
# ditulis ke direktori sementara (.tmp-<ts>), diverifikasi (config ada & tidak
# kosong, worlds berisi minimal satu file jika diminta), dan HANYA di-rename
# ke nama final bertimestamp kalau semua tahap lolos. Kalau gagal di titik
# manapun, direktori sementara dihapus lewat trap EXIT (bukan RETURN - exit
# tidak memicu RETURN, sudah diuji) sehingga tidak pernah ada folder setengah
# jadi yang tampak seperti backup sukses.
cmd_backup() {
    require_operator
    require_installed
    acquire_lock

    local include_worlds=false
    local safe_stop=false
    local debug=false
    for arg in "$@"; do
        case "$arg" in
            --worlds) include_worlds=true ;;
            --stop)   safe_stop=true ;;
            --debug)  debug=true ;;
            *) log ERROR "Opsi backup tidak dikenal: $arg"; exit 1 ;;
        esac
    done

    if ! mkdir -p "$BACKUP_DIR"; then
        log ERROR "Tidak dapat membuat direktori backup: $BACKUP_DIR"
        exit 1
    fi
    fix_owner_top "$BACKUP_DIR"
    local ts tmp_dest final_dest
    ts=$(date '+%Y%m%d_%H%M%S')
    tmp_dest="$BACKUP_DIR/.tmp-${ts}"
    final_dest="$BACKUP_DIR/${ts}"

    # Bersihkan sisa temp dari proses sebelumnya yang mungkin pernah crash
    # (kill -9, mati listrik, dll.) sebelum sempat membersihkan diri sendiri.
    rm -rf "$tmp_dest"
    mkdir -p "$tmp_dest"

    local backup_ok=false
    cleanup_tmp_backup() {
        if [ "$backup_ok" != true ] && [ -d "$tmp_dest" ]; then
            log WARN "Backup dibatalkan/gagal - menghapus direktori sementara: $tmp_dest"
            rm -rf "$tmp_dest"
        fi
    }
    trap cleanup_tmp_backup EXIT

    log STEP "Membuat Backup (tanpa menjalankan update)"

    local expected_configs=() copied_configs=()
    for f in server.properties allowlist.json permissions.json; do
        if [ -f "$SERVER_DIR/$f" ]; then
            expected_configs+=("$f")
            if cp "$SERVER_DIR/$f" "$tmp_dest/$f"; then
                copied_configs+=("$f")
                log INFO "Backup: $f"
            else
                log ERROR "Gagal menyalin: $f"
            fi
        fi
    done

    if [ "${#expected_configs[@]}" -gt 0 ] && [ "${#copied_configs[@]}" -ne "${#expected_configs[@]}" ]; then
        log ERROR "Backup config tidak lengkap (${#copied_configs[@]}/${#expected_configs[@]} berhasil disalin)."
        exit 1
    fi

    local worlds_failed=false
    if [ "$include_worlds" = true ]; then
        if [ ! -d "$SERVER_DIR/worlds" ]; then
            log WARN "Direktori worlds tidak ditemukan, dilewati."
        elif [ "$safe_stop" = true ]; then
            log INFO "Mode --stop aktif: menghentikan server untuk snapshot terjamin konsisten."
            local was_running=false
            is_server_running && was_running=true
            if [ "$was_running" = true ] && ! svc_ctl stop "$SERVICE_NAME"; then
                log ERROR "Gagal menghentikan server. Backup DIBATALKAN, tidak ada yang diubah."
                exit 1
            fi
            cp -r "$SERVER_DIR/worlds" "$tmp_dest/worlds"
            if [ "$was_running" = true ] && ! svc_ctl start "$SERVICE_NAME"; then
                log ERROR "Server GAGAL dijalankan kembali. Jalankan manual: $(basename "$0") start"
            fi
            log INFO "Backup worlds (mode stop) selesai."
        elif is_server_running && screen_exists; then
            if ! live_backup_worlds "$tmp_dest/worlds" "$debug"; then
                worlds_failed=true
                log ERROR "Live backup worlds gagal."
            fi
        else
            cp -r "$SERVER_DIR/worlds" "$tmp_dest/worlds"
            log INFO "Server tidak berjalan, worlds disalin langsung."
        fi
    fi

    if [ "$worlds_failed" = true ]; then
        log ERROR "Backup DIBATALKAN karena live backup worlds gagal. Alternatif terjamin: backup --worlds --stop"
        exit 1
    fi

    # Verifikasi akhir sebelum dianggap sukses.
    local verify_failed=false
    local f
    for f in "${expected_configs[@]}"; do
        if [ ! -s "$tmp_dest/$f" ]; then
            log ERROR "Verifikasi gagal: $f tidak ada atau kosong pada hasil backup."
            verify_failed=true
        fi
    done
    if [ "$include_worlds" = true ] && [ -d "$SERVER_DIR/worlds" ]; then
        local file_count
        file_count=$(find "$tmp_dest/worlds" -type f 2>/dev/null | wc -l)
        if [ "$file_count" -eq 0 ]; then
            log ERROR "Verifikasi gagal: folder worlds pada hasil backup kosong."
            verify_failed=true
        fi
    fi
    if [ "$verify_failed" = true ]; then
        log ERROR "Backup tidak lolos verifikasi. Backup DIBATALKAN."
        exit 1
    fi

    # Semua tahap lolos -> pindahkan dari temp ke nama final bertimestamp.
    # 'mv' dalam satu filesystem bersifat atomik (rename syscall), jadi tidak
    # pernah ada jendela waktu di mana nama final ada tapi isinya setengah jadi.
    mv "$tmp_dest" "$final_dest"
    fix_owner "$final_dest"
    backup_ok=true
    trap - EXIT

    log INFO "Backup tersimpan di: $final_dest"
    prune_backups
}

prune_backups() {
    [ "$BACKUP_RETAIN" -gt 0 ] 2>/dev/null || return 0
    [ -d "$BACKUP_DIR" ] || return 0
    local count
    count=$(find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d | wc -l)
    if [ "$count" -gt "$BACKUP_RETAIN" ]; then
        find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d | sort | head -n "$((count - BACKUP_RETAIN))" \
        | while IFS= read -r d; do
            log INFO "Menghapus backup lama (melebihi BEDROCK_BACKUP_RETAIN=$BACKUP_RETAIN): $d"
            rm -rf "$d"
        done
    fi
}

cmd_backup_list() {
    require_installed
    if [ ! -d "$BACKUP_DIR" ] || [ -z "$(ls -A "$BACKUP_DIR" 2>/dev/null)" ]; then
        log INFO "Belum ada backup di: $BACKUP_DIR"
        return 0
    fi
    printf "%-20s %-10s %s\n" "TIMESTAMP" "UKURAN" "ISI"
    local d
    for d in "$BACKUP_DIR"/*/; do
        [ -d "$d" ] || continue
        printf "%-20s %-10s %s\n" \
            "$(basename "$d")" \
            "$(du -sh "$d" 2>/dev/null | cut -f1)" \
            "$(ls "$d" 2>/dev/null | tr '\n' ',' | sed 's/,$//')"
    done
}

# PERBAIKAN (atomik + rollback lokal): versi sebelumnya melakukan
# `rm -rf worlds` LEBIH DULU baru `cp -r` data restore. Kalau cp gagal di
# tengah jalan (disk penuh, terhenti paksa), world lama sudah hilang dan
# yang tersisa cuma salinan setengah jadi. Sekarang data restore disalin ke
# staging dulu (worlds/ asli sama sekali tidak disentuh selama proses ini),
# diverifikasi tidak kosong, baru DITUKAR lewat dua 'mv' (operasi rename,
# bukan copy - sangat singkat, risiko gagal di tengah jalan jauh lebih
# kecil dibanding menyalin ratusan MB data). worlds/ lama TIDAK dihapus,
# hanya di-rename ke worlds.before-restore-<timestamp> sebagai rollback
# lokal manual kalau ternyata restore yang dipilih salah.
restore_worlds_atomic() {
    local src="$1" ts="$2"
    local worlds_dir="${SERVER_DIR}/worlds"
    local staging="${SERVER_DIR}/.worlds-restore-staging"
    local safety="${SERVER_DIR}/worlds.before-restore-${ts}"

    log STEP "Restore Worlds dari $ts"

    rm -rf "$staging"
    if ! cp -r "${src}/worlds" "$staging"; then
        log ERROR "Gagal menyalin data worlds dari backup ke staging."
        log ERROR "Restore DIBATALKAN - worlds/ yang sedang aktif tidak diubah sama sekali."
        rm -rf "$staging"
        return 1
    fi

    local file_count
    file_count=$(find "$staging" -type f 2>/dev/null | wc -l)
    if [ "$file_count" -eq 0 ]; then
        log ERROR "Verifikasi gagal: hasil salinan staging kosong."
        log ERROR "Restore DIBATALKAN - worlds/ yang sedang aktif tidak diubah sama sekali."
        rm -rf "$staging"
        return 1
    fi

    local was_running=false
    is_server_running && was_running=true
    if [ "$was_running" = true ] && ! svc_ctl stop "$SERVICE_NAME"; then
        log ERROR "Gagal menghentikan server."
        log ERROR "Restore DIBATALKAN, worlds/ yang sedang aktif tidak diubah sama sekali."
        rm -rf "$staging"
        return 1
    fi

    if [ -d "$worlds_dir" ]; then
        rm -rf "$safety"
        mv "$worlds_dir" "$safety"
    fi
    mv "$staging" "$worlds_dir"
    fix_owner "$worlds_dir"

    log INFO "Worlds dipulihkan dari: $src"
    if [ -d "$safety" ]; then
        log INFO "Worlds sebelumnya diamankan di: $safety"
        log INFO "Hapus manual setelah yakin restore ini benar: rm -rf $safety"
    fi

    if [ "$was_running" = true ] && ! svc_ctl start "$SERVICE_NAME"; then
        log ERROR "Server GAGAL dijalankan kembali. Jalankan manual: $(basename "$0") start"
    fi
    return 0
}

# Config kecil (3 file), risiko gagal-di-tengah jauh lebih rendah dibanding
# worlds, tapi tetap diberi jaring pengaman: versi yang sedang aktif disalin
# ke .config-before-restore-<timestamp> sebelum ditimpa, dan setiap kegagalan
# 'cp' sekarang eksplisit dilaporkan (versi lama diam-diam melanjutkan meski
# salah satu file gagal disalin).
restore_configs_atomic() {
    local src="$1" ts="$2"
    local safety_dir="${SERVER_DIR}/.config-before-restore-${ts}"
    local restored=0 failed=0
    local f

    log STEP "Restore Konfigurasi dari $ts"

    for f in server.properties allowlist.json permissions.json; do
        if [ -f "${src}/${f}" ]; then
            if [ -f "${SERVER_DIR}/${f}" ]; then
                mkdir -p "$safety_dir"
                cp "${SERVER_DIR}/${f}" "$safety_dir/${f}" 2>/dev/null || true
            fi
            if cp "${src}/${f}" "${SERVER_DIR}/${f}"; then
                fix_owner_top "${SERVER_DIR}/${f}"
                log INFO "Dipulihkan: $f"
                restored=$((restored + 1))
            else
                log ERROR "Gagal memulihkan: $f"
                failed=$((failed + 1))
            fi
        fi
    done

    if [ "$failed" -gt 0 ]; then
        log ERROR "$failed config gagal dipulihkan - periksa manual."
    fi
    if [ -d "$safety_dir" ]; then
        fix_owner "$safety_dir"
        log INFO "Config sebelumnya diamankan di: $safety_dir"
    fi

    if is_server_running && screen_exists; then
        screen_cmd -S "$SCREEN_NAME" -p 0 -X stuff "whitelist reload$(printf '\r')" 2>/dev/null || true
        screen_cmd -S "$SCREEN_NAME" -p 0 -X stuff "permissions reload$(printf '\r')" 2>/dev/null || true
        log INFO "allowlist/permissions dimuat ulang tanpa restart (whitelist reload, permissions reload)."
    fi

    [ "$failed" -eq 0 ]
}

cmd_restore() {
    require_operator
    require_installed
    acquire_lock
    local ts="${1:-}"; shift || true
    if [ -z "$ts" ]; then
        log ERROR "Gunakan: $(basename "$0") restore <timestamp> [--worlds] [--configs]"
        log ERROR "Lihat timestamp yang tersedia dengan: $(basename "$0") backup-list"
        exit 1
    fi
    local src="$BACKUP_DIR/$ts"
    [ -d "$src" ] || { log ERROR "Backup tidak ditemukan: $src"; exit 1; }

    local do_worlds=false do_configs=false
    for arg in "$@"; do
        case "$arg" in
            --worlds)  do_worlds=true ;;
            --configs) do_configs=true ;;
            *) log ERROR "Opsi restore tidak dikenal: $arg"; exit 1 ;;
        esac
    done
    if [ "$do_worlds" = false ] && [ "$do_configs" = false ]; then
        do_worlds=true; do_configs=true
    fi

    local restore_ts
    restore_ts=$(date '+%Y%m%d_%H%M%S')

    if [ "$do_worlds" = true ]; then
        if [ ! -d "${src}/worlds" ]; then
            log WARN "Backup ini tidak memiliki data worlds, dilewati."
        else
            restore_worlds_atomic "$src" "$restore_ts" || exit 1
        fi
    fi

    if [ "$do_configs" = true ]; then
        restore_configs_atomic "$src" "$restore_ts"
    fi
}

# -----------------------------------------------------------------------------
# UPDATE (meneruskan ke update_bedrock.sh yang sudah ada)
# -----------------------------------------------------------------------------
cmd_update() {
    require_operator
    require_installed
    acquire_lock
    if [ ! -x "$UPDATE_SCRIPT" ]; then
        log ERROR "Skrip update tidak ditemukan atau tidak executable: $UPDATE_SCRIPT"
        exit 1
    fi
    exec bash "$UPDATE_SCRIPT" "$@"
}

# -----------------------------------------------------------------------------
# PLAYER ACTIVITY LOGGER (permanen, hanya reset jika file dihapus manual)
# -----------------------------------------------------------------------------
logger_install() {
    check_root
    require_installed

    local logger_script="${SERVER_DIR}/player-logger.sh"
    local unit_file="/etc/systemd/system/bedrock-player-logger.service"

    log STEP "Memasang Player Activity Logger"

    cat > "$logger_script" << 'SCRIPT_EOF'
#!/bin/bash
set -uo pipefail

LOG_FILE="${BEDROCK_LOG_FILE:-/var/log/bedrock-server.log}"
PLAYER_LOG="${BEDROCK_PLAYER_LOG:-$(dirname "$(readlink -f "$0")")/player_activity.log}"

mkdir -p "$(dirname "$PLAYER_LOG")"
touch "$PLAYER_LOG"

while [ ! -f "$LOG_FILE" ]; do
    sleep 2
done

tail -n 0 -F "$LOG_FILE" 2>/dev/null | while IFS= read -r line; do
    if echo "$line" | grep -q "Player connected:"; then
        name=$(echo "$line" | sed -nE 's/.*Player connected: ([^,]+),.*/\1/p')
        xuid=$(echo "$line" | sed -nE 's/.*xuid:[[:space:]]*([0-9]+).*/\1/p')
        [ -n "$name" ] && echo "$(date '+%Y-%m-%d %H:%M:%S')|JOIN|${name}|${xuid:-unknown}" >> "$PLAYER_LOG"
    elif echo "$line" | grep -q "Player disconnected:"; then
        name=$(echo "$line" | sed -nE 's/.*Player disconnected: ([^,]+),.*/\1/p')
        xuid=$(echo "$line" | sed -nE 's/.*xuid:[[:space:]]*([0-9]+).*/\1/p')
        [ -n "$name" ] && echo "$(date '+%Y-%m-%d %H:%M:%S')|LEAVE|${name}|${xuid:-unknown}" >> "$PLAYER_LOG"
    fi
done
SCRIPT_EOF

    chmod +x "$logger_script"
    touch "$PLAYER_LOG"
    fix_owner_top "$logger_script" "$PLAYER_LOG"
    log INFO "Skrip logger dipasang: $logger_script"

    cat > "$unit_file" << EOF
[Unit]
Description=Bedrock Player Activity Logger (join/leave permanen)
After=network.target ${SERVICE_NAME}.service
Wants=${SERVICE_NAME}.service

[Service]
Type=simple
User=${SERVICE_USER}
Environment=BEDROCK_LOG_FILE=${LOG_FILE}
Environment=BEDROCK_PLAYER_LOG=${PLAYER_LOG}
ExecStart=/bin/bash ${logger_script}
Restart=always
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
    # Eksplisit 644: dengan umask 002, file akan group-writable dan memicu
    # peringatan systemd.
    chmod 644 "$unit_file"

    systemctl daemon-reload
    systemctl enable bedrock-player-logger.service
    systemctl restart bedrock-player-logger.service

    log INFO "Service aktif: bedrock-player-logger (berjalan sebagai user '$SERVICE_USER')"
    log INFO "File log pemain (permanen): $PLAYER_LOG"
    log INFO "Retensi: tidak ada batas waktu. Hanya reset jika file ini dihapus manual."
}

logger_uninstall() {
    check_root
    systemctl stop bedrock-player-logger.service 2>/dev/null || true
    systemctl disable bedrock-player-logger.service 2>/dev/null || true
    rm -f /etc/systemd/system/bedrock-player-logger.service
    systemctl daemon-reload
    log INFO "Service bedrock-player-logger dicopot."
    log INFO "File data ($PLAYER_LOG) TIDAK dihapus. Hapus manual jika ingin reset."
}

logger_status() {
    systemctl status bedrock-player-logger.service --no-pager -l 2>/dev/null || log WARN "Service belum terpasang."
    if [ -f "$PLAYER_LOG" ]; then
        echo ""
        echo -e "${BOLD}Total entri:${RESET} $(wc -l < "$PLAYER_LOG")"
        echo -e "${BOLD}Ukuran file:${RESET} $(du -h "$PLAYER_LOG" | cut -f1)"
        echo -e "${BOLD}5 entri terakhir:${RESET}"
        tail -n 5 "$PLAYER_LOG"
    fi
}

cmd_logger() {
    local sub="${1:-}"
    shift || true
    case "$sub" in
        install)   logger_install ;;
        uninstall) logger_uninstall ;;
        status)    logger_status ;;
        *)
            log ERROR "Gunakan: $(basename "$0") logger {install|uninstall|status}"
            exit 1
            ;;
    esac
}

# -----------------------------------------------------------------------------
# PEMBACAAN RIWAYAT PEMAIN
# -----------------------------------------------------------------------------
cmd_players() {
    local sub="${1:-recent}"
    if [ ! -f "$PLAYER_LOG" ]; then
        log ERROR "File log pemain belum ada. Jalankan: $(basename "$0") logger install"
        exit 1
    fi

    case "$sub" in
        recent)
            local n="${2:-50}"
            tail -n "$n" "$PLAYER_LOG"
            ;;
        today)
            grep "^$(date '+%Y-%m-%d')" "$PLAYER_LOG" || log INFO "Belum ada aktivitas hari ini."
            ;;
        search)
            local name="${2:-}"
            if [ -z "$name" ]; then
                log ERROR "Gunakan: $(basename "$0") players search <nama>"
                exit 1
            fi
            grep -i "|${name}|" "$PLAYER_LOG" || log INFO "Tidak ditemukan riwayat untuk: $name"
            ;;
        count)
            echo -e "${BOLD}Total entri:${RESET} $(wc -l < "$PLAYER_LOG")"
            echo -e "${BOLD}Ukuran file:${RESET} $(du -h "$PLAYER_LOG" | cut -f1)"
            ;;
        stats)
            # Key: XUID (nama bisa berubah, XUID tetap). Nama yang ditampilkan
            # adalah nama terakhir yang tercatat untuk XUID tsb. Entri dengan
            # xuid "unknown" (gagal diekstrak logger) ikut tergabung jadi satu
            # baris "unknown" -- kasus langka, bukan bug baru.
            printf "%-24s %-20s %-8s %s\n" "PEMAIN" "XUID" "SESI" "TOTAL_WAKTU"
            awk -F'|' '
                function days_from_civil(y, m, d,    era, yoe, doy) {
                    if (m <= 2) y -= 1
                    era = int((y >= 0 ? y : y - 399) / 400)
                    yoe = y - era * 400
                    doy = int((153 * (m + (m > 2 ? -3 : 9)) + 2) / 5) + d - 1
                    return era * 146097 + (yoe * 365 + int(yoe/4) - int(yoe/100) + doy) - 719468
                }
                function to_epoch(ts,    a, y, mo, d, h, mi, s) {
                    split(ts, a, "[- :]")
                    y = a[1]; mo = a[2]; d = a[3]; h = a[4]; mi = a[5]; s = a[6]
                    return days_from_civil(y, mo, d) * 86400 + h * 3600 + mi * 60 + s
                }
                $2=="JOIN" {
                    in_time[$4] = to_epoch($1)
                    sesi[$4]++
                    name[$4] = $3
                }
                $2=="LEAVE" && ($4 in in_time) {
                    total[$4] += (to_epoch($1) - in_time[$4])
                    delete in_time[$4]
                    name[$4] = $3
                }
                END {
                    for (x in sesi) {
                        d = total[x] + 0
                        printf "%-24s %-20s %-8d %02d:%02d:%02d\n", name[x], x, sesi[x], int(d/3600), int((d%3600)/60), int(d%60)
                    }
                }
            ' "$PLAYER_LOG" | sort -k3 -rn
            ;;
        *)
            local n="$sub"
            if [[ "$n" =~ ^[0-9]+$ ]]; then
                tail -n "$n" "$PLAYER_LOG"
            else
                log ERROR "Subperintah players tidak dikenal: $sub"
                exit 1
            fi
            ;;
    esac
}

cmd_logs() {
    local n="${1:-50}"
    if [ ! -f "$LOG_FILE" ]; then
        log ERROR "Log server tidak ditemukan: $LOG_FILE"
        exit 1
    fi
    tail -n "$n" "$LOG_FILE"
}

# -----------------------------------------------------------------------------
# SELF-INSTALL
# -----------------------------------------------------------------------------
cmd_selfinstall() {
    check_root
    local target="/usr/local/bin/bedrock"
    ln -sfn "$SELF_PATH" "$target"
    chmod +x "$SELF_PATH"
    log INFO "Symlink dibuat: $target -> $SELF_PATH"
    if [ -f "${SELF_DIR}/update_bedrock.sh" ]; then
        chmod +x "${SELF_DIR}/update_bedrock.sh"
        ln -sfn "${SELF_DIR}/update_bedrock.sh" /usr/local/bin/bedrock-update
        log INFO "Symlink dibuat: /usr/local/bin/bedrock-update -> ${SELF_DIR}/update_bedrock.sh"
    fi
    log INFO "Panggil dari mana saja dengan: bedrock <perintah>"
    log INFO "Setelah direktori server dipindah, jalankan ulang perintah ini dari lokasi baru."
}

# -----------------------------------------------------------------------------
# BANTUAN
# -----------------------------------------------------------------------------
print_help() {
    local last_line
    last_line=$(awk '
        NR==1 { next }
        /^#/  { if ($0 ~ /^# ====/) last=NR; next }
        /^$/  { next }
        { exit }
        END   { print last+0 }
    ' "$0")
    [ "$last_line" -gt 0 ] 2>/dev/null || last_line=1
    sed -n "2,${last_line}p" "$0" | sed 's/^# \?//'
}

# -----------------------------------------------------------------------------
# DISPATCHER
# -----------------------------------------------------------------------------
main() {
    resolve_config
    local command="${1:-help}"
    shift || true

    case "$command" in
        start)        cmd_start ;;
        stop)         cmd_stop ;;
        restart)      cmd_restart ;;
        status)       cmd_status ;;
        console)      cmd_console ;;
        send)         cmd_send "$@" ;;
        online)       cmd_online ;;
        backup)       cmd_backup "$@" ;;
        backup-list)  cmd_backup_list ;;
        restore)      cmd_restore "$@" ;;
        update)       cmd_update "$@" ;;
        version)      cmd_version ;;
        logger)       cmd_logger "$@" ;;
        players)      cmd_players "$@" ;;
        logs)         cmd_logs "$@" ;;
        self-install) cmd_selfinstall ;;
        _print-config)
            echo "CONF_FILE      = $CONF_FILE"
            echo "SERVICE_NAME   = $SERVICE_NAME"
            echo "SERVER_DIR     = $SERVER_DIR"
            echo "SCREEN_NAME    = $SCREEN_NAME"
            echo "SERVICE_USER   = $SERVICE_USER (grup: $SERVICE_GROUP)"
            echo "CURRENT_USER   = $CURRENT_USER"
            echo "LOG_FILE       = $LOG_FILE"
            echo "PLAYER_LOG     = $PLAYER_LOG"
            echo "BACKUP_DIR     = $BACKUP_DIR"
            echo "BACKUP_RETAIN  = $BACKUP_RETAIN"
            echo "LOCK_FILE      = $LOCK_FILE"
            ;;
        _test-lock-hold)
            # Perintah tersembunyi untuk diagnosis: memegang lock lewat
            # acquire_lock() -- fungsi PERSIS yang sama dipakai backup/
            # restore/update/restart -- selama N detik (default 5), lalu
            # keluar. Berguna untuk menguji locking tanpa perlu memicu
            # backup/restore/update sungguhan atau menebak-nebak waktu I/O.
            local hold="${1:-5}"
            acquire_lock
            echo "LOCK_HELD_PID=$$"
            sleep "$hold"
            echo "LOCK_RELEASING"
            ;;
        help|-h|--help) print_help ;;
        *)
            log ERROR "Perintah tidak dikenal: $command"
            print_help
            exit 1
            ;;
    esac
}

main "$@"