#!/bin/bash
# =============================================================================
# bedrock-manager.sh — Skrip Manajemen Terpadu Minecraft Bedrock Server
# Repositori acuan: https://github.com/hilmyah/bedrock-server
# =============================================================================
# Deskripsi:
#   Skrip kontrol tunggal untuk siklus hidup Bedrock Dedicated Server:
#   start/stop/restart, status, akses konsol, pengiriman perintah in-game,
#   backup independen (TIDAK terikat pada proses update), pemicu update,
#   pemasangan/pengelolaan player activity logger permanen (join/leave),
#   serta pembacaan riwayat pemain.
#
# Sifat "universal":
#   Skrip TIDAK meng-hardcode path. Resolusi konfigurasi mengikuti urutan:
#     1. Environment variable (BEDROCK_SERVER_DIR, BEDROCK_SCREEN_NAME, dst.)
#     2. File konfigurasi opsional /etc/bedrock-manager/manager.conf
#     3. Introspeksi unit systemd yang sedang terpasang (systemctl show)
#     4. Nilai default (/opt/bedrock-server, screen "mc-server", service "bedrock")
#   Karena itu skrip ini dapat dijalankan di server manapun yang memakai
#   pola instalasi install.sh dari repositori acuan, tanpa modifikasi.
#
# Prasyarat: bash >= 4, systemd, screen, coreutils (ps, du, tail, sed, grep)
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
#   help                          Tampilkan bantuan ini
#
# Catatan penting (bukan asumsi tersembunyi, dinyatakan eksplisit):
#   - Bedrock Dedicated Server tidak memiliki RCON bawaan. Perintah "online"
#     dan "send" bekerja dengan mengirim teks ke sesi screen server, BUKAN
#     melalui protokol terstruktur. Jika screen session tidak ditemukan,
#     perintah akan gagal dengan pesan eksplisit, bukan output palsu.
#   - "backup --worlds" (tanpa --stop) memakai mekanisme resmi save hold/query/
#     resume: file disalin dan DIPOTONG (truncate) sesuai panjang byte yang
#     dilaporkan server lewat 'save query', bukan sekadar cp -r mentah, agar
#     hasilnya konsisten meski server terus menulis data di background.
#     Jika server tidak mengonfirmasi "Data saved." dalam 24 percobaan (~2
#     menit), proses dibatalkan dengan pesan eksplisit (bukan backup palsu).
#     Alternatif yang dijamin konsisten: backup --worlds --stop.
#   - BEDROCK_BACKUP_RETAIN (env var, default 0 = simpan selamanya) membatasi
#     jumlah backup lama yang disimpan bila diisi > 0. Tidak memengaruhi
#     player_activity.log, yang selalu permanen tanpa rotasi.
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
CONF_FILE="/etc/bedrock-manager/manager.conf"

