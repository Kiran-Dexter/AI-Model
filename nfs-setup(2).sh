#!/usr/bin/env bash
# =============================================================================
#  nfs-setup.sh - Interactive NFS server setup for RHEL 9
#  (also runs on Rocky Linux 9, AlmaLinux 9, Oracle Linux 9, CentOS Stream 9)
#
#  Usage:  sudo bash nfs-setup.sh
#
#  Menu-driven. Every step asks before changing anything:
#    * Installs nfs-utils
#    * Chooses which NFS versions to serve: NFSv4 only, or NFSv3 + NFSv4
#    * Enables and starts nfs-server (and rpcbind when NFSv3 is on)
#    * Opens the needed firewalld services
#    * Checks the SELinux booleans NFS needs
#    * Creates exports, one file per directory in /etc/exports.d/, checks
#      them with exportfs and rolls back automatically if they are rejected
#    * Lists, removes and reports on exports
#
#  Every file it changes is backed up to /root/nfs-setup-backups/<timestamp>/
#  Actions are logged to /var/log/nfs-setup.log
# =============================================================================

set -Eeuo pipefail

readonly SCRIPT_NAME="${0##*/}"
readonly EXPORTS_DIR="/etc/exports.d"
readonly NFS_CONF="/etc/nfs.conf"
readonly MANAGED_TAG="# Managed by nfs-setup.sh"
readonly BACKUP_ROOT="/root/nfs-setup-backups"
readonly LOG_FILE="/var/log/nfs-setup.log"
readonly PATH_RE='^(/[A-Za-z0-9._@+-]+)+/?$'
# Directories that must never be exported (the directory itself or anything below it)
readonly -a PROTECTED_PATHS=(/proc /sys /dev /run /boot /etc /usr /bin /sbin /lib /lib64 /root /var/lib/nfs /var/run)
# NFSv3 file locking (lockd) and reboot recovery (statd) use random ports unless
# pinned. These are pinned when NFSv3 is enabled so the firewall can allow them.
readonly LOCKD_TCP_PORT=32803
readonly LOCKD_UDP_PORT=32769
readonly STATD_PORT=662

BACKUP_DIR=""
LAST_BACKUP=""
TMP_FILE=""

if [[ -t 1 ]]; then
    C_RED=$'\e[1;31m'; C_GRN=$'\e[1;32m'; C_YEL=$'\e[1;33m'
    C_BLU=$'\e[1;34m'; C_BLD=$'\e[1m';    C_RST=$'\e[0m'
else
    C_RED=''; C_GRN=''; C_YEL=''; C_BLU=''; C_BLD=''; C_RST=''
fi