resolve_config() {
    SERVER_DIR="${BEDROCK_SERVER_DIR:-}"
    SCREEN_NAME="${BEDROCK_SCREEN_NAME:-}"
    SERVICE_NAME="${BEDROCK_SERVICE_NAME:-bedrock}"
    LOG_FILE="${BEDROCK_LOG_FILE:-}"
    PLAYER_LOG="${BEDROCK_PLAYER_LOG:-}"
    BACKUP_DIR="${BEDROCK_BACKUP_DIR:-}"

    if [ -f "$CONF_FILE" ]; then
        # shellcheck source=/dev/null
        source "$CONF_FILE"
    fi

    if [ -z "$SERVER_DIR" ]; then
        SERVER_DIR=$(systemctl show -p WorkingDirectory --value "${SERVICE_NAME}.service" 2>/dev/null || true)
    fi
    [ -z "$SERVER_DIR" ] && SERVER_DIR="/opt/bedrock-server"

    if [ -z "$SCREEN_NAME" ]; then
        local execstart
        execstart=$(systemctl show -p ExecStart --value "${SERVICE_NAME}.service" 2>/dev/null || true)
        SCREEN_NAME=$(echo "$execstart" | grep -oE '\-DmS[[:space:]]+[^[:space:]]+' | awk '{print $2}')
    fi
    [ -z "$SCREEN_NAME" ] && SCREEN_NAME="mc-server"

    [ -z "$LOG_FILE" ] && LOG_FILE="/var/log/bedrock-server.log"
    [ -z "$PLAYER_LOG" ] && PLAYER_LOG="${SERVER_DIR}/player_activity.log"
    [ -z "$BACKUP_DIR" ] && BACKUP_DIR="${SERVER_DIR}-backup"
    # BACKUP_RETAIN=0 (default) berarti backup config/worlds disimpan selamanya,
    # sama seperti player_activity.log. Set BEDROCK_BACKUP_RETAIN=N (N>0) jika
    # ingin membatasi jumlah backup yang disimpan (bukan berdasarkan waktu).
    BACKUP_RETAIN="${BEDROCK_BACKUP_RETAIN:-0}"
    UPDATE_SCRIPT="${SERVER_DIR}/update_bedrock.sh"
}

# -----------------------------------------------------------------------------
# UTILITAS
# -----------------------------------------------------------------------------
check_root() {
    if [ "$EUID" -ne 0 ]; then
        log ERROR "Perintah ini memerlukan hak akses root atau sudo."
        exit 1
    fi
}

require_installed() {
    if [ ! -d "$SERVER_DIR" ] || [ ! -x "$SERVER_DIR/bedrock_server" ]; then
        log ERROR "Instalasi server tidak ditemukan di: $SERVER_DIR"
        log ERROR "Set BEDROCK_SERVER_DIR atau isi $CONF_FILE jika direktori berbeda."
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
    screen -list 2>/dev/null | grep -q "\.${SCREEN_NAME}[[:space:]]"
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

# Metode identik dengan yang dipakai update_bedrock.sh (fallback 3 lapis),
# diduplikasi di sini secara sengaja agar 'version' murni cek versi tanpa
# efek samping (tidak stop/download/restart server seperti alur 'update').
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
    check_root
    require_installed
    if is_server_running; then
        log WARN "Server sudah berjalan."
        return 0
    fi
    systemctl start "$SERVICE_NAME"
    log INFO "Perintah start dikirim ke systemd."
}

cmd_stop() {
    check_root
    if ! is_server_running; then
        log WARN "Server tidak sedang berjalan."
        return 0
    fi
    systemctl stop "$SERVICE_NAME"
    log INFO "Server dihentikan."
}

cmd_restart() {
    check_root
    require_installed
    systemctl restart "$SERVICE_NAME"
    log INFO "Server di-restart."
}

cmd_status() {
    require_installed
    echo -e "${BOLD}Status service (${SERVICE_NAME}):${RESET}"
    systemctl status "$SERVICE_NAME" --no-pager -l 2>/dev/null | head -n 10
    echo ""
    echo -e "${BOLD}Direktori server :${RESET} $SERVER_DIR"
    echo -e "${BOLD}Versi terpasang  :${RESET} $(get_current_version)"

    if is_server_running; then
        # CATATAN PERBAIKAN: MainPID dari systemd untuk unit ini adalah PID
        # proses 'screen' (karena ExecStart=screen -DmS ...), BUKAN PID
        # 'bedrock_server' yang sebenarnya (itu adalah cucu proses, dijalankan
        # lewat 'bash -c' di dalam screen). Mengukur RSS pada MainPID akan
        # melaporkan memori 'screen' (~beberapa MB), bukan memori server asli.
        # Di sini PID 'bedrock_server' dicari langsung lewat pgrep.
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
    require_installed
    if ! screen_exists; then
        log ERROR "Sesi screen '$SCREEN_NAME' tidak ditemukan. Server mungkin tidak berjalan."
        exit 1
    fi
    log INFO "Melampirkan ke sesi screen '$SCREEN_NAME'. Keluar tanpa menghentikan server: Ctrl+A lalu D."
    exec screen -r "$SCREEN_NAME"
}

cmd_send() {
    local cmdtext="${1:-}"
    if [ -z "$cmdtext" ]; then
        log ERROR "Gunakan: $(basename "$0") send \"<perintah in-game>\""
        exit 1
    fi
    require_running
    if ! screen_exists; then
        log ERROR "Sesi screen '$SCREEN_NAME' tidak ditemukan."
        exit 1
    fi
    screen -S "$SCREEN_NAME" -p 0 -X stuff "${cmdtext}\r"
    log INFO "Perintah terkirim: $cmdtext"
}

cmd_online() {
    require_running
    if ! screen_exists; then
        log ERROR "Sesi screen '$SCREEN_NAME' tidak ditemukan."
        exit 1
    fi
    log INFO "Mengirim perintah 'list' dan membaca respons dari log..."
    screen -S "$SCREEN_NAME" -p 0 -X stuff "list\r"
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

# -----------------------------------------------------------------------------
# BACKUP WORLDS LIVE — mekanisme resmi save hold / save query / save resume
# -----------------------------------------------------------------------------
# Referensi (diverifikasi, bukan asumsi):
#   save hold   -> server bersiap backup, return segera (asinkron)
#   save query  -> dipanggil berulang; saat siap, mengembalikan konfirmasi
#                  "Data saved. Files are now ready to be copied." beserta
#                  daftar "path:panjang_byte" (dipisah koma) yang HARUS
#                  disalin dan DIPOTONG (truncate) sesuai panjang tsb agar
#                  konsisten meski file terus ditulis di background.
#   save resume -> menandai backup selesai, server lanjut normal.
#   Sumber: minecraft.fandom.com/wiki/Commands/save, dokumentasi command BDS.
#
# Perbaikan dari versi sebelumnya:
#   - Sebelumnya hanya mendeteksi kata "saved" secara longgar lalu men-cp -r
#     seluruh folder worlds tanpa truncation -> TIDAK benar-benar konsisten,
#     berpotensi salah deteksi karena autosave berkala juga memuat kata
#     "saved". Versi ini mem-parsing daftar file:panjang dari 'save query'
#     dan memotong tiap file sesuai panjang yang dilaporkan server, sesuai
#     mekanisme resmi.
#   - 'save resume' sekarang dijamin terkirim lewat trap RETURN, walau
#     terjadi error/timeout di tengah proses (mencegah world "tertahan").
live_backup_worlds() {
    local dest="$1" debug="${2:-false}"
    mkdir -p "$dest"

    local hold_issued=false
    resume_if_held() {
        if [ "$hold_issued" = true ]; then
            screen -S "$SCREEN_NAME" -p 0 -X stuff "save resume$(printf '\r')" 2>/dev/null || true
            hold_issued=false
        fi
    }
    trap resume_if_held RETURN

    log INFO "Mengirim 'save hold' ke konsol server..."
    screen -S "$SCREEN_NAME" -p 0 -X stuff "save hold$(printf '\r')"
    hold_issued=true

    local attempt=0 max_attempts=24 interval=5
    local query_output="" file_list=""

    while [ "$attempt" -lt "$max_attempts" ]; do
        sleep "$interval"
        screen -S "$SCREEN_NAME" -p 0 -X stuff "save query$(printf '\r')"
        sleep 1
        query_output=$(tail -n 20 "$LOG_FILE" 2>/dev/null || true)

        if [ "$debug" = true ]; then
            log INFO "[debug] output konsol terbaru:
$query_output"
        fi

        if echo "$query_output" | grep -q "Data saved."; then
            # Kasus 1: daftar file berada pada baris yang sama setelah frasa konfirmasi
            file_list=$(echo "$query_output" | sed -n 's/.*Files are now ready to be copied\.[[:space:]]*//p' | tail -n 1)
            # Kasus 2: daftar file berada pada baris terpisah setelah "Data saved."
            if [ -z "$file_list" ]; then
                file_list=$(echo "$query_output" | grep -E '^[^: ].*:[0-9]+' | grep -v "Data saved" | tail -n 1)
            fi
            break
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
        local src="${SERVER_DIR}/${rel_path}"
        local dst="${dest}/${rel_path}"
        mkdir -p "$(dirname "$dst")"
        if [ -f "$src" ]; then
            head -c "$length" "$src" > "$dst"
            count=$((count + 1))
        else
            log WARN "File sumber tidak ditemukan, dilewati: $src"
            skipped=$((skipped + 1))
        fi
    done
    log INFO "Backup worlds live selesai. File disalin: $count, dilewati: $skipped"

    trap - RETURN
    resume_if_held
    [ "$count" -gt 0 ]
}

# -----------------------------------------------------------------------------
# BACKUP (independen dari update)
# -----------------------------------------------------------------------------
cmd_backup() {
    check_root
    require_installed

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

    mkdir -p "$BACKUP_DIR"
    local ts dest
    ts=$(date '+%Y%m%d_%H%M%S')
    dest="$BACKUP_DIR/$ts"
    mkdir -p "$dest"

    log STEP "Membuat Backup (tanpa menjalankan update)"

    for f in server.properties allowlist.json permissions.json; do
        if [ -f "$SERVER_DIR/$f" ]; then
            cp "$SERVER_DIR/$f" "$dest/$f"
            log INFO "Backup: $f"
        fi
    done

    if [ "$include_worlds" = true ]; then
        if [ ! -d "$SERVER_DIR/worlds" ]; then
            log WARN "Direktori worlds tidak ditemukan, dilewati."
        elif [ "$safe_stop" = true ]; then
            log INFO "Mode --stop aktif: menghentikan server untuk snapshot terjamin konsisten."
            local was_running=false
            is_server_running && was_running=true
            [ "$was_running" = true ] && systemctl stop "$SERVICE_NAME"
            cp -r "$SERVER_DIR/worlds" "$dest/worlds"
            [ "$was_running" = true ] && systemctl start "$SERVICE_NAME"
            log INFO "Backup worlds (mode stop) selesai."
        elif is_server_running && screen_exists; then
            live_backup_worlds "$dest/worlds" "$debug" \
                || log WARN "Live backup worlds tidak sepenuhnya berhasil. Periksa log di atas."
        else
            cp -r "$SERVER_DIR/worlds" "$dest/worlds"
            log INFO "Server tidak berjalan, worlds disalin langsung."
        fi
    fi

    log INFO "Backup tersimpan di: $dest"
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

cmd_restore() {
    check_root
    require_installed
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
    # Tanpa opsi eksplisit, restore keduanya (perilaku default yang aman/jelas).
    if [ "$do_worlds" = false ] && [ "$do_configs" = false ]; then
        do_worlds=true; do_configs=true
    fi

    if [ "$do_worlds" = true ]; then
        if [ ! -d "${src}/worlds" ]; then
            log WARN "Backup ini tidak memiliki data worlds, dilewati."
        else
            log STEP "Restore Worlds dari $ts"
            local was_running=false
            is_server_running && was_running=true
            [ "$was_running" = true ] && systemctl stop "$SERVICE_NAME"
            rm -rf "${SERVER_DIR}/worlds"
            cp -r "${src}/worlds" "${SERVER_DIR}/worlds"
            log INFO "Worlds dipulihkan dari: $src"
            [ "$was_running" = true ] && systemctl start "$SERVICE_NAME"
        fi
    fi

    if [ "$do_configs" = true ]; then
        log STEP "Restore Konfigurasi dari $ts"
        local f
        for f in server.properties allowlist.json permissions.json; do
            if [ -f "${src}/${f}" ]; then
                cp "${src}/${f}" "${SERVER_DIR}/${f}"
                log INFO "Dipulihkan: $f"
            fi
        done
        if is_server_running && screen_exists; then
            screen -S "$SCREEN_NAME" -p 0 -X stuff "whitelist reload$(printf '\r')" 2>/dev/null || true
            screen -S "$SCREEN_NAME" -p 0 -X stuff "permissions reload$(printf '\r')" 2>/dev/null || true
            log INFO "allowlist/permissions dimuat ulang tanpa restart (whitelist reload, permissions reload)."
        fi
    fi
}

# -----------------------------------------------------------------------------
# UPDATE (meneruskan ke update_bedrock.sh yang sudah ada)
# -----------------------------------------------------------------------------
cmd_update() {
    check_root
    require_installed
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
# Dibuat otomatis oleh bedrock-manager.sh (logger install). Jangan diedit manual.
# Menambahkan (append-only) setiap event Player connected/disconnected ke PLAYER_LOG.
# File PLAYER_LOG tidak pernah dipangkas atau dirotasi oleh skrip ini.
set -uo pipefail

LOG_FILE="${BEDROCK_LOG_FILE:-/var/log/bedrock-server.log}"
PLAYER_LOG="${BEDROCK_PLAYER_LOG:-/opt/bedrock-server/player_activity.log}"

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
    log INFO "Skrip logger dipasang: $logger_script"

    cat > "$unit_file" << EOF
[Unit]
Description=Bedrock Player Activity Logger (join/leave permanen)
After=network.target ${SERVICE_NAME}.service
Wants=${SERVICE_NAME}.service

[Service]
Type=simple
User=root
Environment=BEDROCK_LOG_FILE=${LOG_FILE}
Environment=BEDROCK_PLAYER_LOG=${PLAYER_LOG}
ExecStart=/bin/bash ${logger_script}
Restart=always
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable bedrock-player-logger.service
    systemctl restart bedrock-player-logger.service

    log INFO "Service aktif: bedrock-player-logger"
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
            # Menjumlahkan durasi tiap sesi (selisih JOIN -> LEAVE berikutnya per
            # nama) dari seluruh riwayat player_activity.log. Sesi yang belum
            # ada pasangan LEAVE (server sedang berjalan) tidak dihitung.
            printf "%-24s %-8s %s\n" "PEMAIN" "SESI" "TOTAL_WAKTU"
            awk -F'|' '
                $2=="JOIN" {
                    cmd = "date -d \"" $1 "\" +%s"; cmd | getline t; close(cmd)
                    in_time[$3] = t
                    sesi[$3]++
                }
                $2=="LEAVE" && ($3 in in_time) {
                    cmd = "date -d \"" $1 "\" +%s"; cmd | getline t; close(cmd)
                    total[$3] += (t - in_time[$3])
                    delete in_time[$3]
                }
                END {
                    for (p in sesi) {
                        d = total[p] + 0
                        printf "%-24s %-8d %02d:%02d:%02d\n", p, sesi[p], int(d/3600), int((d%3600)/60), int(d%60)
                    }
                }
            ' "$PLAYER_LOG" | sort -k2 -rn
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
    local self
    self=$(readlink -f "$0")
    ln -sf "$self" "$target"
    chmod +x "$self"
    log INFO "Symlink dibuat: $target -> $self"
    log INFO "Panggil dari mana saja dengan: bedrock <perintah>"
}

# -----------------------------------------------------------------------------
# BANTUAN
# -----------------------------------------------------------------------------
print_help() {
    # Mengambil seluruh blok komentar header (baris 2 sampai baris pembatas
    # "====" TERAKHIR sebelum kode pertama), bukan nomor baris tetap yang
    # mudah basi ketika header ditambah/dikurangi di kemudian hari.
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
        help|-h|--help) print_help ;;
        *)
            log ERROR "Perintah tidak dikenal: $command"
            print_help
            exit 1
            ;;
    esac
}

main "$@"