# ----------------------------------------------------------------------------
#  Output and logging
# ----------------------------------------------------------------------------
log() {
    if [[ -w ${LOG_FILE%/*} ]]; then
        printf '%s %s\n' "$(date '+%F %T')" "$*" >>"$LOG_FILE" 2>/dev/null || true
    fi
}
info()   { printf '%s[INFO]%s %s\n' "$C_BLU" "$C_RST" "$*";       log "INFO  $*"; }
ok()     { printf '%s[ OK ]%s %s\n' "$C_GRN" "$C_RST" "$*";       log "OK    $*"; }
warn()   { printf '%s[WARN]%s %s\n' "$C_YEL" "$C_RST" "$*" >&2;   log "WARN  $*"; }
err()    { printf '%s[FAIL]%s %s\n' "$C_RED" "$C_RST" "$*" >&2;   log "ERROR $*"; }
die()    { err "$*"; exit 1; }
header() { printf '\n%s=== %s ===%s\n' "$C_BLD" "$*" "$C_RST"; }

on_error() {
    local rc=$1 line=$2 cmd=$3
    err "Unexpected error (exit code $rc) at line $line: $cmd"
    if [[ -n $BACKUP_DIR ]]; then err "Backups of changed files are in $BACKUP_DIR"; fi
}

cleanup() {
    if [[ -n ${TMP_FILE:-} && -e $TMP_FILE ]]; then rm -f -- "$TMP_FILE"; fi
}

# ----------------------------------------------------------------------------
#  Input helpers (all of them abort cleanly on EOF / Ctrl-D)
# ----------------------------------------------------------------------------
trim() {
    local s=$1
    s=${s#"${s%%[![:space:]]*}"}
    s=${s%"${s##*[![:space:]]}"}
    printf '%s' "$s"
}

# ask VARNAME "Prompt" [default]
ask() {
    local _ask_var=$1 _ask_prompt=$2 _ask_default=${3-} _ask_reply
    if [[ -n $_ask_default ]]; then _ask_prompt+=" [$_ask_default]"; fi
    if ! IFS= read -r -e -p "$_ask_prompt: " _ask_reply; then
        printf '\n'
        die "No more input (EOF). Exiting."
    fi
    _ask_reply=$(trim "$_ask_reply")
    if [[ -z $_ask_reply ]]; then _ask_reply=$_ask_default; fi
    printf -v "$_ask_var" '%s' "$_ask_reply"
}

# confirm "Question" [y|n]   -> exit status 0 = yes, 1 = no. Always use inside "if".
confirm() {
    local prompt=$1 default=${2:-n} reply hint
    if [[ $default == y ]]; then hint="Y/n"; else hint="y/N"; fi
    while true; do
        if ! IFS= read -r -e -p "$prompt [$hint]: " reply; then
            printf '\n'
            die "No more input (EOF). Exiting."
        fi
        reply=$(trim "$reply")
        reply=${reply,,}
        if [[ -z $reply ]]; then reply=$default; fi
        case $reply in
            y|yes) return 0 ;;
            n|no)  return 1 ;;
            *)     warn "Please answer y or n." ;;
        esac
    done
}

# choose VARNAME "Prompt" DEFAULT_NUMBER "option 1" "option 2" ...  -> VARNAME = chosen number
choose() {
    local _ch_var=$1 _ch_prompt=$2 _ch_default=$3 _ch_reply _ch_i
    shift 3
    local -a _ch_opts=("$@")
    for _ch_i in "${!_ch_opts[@]}"; do
        printf '  %d) %s\n' "$((_ch_i + 1))" "${_ch_opts[_ch_i]}"
    done
    while true; do
        ask _ch_reply "$_ch_prompt" "$_ch_default"
        if [[ $_ch_reply =~ ^[1-9][0-9]{0,2}$ ]] && (( _ch_reply <= ${#_ch_opts[@]} )); then
            printf -v "$_ch_var" '%s' "$_ch_reply"
            return 0
        fi
        warn "Enter a number from 1 to ${#_ch_opts[@]}."
    done
}

in_array() {
    local needle=$1 x
    shift
    for x in "$@"; do
        if [[ $x == "$needle" ]]; then return 0; fi
    done
    return 1
}

# ----------------------------------------------------------------------------
#  Validation
# ----------------------------------------------------------------------------
is_valid_ipv4() {
    local ip=$1 octet
    [[ $ip =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    for octet in "${BASH_REMATCH[@]:1}"; do
        if (( 10#$octet > 255 )); then return 1; fi
    done
    return 0
}

is_valid_ipv6() {
    local a=$1 rest
    [[ $a == *:* && $a =~ ^[0-9A-Fa-f:.]+$ && $a != *:::* ]] || return 1
    rest=${a/::/}
    [[ $rest != *::* ]]          # at most one "::"
}

# Accepts: *  |  IPv4  |  IPv4/prefix  |  IPv4/netmask  |  IPv6[/prefix]
#          hostname  |  wildcard hostname (*.example.com)  |  @netgroup
is_valid_client() {
    local c=$1 addr prefix
    local host_re='^[A-Za-z0-9*?]([A-Za-z0-9.*?-]{0,251}[A-Za-z0-9*?])?$'
    [[ -n $c ]] || return 1
    if [[ $c == '*' ]]; then return 0; fi
    if [[ $c == @* ]]; then
        [[ $c =~ ^@[A-Za-z0-9._-]+$ ]]
        return
    fi
    if [[ $c == */* ]]; then
        addr=${c%%/*}
        prefix=${c#*/}
        if is_valid_ipv4 "$addr"; then
            if [[ $prefix =~ ^[0-9]{1,2}$ ]] && (( 10#$prefix <= 32 )); then return 0; fi
            is_valid_ipv4 "$prefix"
            return
        fi
        if is_valid_ipv6 "$addr"; then
            [[ $prefix =~ ^[0-9]{1,3}$ ]] && (( 10#$prefix <= 128 ))
            return
        fi
        return 1
    fi
    if is_valid_ipv4 "$c" || is_valid_ipv6 "$c"; then return 0; fi
    if [[ $c =~ ^[0-9.]+$ ]]; then return 1; fi      # looks like a broken IPv4 address
    [[ $c =~ $host_re ]]
}

# Prints the reason and returns 1 if the path cannot be exported.
validate_export_path() {
    local p=$1 resolved d
    if [[ ! $p =~ $PATH_RE ]]; then
        err "Use an absolute path made of letters, digits and . _ @ + - only (no spaces), e.g. /srv/nfs/share"
        return 1
    fi
    resolved=$(realpath -m -- "$p")
    if [[ $resolved == / ]]; then
        err "Refusing to export the root filesystem (/)."
        return 1
    fi
    if [[ ! $resolved =~ $PATH_RE ]]; then
        err "$p resolves to '$resolved', which contains unsupported characters."
        return 1
    fi
    if [[ $resolved == /var ]]; then
        err "Refusing to export /var itself. Use a subdirectory such as /var/nfs/share."
        return 1
    fi
    for d in "${PROTECTED_PATHS[@]}"; do
        if [[ $resolved == "$d" || $resolved == "$d"/* ]]; then
            err "Refusing to export system directory $resolved (it is under $d)."
            return 1
        fi
    done
    if [[ -e $resolved && ! -d $resolved ]]; then
        err "$resolved exists and is not a directory."
        return 1
    fi
    return 0
}

# ----------------------------------------------------------------------------
#  System helpers
# ----------------------------------------------------------------------------
require_root() {
    if (( EUID != 0 )); then die "Run this script as root: sudo bash $SCRIPT_NAME"; fi
}

check_os() {
    local id="" like="" ver="" pretty=""
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        IFS='|' read -r id like ver pretty < <(
            . /etc/os-release
            printf '%s|%s|%s|%s\n' "${ID:-}" "${ID_LIKE:-}" "${VERSION_ID:-}" "${PRETTY_NAME:-}"
        ) || true
    fi
    local major=${ver%%.*}
    case $id in rhel|centos|rocky|almalinux|ol) like+=" rhel" ;; esac
    if [[ " $like " == *" rhel "* && $major == 9 ]]; then
        ok "Detected ${pretty:-$id $ver}"
        return 0
    fi
    warn "This script is written for RHEL 9. Detected: ${pretty:-unknown OS}."
    if ! confirm "Continue anyway?" n; then exit 1; fi
}

is_installed() { rpm -q "$1" >/dev/null 2>&1; }

need_nfs_utils() {
    if is_installed nfs-utils; then return 0; fi
    warn "nfs-utils is not installed. Run 'Full setup' first."
    return 1
}

ensure_backup_dir() {
    if [[ -z $BACKUP_DIR ]]; then
        BACKUP_DIR="$BACKUP_ROOT/$(date +%Y%m%d-%H%M%S)"
        mkdir -p -m 0700 -- "$BACKUP_DIR"
    fi
}

# Copies a file into this run's backup directory; sets LAST_BACKUP to the copy.
backup_file() {
    local src=$1 dest
    LAST_BACKUP=""
    [[ -e $src ]] || return 0
    ensure_backup_dir
    dest="$BACKUP_DIR/${src//\//_}"
    if [[ -e $dest ]]; then dest+=".$(date +%s%N)"; fi
    cp -a -- "$src" "$dest"
    LAST_BACKUP=$dest
    log "Backed up $src -> $dest"
}

is_managed() { grep -Fxq -e "$MANAGED_TAG" -- "$1" 2>/dev/null; }

# Does the exports file $1 contain an entry for path $2?
exports_file_has_path() {
    awk -v p="$2" '!/^[[:space:]]*#/ && ($1 == p || $1 == "\"" p "\"") {f = 1} END {exit !f}' "$1"
}

is_exported() {
    local out
    out=$(exportfs -v 2>/dev/null) || return 1
    awk -v p="$1" '/^[^[:space:]]/ && $1 == p {f = 1} END {exit !f}' <<<"$out"
}

reload_exports() {
    local out rc=0
    out=$(exportfs -ra 2>&1) || rc=$?
    if [[ -n $out ]]; then
        printf '%s\n' "$out" | sed 's/^/    /' >&2
        log "exportfs -ra (rc=$rc): $out"
    fi
    return "$rc"
}

# Prints the value of a key from nfs.conf (merged with /etc/nfs.conf.d), or nothing.
conf_get() { nfsconf --get "$1" "$2" 2>/dev/null || true; }

# GNU chmod keeps setuid/setgid on directories for a 3- or 4-digit numeric mode,
# so "chmod 0755" on a 2775 directory gives 2755. A 5-digit mode sets every bit.
set_mode() { chmod "$(printf '0%04o' "$((8#$1))")" "$2"; }

nfsv3_enabled() {
    local v
    v=$(conf_get nfsd vers3)
    case ${v,,} in
        n|no|0|false|off) return 1 ;;
        *)                return 0 ;;      # unset = RHEL 9 default = enabled
    esac
}

selinux_active() {
    command -v getenforce >/dev/null 2>&1 && [[ $(getenforce 2>/dev/null) != Disabled ]]
}

check_selinux_bool() {
    local bool=$1 val
    val=$(getsebool "$bool" 2>/dev/null | awk '{print $NF}' || true)
    case $val in
        on)  ok "SELinux boolean $bool is on." ;;
        off)
            warn "SELinux boolean $bool is off; NFS clients will get 'Permission denied'."
            if confirm "Turn on $bool permanently?" y; then
                setsebool -P "$bool" on
                ok "Turned on $bool."
            else
                warn "Left $bool off."
            fi
            ;;
        *)   : ;;   # boolean not present on this system
    esac
}

server_address() {
    local ip
    ip=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
    if [[ -z $ip ]]; then ip=$(hostname 2>/dev/null || echo "<server>"); fi
    printf '%s' "$ip"
}

print_client_hint() {
    local path=$1 ip mnt
    ip=$(server_address)
    mnt="/mnt/${path##*/}"
    printf '\n%sTo mount it on a RHEL client:%s\n' "$C_BLD" "$C_RST"
    printf '    dnf install -y nfs-utils\n'
    printf '    mkdir -p %s\n' "$mnt"
    printf '    mount -t nfs %s:%s %s\n' "$ip" "$path" "$mnt"
    printf '%sTo mount it at boot, add this line to /etc/fstab on the client:%s\n' "$C_BLD" "$C_RST"
    printf '    %s:%s  %s  nfs  defaults,_netdev  0 0\n' "$ip" "$path" "$mnt"
}

# ----------------------------------------------------------------------------
#  Setup steps
# ----------------------------------------------------------------------------
install_packages() {
    header "Packages"
    if is_installed nfs-utils; then
        ok "nfs-utils is already installed ($(rpm -q nfs-utils))."
        return 0
    fi
    if ! confirm "nfs-utils is not installed. Install it with dnf now?" y; then
        warn "Skipped installing nfs-utils."
        return 0
    fi
    if ! dnf install -y nfs-utils; then
        die "dnf could not install nfs-utils. Check that the system is registered (subscription-manager status) and that the BaseOS repository is reachable."
    fi
    ok "Installed $(rpm -q nfs-utils)."
}

configure_versions() {
    header "NFS protocol versions"
    if ! command -v nfsconf >/dev/null 2>&1; then
        warn "nfsconf not found; leaving NFS versions at their defaults."
        return 0
    fi
    local was_v3=0 want_v3=0 default choice
    if nfsv3_enabled; then was_v3=1; fi
    if (( was_v3 )); then
        info "Currently serving: NFSv3 and NFSv4."
        default=2
    else
        info "Currently serving: NFSv4 only."
        default=1
    fi
    choose choice "Which versions should this server serve?" "$default" \
        "NFSv4 only (recommended; clients need only TCP port 2049)" \
        "NFSv3 and NFSv4 (for older clients that cannot use NFSv4)"
    if [[ $choice == 2 ]]; then want_v3=1; fi

    local changed=0 now_v3=0
    if (( want_v3 != was_v3 )); then
        backup_file "$NFS_CONF"
        if (( want_v3 )); then nfsconf --set nfsd vers3 y; else nfsconf --set nfsd vers3 n; fi
        changed=1
        if nfsv3_enabled; then now_v3=1; fi
        if (( now_v3 != want_v3 )); then
            warn "A file in /etc/nfs.conf.d/ overrides 'vers3' in $NFS_CONF; the change has no effect until you edit it."
        elif (( want_v3 )); then
            ok "Enabled NFSv3 in $NFS_CONF."
        else
            ok "Disabled NFSv3 in $NFS_CONF (NFSv4 only)."
        fi
    fi

    # NFSv3 locking needs fixed ports to get through the firewall.
    if (( want_v3 )) && [[ -z $(conf_get lockd port) || -z $(conf_get lockd udp-port) || -z $(conf_get statd port) ]]; then
        if (( ! changed )); then backup_file "$NFS_CONF"; fi
        if [[ -z $(conf_get lockd port) ]];     then nfsconf --set lockd port "$LOCKD_TCP_PORT"; fi
        if [[ -z $(conf_get lockd udp-port) ]]; then nfsconf --set lockd udp-port "$LOCKD_UDP_PORT"; fi
        if [[ -z $(conf_get statd port) ]];     then nfsconf --set statd port "$STATD_PORT"; fi
        ok "Pinned NFSv3 lock ports: lockd $(conf_get lockd port)/tcp $(conf_get lockd udp-port)/udp, statd $(conf_get statd port)."
        info "If the server also mounts NFS shares itself, the lockd ports apply only after a reboot."
        changed=1
    fi

    if (( ! changed )); then
        ok "No change needed."
        return 0
    fi

    if systemctl is-active --quiet nfs-server.service; then
        if confirm "nfs-server is running. Restart it now to apply? Connected clients will pause briefly." y; then
            if (( want_v3 )); then ensure_rpcbind; fi
            if systemctl restart nfs-server.service; then
                systemctl try-restart rpc-statd.service >/dev/null 2>&1 || true
                ok "Restarted nfs-server."
            else
                die "nfs-server failed to restart. Check: journalctl -xeu nfs-server.service"
            fi
        else
            warn "The change takes effect the next time nfs-server restarts."
        fi
    fi
}

ensure_rpcbind() {
    if systemctl enable --now rpcbind.socket rpcbind.service >/dev/null 2>&1; then
        ok "rpcbind is enabled and running (needed for NFSv3)."
    else
        warn "Could not start rpcbind; NFSv3 clients will not be able to mount."
    fi
}

start_services() {
    header "Services"
    if nfsv3_enabled; then ensure_rpcbind; fi
    if ! systemctl enable --now nfs-server.service >/dev/null 2>&1; then
        die "nfs-server failed to start. Check: journalctl -xeu nfs-server.service"
    fi
    if ! systemctl is-active --quiet nfs-server.service; then
        die "nfs-server is not running. Check: journalctl -xeu nfs-server.service"
    fi
    ok "nfs-server is enabled at boot and running."
}

configure_firewall() {
    header "Firewall"
    if ! command -v firewall-cmd >/dev/null 2>&1; then
        warn "firewalld is not installed. Make sure TCP 2049 is reachable (plus 111 and 20048 for NFSv3)."
        return 0
    fi
    if ! firewall-cmd --state >/dev/null 2>&1; then
        warn "firewalld is not running. Make sure TCP 2049 is reachable (plus 111 and 20048 for NFSv3)."
        return 0
    fi
    if ! confirm "Open NFS in firewalld?" y; then
        warn "Firewall left unchanged. Clients will not be able to connect until NFS is allowed."
        return 0
    fi

    local zone zones default_zone item p
    local -a services=(nfs) ports=() stale=()
    default_zone=$(firewall-cmd --get-default-zone)
    zones=" $(firewall-cmd --get-zones) "
    while true; do
        ask zone "firewalld zone that NFS clients connect through" "$default_zone"
        if [[ $zones == *" $zone "* ]]; then break; fi
        warn "Unknown zone '$zone'. Available:${zones% }"
    done

    if nfsv3_enabled; then
        services+=(rpc-bind mountd)
        p=$(conf_get lockd port);     if [[ -n $p ]]; then ports+=("$p/tcp"); fi
        p=$(conf_get lockd udp-port); if [[ -n $p ]]; then ports+=("$p/udp"); fi
        p=$(conf_get statd port);     if [[ -n $p ]]; then ports+=("$p/tcp" "$p/udp"); fi
        if (( ${#ports[@]} == 0 )); then
            warn "NFSv3 lock ports are not pinned, so file locking may hang through the firewall. Rerun the versions step to fix this."
        fi
    fi
    for item in "${services[@]}"; do fw_allow "$zone" service "$item"; done
    for item in "${ports[@]}";    do fw_allow "$zone" port "$item"; done

    if ! nfsv3_enabled; then
        for item in rpc-bind mountd; do
            if firewall-cmd --permanent --zone="$zone" --query-service="$item" >/dev/null 2>&1; then stale+=("$item"); fi
        done
        if (( ${#stale[@]} )); then
            info "NFSv3 is off, but ${stale[*]} are still open in zone '$zone' (rpc-bind may be needed by other RPC services such as NIS)."
            if confirm "Close ${stale[*]}?" n; then
                for item in "${stale[@]}"; do
                    firewall-cmd --permanent --zone="$zone" --remove-service="$item" >/dev/null
                    firewall-cmd --zone="$zone" --remove-service="$item" >/dev/null 2>&1 || true
                    ok "Closed service '$item' in zone '$zone'."
                done
            fi
        fi
    fi
}

# fw_allow ZONE service|port VALUE
# Adds the rule permanently and to the running firewall. No "firewall-cmd --reload",
# because a reload throws away runtime-only rules that someone else added.
fw_allow() {
    local zone=$1 kind=$2 val=$3
    if firewall-cmd --permanent --zone="$zone" --query-"$kind"="$val" >/dev/null 2>&1; then
        ok "$kind '$val' is already allowed in zone '$zone'."
    else
        firewall-cmd --permanent --zone="$zone" --add-"$kind"="$val" >/dev/null
        ok "Allowed $kind '$val' in zone '$zone'."
    fi
    if ! firewall-cmd --zone="$zone" --query-"$kind"="$val" >/dev/null 2>&1; then
        firewall-cmd --zone="$zone" --add-"$kind"="$val" >/dev/null
    fi
}

check_selinux() {
    header "SELinux"
    if ! selinux_active; then
        info "SELinux is disabled or not present; nothing to check."
        return 0
    fi
    info "SELinux mode: $(getenforce)."
    check_selinux_bool nfs_export_all_rw
    check_selinux_bool nfs_export_all_ro
}

# ----------------------------------------------------------------------------
#  Export management
# ----------------------------------------------------------------------------
add_export() {
    header "Add an NFS export"
    local path real name file f current="" keep_label perm_choice perm_desc
    local owner="" group="" mode="" client access sync choice opts anonuid anongid line
    local created=0 prev="" old_perm="" final_uid final_mode u
    local -a clients=() entries=() squash_uids=()

    if ! systemctl is-active --quiet nfs-server.service; then
        warn "nfs-server is not running."
        if confirm "Enable and start it now?" y; then start_services; fi
    fi

    # --- Directory -----------------------------------------------------------
    while true; do
        ask path "Directory to export, absolute path ('q' to cancel)" "/srv/nfs/share"
        if [[ $path == [qQ] ]]; then info "Cancelled."; return 0; fi
        if validate_export_path "$path"; then break; fi
    done
    real=$(realpath -m -- "$path")
    if [[ $real != "${path%/}" ]]; then info "Using the canonical path: $real"; fi

    # Reuse the file this script already wrote for this path, if there is one.
    file=""
    for f in "$EXPORTS_DIR"/*.exports; do
        [[ -f $f ]] || continue
        if is_managed "$f" && exports_file_has_path "$f" "$real"; then file=$f; break; fi
    done
    if [[ -z $file ]]; then
        name=${real#/}
        name=${name//\//_}
        file="$EXPORTS_DIR/$name.exports"
        # Different paths can flatten to the same name (/srv/nfs_share and /srv/nfs/share),
        # so add a hash of the path instead of overwriting another export's file.
        if [[ -e $file ]]; then
            file="$EXPORTS_DIR/$name-$(printf '%s' "$real" | md5sum | cut -c1-8).exports"
        fi
    fi

    if [[ -e $file ]] && ! is_managed "$file"; then
        err "$file already exists and was not created by this script. Edit or remove it by hand first."
        return 0
    fi
    for f in /etc/exports "$EXPORTS_DIR"/*.exports; do
        [[ -f $f && $f != "$file" ]] || continue
        if exports_file_has_path "$f" "$real"; then
            err "$real is already exported in $f. Edit that file by hand, or remove the entry first."
            return 0
        fi
    done
    if [[ -e $file ]]; then
        warn "$real is already exported by this script:"
        grep -v -e '^#' "$file" | sed 's/^/    /' || true
        if ! confirm "Replace it with a new definition?" n; then info "Cancelled."; return 0; fi
    fi

    # --- Ownership and permissions ----------------------------------------
    if [[ -d $real ]]; then
        current=$(stat -c '%U:%G %a' -- "$real")
        keep_label="Leave unchanged ($current)"
    else
        info "$real does not exist yet; it will be created."
        keep_label="Default for a new directory (root:root 755)"
    fi
    while true; do
        choose perm_choice "Owner and permissions for $real" 1 \
            "$keep_label" \
            "nobody:nobody 2775 (writable by squashed users: client root with root_squash, everyone with all_squash)" \
            "Custom owner, group and mode"
        case $perm_choice in
            1)
                perm_desc=$keep_label
                break
                ;;
            2)
                if getent passwd nobody >/dev/null && getent group nobody >/dev/null; then
                    perm_desc="nobody:nobody 2775"
                    break
                fi
                warn "User or group 'nobody' does not exist on this system. Choose another option."
                ;;
            3)
                while true; do
                    ask owner "Owner (user name or UID)" "root"
                    if [[ $owner =~ ^[0-9]+$ ]] || getent passwd "$owner" >/dev/null; then break; fi
                    warn "Unknown user '$owner'."
                done
                while true; do
                    ask group "Group (group name or GID)" "root"
                    if [[ $group =~ ^[0-9]+$ ]] || getent group "$group" >/dev/null; then break; fi
                    warn "Unknown group '$group'."
                done
                while true; do
                    ask mode "Mode in octal (e.g. 0755, 2775, 0770)" "0755"
                    if [[ $mode =~ ^[0-7]{3,4}$ ]]; then break; fi
                    warn "'$mode' is not an octal mode."
                done
                perm_desc="$owner:$group $mode"
                break
                ;;
        esac
    done

    # --- Clients -------------------------------------------------------------
    info "Add the hosts or networks allowed to mount $real."
    while true; do
        ask client "Client (e.g. 192.168.1.0/24, 10.0.0.5, host.example.com, *.example.com, * = anyone)"
        if [[ -z $client ]]; then warn "Enter at least one client."; continue; fi
        if ! is_valid_client "$client"; then
            warn "'$client' is not a valid IP address, network, hostname, wildcard or @netgroup."
            continue
        fi
        if in_array "$client" "${clients[@]}"; then warn "$client is already in this export."; continue; fi
        if [[ $client == '*' ]]; then
            warn "'*' lets ANY host that can reach this server mount the export."
            if ! confirm "Allow every host?" n; then continue; fi
        fi

        choose choice "Access for $client" 1 "Read-write (rw)" "Read-only (ro)"
        if [[ $choice == 1 ]]; then access=rw; else access=ro; fi

        sync=sync
        if [[ $access == rw ]]; then
            choose choice "Write mode for $client" 1 \
                "sync  - reply only after data is on disk (safe, recommended)" \
                "async - faster, but recent writes are lost if the server crashes"
            if [[ $choice == 2 ]]; then sync=async; fi
        fi

        choose choice "Mapping of client users for $client" 1 \
            "root_squash    - client root becomes 'nobody' (recommended)" \
            "no_root_squash - client root has full root power on this export (risky)" \
            "all_squash     - every client user becomes one anonymous user"
        opts="$access,$sync"
        case $choice in
            1)
                opts+=",root_squash"
                ;;
            2)
                warn "With no_root_squash, root on $client can create, change and delete any file in $real."
                if confirm "Use no_root_squash anyway?" n; then
                    opts+=",no_root_squash"
                else
                    opts+=",root_squash"
                    info "Using root_squash."
                fi
                ;;
            3)
                while true; do
                    ask anonuid "UID the client users map to" "65534"
                    if [[ $anonuid =~ ^[0-9]{1,10}$ ]] && (( 10#$anonuid <= 4294967294 )); then break; fi
                    warn "Enter a numeric UID."
                done
                while true; do
                    ask anongid "GID the client users map to" "65534"
                    if [[ $anongid =~ ^[0-9]{1,10}$ ]] && (( 10#$anongid <= 4294967294 )); then break; fi
                    warn "Enter a numeric GID."
                done
                opts+=",all_squash,anonuid=$((10#$anonuid)),anongid=$((10#$anongid))"
                ;;
        esac
        opts+=",no_subtree_check"

        # Remember which UID a squashed client writes as, to check permissions below.
        if [[ $access == rw ]]; then
            case $opts in
                *no_root_squash*) ;;
                *all_squash*)     squash_uids+=("$((10#$anonuid))") ;;
                *)                squash_uids+=(65534) ;;
            esac
        fi

        clients+=("$client")
        entries+=("$client($opts)")
        ok "Added $client($opts)"
        if ! confirm "Add another client to this export?" n; then break; fi
    done

    # --- Will squashed clients be able to write? --------------------------------
    case $perm_choice in
        1)
            if [[ -d $real ]]; then
                final_uid=$(stat -c %u -- "$real"); final_mode=$(stat -c %a -- "$real")
            else
                final_uid=0; final_mode=755
            fi
            ;;
        2) final_uid=$(id -u nobody); final_mode=2775 ;;
        3)
            if [[ $owner =~ ^[0-9]+$ ]]; then final_uid=$((10#$owner)); else final_uid=$(id -u "$owner"); fi
            final_mode=$mode
            ;;
    esac
    for u in "${squash_uids[@]}"; do
        if (( (u == final_uid && (8#$final_mode >> 6 & 2)) || (8#$final_mode & 2) )); then continue; fi
        warn "Squashed clients write as UID $u, but $real will be owned by UID $final_uid with mode $final_mode."
        warn "Client root (and all_squash users) will get 'Permission denied' when writing. Option 2, nobody:nobody 2775, usually fixes this."
        break
    done

    # --- Review ----------------------------------------------------------------
    line="$real ${entries[*]}"
    header "Review"
    printf '  Directory   : %s%s\n' "$real" "$( [[ -d $real ]] || printf ' (will be created)')"
    printf '  Permissions : %s\n' "$perm_desc"
    printf '  Export file : %s\n' "$file"
    printf '  Entry       : %s\n\n' "$line"
    if ! confirm "Apply this export?" y; then info "Cancelled; nothing was changed."; return 0; fi

    # --- Apply -----------------------------------------------------------------
    if [[ -d $real ]]; then
        old_perm=$(stat -c '%u:%g %a' -- "$real")
    else
        mkdir -p -- "$real"
        created=1
        ok "Created $real."
    fi
    case $perm_choice in
        1) if (( created )); then chown root:root "$real"; set_mode 0755 "$real"; fi ;;
        2) chown nobody:nobody "$real"; set_mode 2775 "$real"; ok "Set $real to nobody:nobody 2775." ;;
        3) chown "$owner:$group" "$real"; set_mode "$mode" "$real"; ok "Set $real to $owner:$group $mode." ;;
    esac

    if [[ -e $file ]]; then
        backup_file "$file"
        prev=$LAST_BACKUP
    fi
    mkdir -p -- "$EXPORTS_DIR"
    # Temp file name does not end in .exports, so exportfs ignores it until it is renamed.
    TMP_FILE=$(mktemp "$EXPORTS_DIR/.nfs-setup.XXXXXX")
    {
        printf '%s\n' "$MANAGED_TAG"
        printf '# Written %s. Use %s to change or remove this export.\n' "$(date '+%F %T')" "$SCRIPT_NAME"
        printf '%s\n' "$line"
    } >"$TMP_FILE"
    chmod 0644 "$TMP_FILE"
    mv -f -- "$TMP_FILE" "$file"
    TMP_FILE=""
    if command -v restorecon >/dev/null 2>&1; then restorecon "$file" 2>/dev/null || true; fi
    log "Wrote $file: $line"

    if reload_exports && is_exported "$real"; then
        ok "$real is now exported."
    else
        err "exportfs did not accept the new export; rolling back $file."
        if [[ -n $prev ]]; then cp -a -- "$prev" "$file"; else rm -f -- "$file"; fi
        reload_exports || warn "exportfs still reports problems; check /etc/exports and $EXPORTS_DIR/."
        if [[ -n $old_perm ]]; then
            chown "${old_perm% *}" "$real"
            set_mode "${old_perm#* }" "$real"
            info "Restored the original owner and mode of $real."
        fi
        if (( created )); then info "The directory $real was created and has been left in place."; fi
        return 0
    fi

    if selinux_active; then
        if [[ $line == *"(rw,"* ]]; then check_selinux_bool nfs_export_all_rw; fi
        check_selinux_bool nfs_export_all_ro
    fi
    print_client_hint "$real"
}

remove_export() {
    header "Remove an NFS export"
    local f p idx
    local -a files=() labels=()
    for f in "$EXPORTS_DIR"/*.exports; do
        [[ -f $f ]] || continue
        if is_managed "$f"; then
            p=$(awk '!/^[[:space:]]*(#|$)/ {print $1; exit}' "$f")
            files+=("$f")
            labels+=("${p:-?}   ($f)")
        fi
    done
    if (( ${#files[@]} == 0 )); then
        info "There are no exports created by this script. Exports in /etc/exports must be removed by hand."
        return 0
    fi
    labels+=("Cancel")
    choose idx "Export to remove" "${#labels[@]}" "${labels[@]}"
    if (( idx == ${#labels[@]} )); then info "Cancelled."; return 0; fi
    f=${files[idx - 1]}

    grep -v -e '^#' "$f" | sed 's/^/    /' || true
    warn "Clients that have this export mounted will get 'Stale file handle' errors."
    if ! confirm "Stop exporting this? The directory and its data are NOT deleted." n; then
        info "Cancelled."
        return 0
    fi
    backup_file "$f"
    rm -f -- "$f"
    log "Removed $f"
    if reload_exports; then
        ok "Export removed. Backup of the definition: $LAST_BACKUP"
    else
        warn "Removed $f, but exportfs reported problems (shown above)."
    fi
}

list_exports() {
    header "Active exports (exportfs -v)"
    local out f
    out=$(exportfs -v 2>&1 || true)
    if [[ -n $out ]]; then printf '%s\n' "$out"; else info "Nothing is exported right now."; fi

    header "Export definition files"
    for f in /etc/exports "$EXPORTS_DIR"/*.exports; do
        [[ -f $f ]] || continue
        if ! grep -qv -e '^[[:space:]]*#' -e '^[[:space:]]*$' "$f"; then continue; fi
        if is_managed "$f"; then
            printf '%s%s%s  (managed by this script)\n' "$C_BLD" "$f" "$C_RST"
        else
            printf '%s%s%s\n' "$C_BLD" "$f" "$C_RST"
        fi
        grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' "$f" | sed 's/^/    /' || true
    done
}

show_status() {
    header "NFS server status"
    printf '  nfs-server active  : %s\n' "$(systemctl is-active nfs-server.service 2>/dev/null || true)"
    printf '  nfs-server at boot : %s\n' "$(systemctl is-enabled nfs-server.service 2>/dev/null || true)"
    if nfsv3_enabled; then
        printf '  Configured versions: NFSv3 + NFSv4\n'
        printf '  NFSv3 lock ports   : lockd %s/tcp %s/udp, statd %s\n' \
            "$(conf_get lockd port)" "$(conf_get lockd udp-port)" "$(conf_get statd port)"
    else
        printf '  Configured versions: NFSv4 only\n'
    fi
    if [[ -r /proc/fs/nfsd/versions ]]; then
        printf '  Kernel nfsd serving: %s\n' "$(cat /proc/fs/nfsd/versions 2>/dev/null || true)"
    fi
    if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
        local zone
        # Every active zone, not just the default: NFS may have been opened in another one.
        while read -r zone; do
            printf '  firewalld %-9s: services: %s | ports: %s\n' "$zone" \
                "$(firewall-cmd --zone="$zone" --list-services 2>/dev/null || true)" \
                "$(firewall-cmd --zone="$zone" --list-ports 2>/dev/null || true)"
        done < <(firewall-cmd --get-active-zones 2>/dev/null | awk '/^[^[:space:]]/ {print $1}' || true)
    else
        printf '  firewalld          : not running\n'
    fi
    if selinux_active; then
        printf '  SELinux            : %s\n' "$(getenforce)"
    fi
    list_exports
}

full_setup() {
    install_packages
    if ! is_installed nfs-utils; then
        warn "Setup cannot continue without nfs-utils."
        return 0
    fi
    configure_versions
    start_services
    configure_firewall
    check_selinux
    if confirm "Add an export now?" y; then add_export; fi
}

# ----------------------------------------------------------------------------
#  Main menu
# ----------------------------------------------------------------------------
main() {
    trap 'on_error $? $LINENO "$BASH_COMMAND"' ERR
    trap 'printf "\n"; warn "Interrupted."; exit 130' INT
    trap 'printf "\n"; warn "Terminated."; exit 143' TERM
    trap cleanup EXIT

    printf '%sNFS server setup for RHEL 9%s\n' "$C_BLD" "$C_RST"
    require_root
    check_os
    log "---- $SCRIPT_NAME started ----"

    local action default
    while true; do
        default=1
        if is_installed nfs-utils && systemctl is-active --quiet nfs-server.service; then default=2; fi
        header "Main menu"
        choose action "Choose an action" "$default" \
            "Full setup (install, versions, service, firewall, SELinux, first export)" \
            "Add an export" \
            "Remove an export" \
            "List exports" \
            "Show NFS server status" \
            "Quit"
        case $action in
            1) full_setup ;;
            2) if need_nfs_utils; then add_export; fi ;;
            3) if need_nfs_utils; then remove_export; fi ;;
            4) if need_nfs_utils; then list_exports; fi ;;
            5) if need_nfs_utils; then show_status; fi ;;
            6) break ;;
        esac
    done

    if [[ -n $BACKUP_DIR ]]; then info "Backups of changed files: $BACKUP_DIR"; fi
    ok "Done."
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
