#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# PATCH-01 / AI-01  --  Phase 0 : base system bootstrap
#
#   1. Detects the OS (Enterprise Linux family) and warns instead of refusing
#   2. Verifies package repositories are usable before touching anything
#   3. Installs required packages, tolerating optional ones that are absent
#   4. Discovers unused block devices and builds LVM storage, or extends an
#      existing volume group, or skips storage entirely
#   5. Creates the platform directory tree and records a machine-readable
#      baseline for later phases
#
# Design rules:
#   - Never modifies a device that is mounted, has holders, is an LVM PV,
#     or carries the root filesystem.
#   - A device with any existing signature requires typed confirmation.
#   - /etc/fstab is backed up and rolled back if the new mount fails.
#   - Re-running is safe: completed steps are detected and skipped.
#
# Usage:
#   ./patch01-bootstrap.sh                     interactive
#   ./patch01-bootstrap.sh --dry-run           show the plan, change nothing
#   ./patch01-bootstrap.sh --yes               non-interactive, safe defaults
#   ./patch01-bootstrap.sh --no-storage        packages and directories only
#   ./patch01-bootstrap.sh --base /data/patch  preset the base directory
#   ./patch01-bootstrap.sh --role AI-01        bootstrap the inference host
#   ./patch01-bootstrap.sh --keep-graphroot    leave Podman storage at the default
#   ./patch01-bootstrap.sh --no-selinux         skip SELinux labelling quietly
#   ./patch01-bootstrap.sh --no-firewalld       skip firewalld handling quietly
#   ./patch01-bootstrap.sh --force             re-run even if already complete
#   ./patch01-bootstrap.sh --reset             tear down a previous run (refuses
#                                              if it finds real data)
# ---------------------------------------------------------------------------

set -Eeuo pipefail
umask 027

VERSION="0.9.0"

ETC_DIR="/etc/patch-platform"
LOG_DIR="/var/log/patch-platform"
STATE_DIR="/var/lib/patch-platform"

ROLE="PATCH-01"
PATCH_BASE=""
DRY_RUN=no
ASSUME_YES=no
DO_STORAGE=yes
FORCE=no
RELOCATE_PODMAN=yes
DO_RESET=no
DO_SELINUX=auto      # auto | no  -- 'no' skips labelling silently
DO_FIREWALL=auto     # auto | no  -- 'no' skips firewalld checks silently

# Storage plan, filled in during discovery
STORAGE_MODE="skip"          # newvg | extend | skip
STORAGE_DEVICES=()
STORAGE_VG=""
STORAGE_LAYOUT="split"
STORAGE_FSTYPE="xfs"
VOL_TABLE=()
TOTAL_PCT=0
STORAGE_MOUNT=""
FSTAB_BACKUP=""

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

while (($#)); do
  case "$1" in
    --dry-run)    DRY_RUN=yes ;;
    --yes|-y)     ASSUME_YES=yes ;;
    --no-storage) DO_STORAGE=no ;;
    --keep-graphroot) RELOCATE_PODMAN=no ;;
    --no-selinux)     DO_SELINUX=no ;;
    --no-firewalld)   DO_FIREWALL=no ;;
    --force)      FORCE=yes ;;
    --reset)      DO_RESET=yes ;;
    --base)       PATCH_BASE="${2:-}"; shift ;;
    --role)       ROLE="${2:-}"; shift ;;
    -h|--help)    sed -n '2,32p' "$0"; exit 0 ;;
    *)            echo "Unknown option: $1  (try --help)" >&2; exit 2 ;;
  esac
  shift
done

case "$ROLE" in
  PATCH-01|AI-01) ;;
  *) echo "Role must be PATCH-01 or AI-01. Got: $ROLE" >&2; exit 2 ;;
esac

# ---------------------------------------------------------------------------
# Logging and output helpers
# ---------------------------------------------------------------------------

mkdir -p "$ETC_DIR" "$LOG_DIR" "$STATE_DIR"
LOG_FILE="$LOG_DIR/phase0-$(date +%Y%m%d-%H%M%S).log"
: >"$LOG_FILE"
chmod 0600 "$LOG_FILE"

log()  { printf '%s  %s\n' "$(date '+%F %T')" "$*" >>"$LOG_FILE"; }
say()  { printf '%s\n' "$*"; log "OUT: $*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; log "WARN: $*"; }
step() { printf '\n==> %s\n' "$*"; log "STEP: $*"; }

die() {
  local m="$1"
  log "FATAL: $m"
  printf '\nERROR: %s\nLog: %s\n' "$m" "$LOG_FILE" >&2
  exit 1
}

trap 'rc=$?; [[ $rc -ne 0 ]] && log "TRAP rc=$rc line=${BASH_LINENO[0]:-$LINENO} cmd=${BASH_COMMAND:-?}"; exit $rc' ERR

# run: execute a command, honouring --dry-run, logging both ways
run() {
  if [[ "$DRY_RUN" == yes ]]; then
    printf '  [dry-run] %s\n' "$*"
    log "DRYRUN: $*"
    return 0
  fi
  log "EXEC: $*"
  if ! "$@" >>"$LOG_FILE" 2>&1; then
    return 1
  fi
}

# confirm: yes/no question. --yes answers yes; a default of "n" still needs a
# real answer even under --yes, so destructive paths are never auto-approved.
confirm() {
  local prompt="$1" default="${2:-y}" reply
  if [[ "$ASSUME_YES" == yes && "$default" == y ]]; then
    log "AUTO-YES: $prompt"
    return 0
  fi
  if [[ ! -t 0 ]]; then
    log "NON-TTY, using default '$default': $prompt"
    [[ "$default" == y ]]
    return
  fi
  local hint="[Y/n]"; [[ "$default" == y ]] || hint="[y/N]"
  read -r -p "$prompt $hint: " reply || true
  reply="${reply:-$default}"
  [[ "${reply,,}" =~ ^(y|yes)$ ]]
}

# ask: free-text prompt with a default
ask() {
  local prompt="$1" default="${2:-}" reply
  if [[ "$ASSUME_YES" == yes || ! -t 0 ]]; then
    printf '%s' "$default"
    return 0
  fi
  read -r -p "$prompt [$default]: " reply || true
  printf '%s' "${reply:-$default}"
}

# ---------------------------------------------------------------------------
# Preconditions
# ---------------------------------------------------------------------------

step "Checking preconditions"

[[ $EUID -eq 0 ]] || die "Run as root."

for c in awk sed grep df findmnt lsblk; do
  command -v "$c" >/dev/null 2>&1 || die "Required core utility missing: $c"
done

if [[ -e "$STATE_DIR/PHASE0_COMPLETE" && "$FORCE" != yes ]]; then
  say "Phase 0 already completed on $(cat "$STATE_DIR/PHASE0_COMPLETE" 2>/dev/null || echo 'unknown date')."
  if [[ -f "$ETC_DIR/phase0.env" ]]; then
    say "Existing configuration:"
    sed 's/^/    /' "$ETC_DIR/phase0.env"
  fi
  confirm "Re-run phase 0 and overwrite this configuration?" n \
    || { say "Nothing to do. Use --force to skip this prompt."; exit 0; }
fi

# ---------------------------------------------------------------------------
# Reset
#
# Tears down a previous phase 0 run so the script can be re-run with a
# different layout. Deliberately conservative:
#   - Reads what the previous run recorded rather than guessing.
#   - Refuses outright if it finds repository content, a populated database,
#     container images or anything else that looks like real data.
#   - Only removes a volume group and physical volumes if the earlier run
#     created them. A pre-existing VG is never touched.
#   - Requires the base path to be typed out in full.
# ---------------------------------------------------------------------------

reset_platform() {
  step "Reset requested"

  local conf="$ETC_DIR/phase0.env"
  local r_base r_vg r_vols r_vgcreated r_pvs r_graphroot
  local mounts=() lvs=()

  if [[ -f "$conf" ]]; then
    # Read values without sourcing, so a tampered file cannot execute
    r_base="$(grep -E '^PP_BASE=' "$conf" | cut -d= -f2- || true)"
    r_vg="$(grep -E '^PP_STORAGE_VG=' "$conf" | cut -d= -f2- || true)"
    r_vols="$(grep -E '^PP_STORAGE_VOLUMES=' "$conf" | cut -d= -f2- | tr -d '"' || true)"
    r_vgcreated="$(grep -E '^PP_VG_CREATED=' "$conf" | cut -d= -f2- || echo unknown)"
    r_pvs="$(grep -E '^PP_PVS=' "$conf" | cut -d= -f2- | tr -d '"' || true)"
    r_graphroot="$(grep -E '^PP_PODMAN_GRAPHROOT=' "$conf" | cut -d= -f2- || true)"
    say "Found a previous run recorded in $conf"
  else
    warn "No $conf found. Falling back to the values given on the command line."
    r_base="${PATCH_BASE:-}"
    r_vg=""
    r_vols=""
    r_vgcreated=unknown
    r_pvs=""
    r_graphroot=""
  fi

  [[ -n "$r_base" ]] || r_base="$(ask "Base directory that was used" "/patch")"
  [[ "$r_base" == /* ]] || die "Base directory must be absolute."
  r_base="${r_base%/}"
  case "$r_base" in
    ""|/|/bin|/boot|/dev|/etc|/home|/lib|/lib64|/proc|/root|/run|/sbin|/sys|/tmp|/usr|/var)
      die "Refusing to reset the system directory: $r_base" ;;
  esac

  say "Base:          $r_base"
  say "Volume group:  ${r_vg:-none recorded}"
  say "VG created by this script: $r_vgcreated"

  # ---- Safety gate 1: look for real data -------------------------------
  local danger=0

  # Currently mounted filesystems under the base
  while read -r mp; do
    [[ -n "$mp" ]] && mounts+=("$mp") || true
  done < <(findmnt -rno TARGET 2>/dev/null | grep -E "^${r_base}(/|$)" | sort -r || true)

  local mp used
  for mp in "${mounts[@]}"; do
    used="$(df -PB1 "$mp" 2>/dev/null | awk 'NR==2{print $3}' || echo 0)"
    # more than 100 MB used means something is actually stored there
    if [[ "$used" =~ ^[0-9]+$ ]] && (( used > 104857600 )); then
      warn "$mp holds $(numfmt --to=iec "$used" 2>/dev/null || echo "$used bytes") of data"
      danger=$((danger+1))
    fi
  done

  if [[ -d "$r_base/data/postgres" ]] && [[ -n "$(ls -A "$r_base/data/postgres" 2>/dev/null || true)" ]]; then
    warn "$r_base/data/postgres is not empty - this may be a live database"
    danger=$((danger+1))
  fi
  if [[ -d "$r_base/data/pulp/artifact" ]]; then
    warn "$r_base/data/pulp/artifact exists - Pulp may hold repository content"
    danger=$((danger+1))
  fi

  local img_count=0
  if command -v podman >/dev/null 2>&1; then
    img_count="$(podman images -q 2>/dev/null | sort -u | wc -l || echo 0)"
    if (( img_count > 0 )); then
      warn "$img_count container image(s) present - these will become inaccessible"
      danger=$((danger+1))
    fi
  fi

  if (( danger > 0 )); then
    warn ""
    warn "$danger indication(s) of real data were found."
    warn "Reset is intended for a fresh install that has not been used yet."
    warn "If this is a working system, back up PostgreSQL first - the Pulp"
    warn "artifacts are meaningless without the database."
    confirm "Continue and DESTROY the above anyway?" n \
      || { say "Reset aborted. Nothing was changed."; exit 0; }
  else
    say "No repository content, database or images found - this looks unused."
  fi

  # ---- Safety gate 2: typed confirmation -------------------------------
  say ""
  say "This will unmount and delete:"
  for mp in "${mounts[@]}"; do say "  mount  $mp"; done
  if [[ -n "$r_vols" && -n "$r_vg" ]]; then
    local entry vname vpath vpct
    for entry in $r_vols; do
      IFS=: read -r vname vpath vpct <<<"$entry"
      say "  volume /dev/$r_vg/$vname"
      lvs+=("/dev/$r_vg/$vname")
    done
  fi
  if [[ "$r_vgcreated" == yes && -n "$r_vg" ]]; then
    say "  volume group $r_vg"
    [[ -n "$r_pvs" ]] && say "  physical volume(s) $r_pvs" || true
  elif [[ -n "$r_vg" ]]; then
    say "  volume group $r_vg will be LEFT IN PLACE (not created by this script)"
  fi
  say ""

  local typed
  typed="$(ask "Type the base path exactly to confirm ($r_base)" "")"
  [[ "$typed" == "$r_base" ]] || die "Confirmation did not match. Nothing was changed."

  if [[ "$DRY_RUN" == yes ]]; then
    say "[dry-run] Reset would proceed here. Nothing was changed."
    exit 0
  fi

  # ---- Teardown --------------------------------------------------------
  step "Tearing down"

  if command -v podman >/dev/null 2>&1; then
    say "Stopping containers"
    podman stop --all --time 30 >>"$LOG_FILE" 2>&1 || true
  fi

  # Restore the Podman graph root before unmounting, or Podman ends up
  # pointing at a path that no longer exists
  if [[ -n "$r_graphroot" && "$r_graphroot" != default ]]; then
    local sc_bak
    sc_bak="$(ls -t /etc/containers/storage.conf.phase0-*.bak 2>/dev/null | head -1 || true)"
    if [[ -n "$sc_bak" ]]; then
      cp -a "$sc_bak" /etc/containers/storage.conf
      say "Restored /etc/containers/storage.conf from $sc_bak"
    elif [[ -f /etc/containers/storage.conf ]]; then
      mv /etc/containers/storage.conf "/etc/containers/storage.conf.reset-$(date +%Y%m%d-%H%M%S).bak"
      say "Moved storage.conf aside; Podman reverts to its built-in default."
    fi
  fi

  # Unmount deepest first
  for mp in "${mounts[@]}"; do
    if umount "$mp" >>"$LOG_FILE" 2>&1; then
      say "Unmounted $mp"
    else
      warn "Could not unmount $mp - trying lazy unmount"
      umount -l "$mp" >>"$LOG_FILE" 2>&1 || warn "Still could not unmount $mp"
    fi
  done

  # Remove fstab entries for the base tree, keeping a backup
  if grep -qsE "[[:space:]]${r_base}(/[^[:space:]]*)?[[:space:]]" /etc/fstab; then
    local fb="/etc/fstab.reset-$(date +%Y%m%d-%H%M%S).bak"
    cp -a /etc/fstab "$fb"
    sed -i -E "\|[[:space:]]${r_base}(/[^[:space:]]*)?[[:space:]]|d" /etc/fstab
    say "Removed fstab entries for $r_base (backup: $fb)"
  fi

  # Remove logical volumes
  local lv
  for lv in "${lvs[@]}"; do
    if [[ -e "$lv" ]]; then
      lvremove -f "$lv" >>"$LOG_FILE" 2>&1 && say "Removed $lv" || warn "Could not remove $lv"
    fi
  done

  # Catch any leftover LVs in the VG that the record missed
  if [[ -n "$r_vg" ]] && vgs --noheadings -o vg_name 2>/dev/null | grep -qw "$r_vg"; then
    local leftover
    leftover="$(lvs --noheadings -o lv_name "$r_vg" 2>/dev/null | tr -d ' ' | tr '\n' ' ' || true)"
    if [[ -n "${leftover// /}" ]]; then
      warn "Volume group $r_vg still contains: $leftover"
      if confirm "Remove these too?" n; then
        for lv in $leftover; do
          lvremove -f "/dev/$r_vg/$lv" >>"$LOG_FILE" 2>&1 && say "Removed $lv" || true
        done
      fi
    fi
  fi

  # Only dismantle the VG and PVs if this script built them
  if [[ "$r_vgcreated" == yes && -n "$r_vg" ]]; then
    vgremove -f "$r_vg" >>"$LOG_FILE" 2>&1 && say "Removed volume group $r_vg" \
      || warn "Could not remove volume group $r_vg"
    local pv
    for pv in $r_pvs; do
      pvremove -f "$pv" >>"$LOG_FILE" 2>&1 && say "Removed physical volume $pv" || true
      wipefs -a "$pv" >>"$LOG_FILE" 2>&1 && say "Wiped signatures on $pv" || true
    done
  elif [[ -n "$r_vg" ]]; then
    say "Left volume group $r_vg in place, as this script did not create it."
  fi

  # Remove the now-empty directory tree
  if [[ -d "$r_base" ]]; then
    if rmdir -p --ignore-fail-on-non-empty "$r_base"/* 2>/dev/null; then :; fi
    if [[ -n "$(ls -A "$r_base" 2>/dev/null || true)" ]]; then
      warn "$r_base is not empty; leaving it in place for inspection."
    else
      rmdir "$r_base" 2>/dev/null && say "Removed $r_base" || true
    fi
  fi

  # Clear phase 0 state
  rm -f "$STATE_DIR/PHASE0_COMPLETE" "$STATE_DIR/phase0-report.txt"
  rm -f "$ETC_DIR/phase0.env" "$ETC_DIR/proxy.env"
  say "Cleared the phase 0 state."

  echo
  echo "================================================================"
  echo " RESET COMPLETE"
  echo "================================================================"
  if command -v podman >/dev/null 2>&1; then
    printf ' Podman graph root: %s\n' "$(podman info --format '{{.Store.GraphRoot}}' 2>/dev/null || echo unknown)"
  fi
  printf ' Log: %s\n' "$LOG_FILE"
  echo
  echo " Re-run without --reset to build the new layout."
  exit 0
}

if [[ "$DO_RESET" == yes ]]; then
  reset_platform
fi

# ---------------------------------------------------------------------------
# OS detection -- flexible: recognise the family, warn on anything unexpected
# ---------------------------------------------------------------------------

step "Detecting operating system"

[[ -r /etc/os-release ]] || die "/etc/os-release is missing or unreadable."
# shellcheck disable=SC1091
source /etc/os-release

OS_ID="${ID:-unknown}"
OS_VER="${VERSION_ID:-0}"
OS_MAJOR="${OS_VER%%.*}"
OS_PRETTY="${PRETTY_NAME:-$OS_ID $OS_VER}"
ARCH="$(uname -m)"

EL_FAMILY=no
case "$OS_ID" in
  rhel|ol|rocky|almalinux|centos) EL_FAMILY=yes ;;
  *)
    if [[ " ${ID_LIKE:-} " == *" rhel "* || " ${ID_LIKE:-} " == *" fedora "* ]]; then
      EL_FAMILY=yes
    fi
    ;;
esac

say "OS:     $OS_PRETTY"
say "Arch:   $ARCH"
say "Family: $([[ "$EL_FAMILY" == yes ]] && echo "Enterprise Linux" || echo "$OS_ID (unrecognised)")"

if [[ "$EL_FAMILY" != yes ]]; then
  warn "This script targets the Enterprise Linux family (RHEL, Oracle Linux, Rocky, Alma)."
  confirm "Continue anyway? Package names may not resolve." n || exit 0
fi

if ! command -v dnf >/dev/null 2>&1; then
  command -v yum >/dev/null 2>&1 || die "Neither dnf nor yum is available."
  PKG=yum
  warn "dnf not found, falling back to yum."
else
  PKG=dnf
fi

case "$OS_MAJOR" in
  8|9|10) : ;;
  *) warn "Untested major version: $OS_MAJOR (expected 8, 9 or 10)."
     confirm "Continue?" n || exit 0 ;;
esac

if [[ "$ARCH" != x86_64 && "$ARCH" != aarch64 ]]; then
  warn "Unusual architecture: $ARCH"
  confirm "Continue?" n || exit 0
fi

# ---------------------------------------------------------------------------
# Repository reachability -- fail here with a clear message rather than
# letting the first install fail with an opaque dnf error
# ---------------------------------------------------------------------------

step "Checking package repositories"

REPO_COUNT=0
REPO_COUNT="$($PKG repolist --enabled 2>/dev/null | grep -cE '^[^ ]' || true)"
log "enabled repo lines: $REPO_COUNT"

if (( REPO_COUNT < 2 )); then
  warn "Few or no enabled repositories were detected."
  if [[ "$OS_ID" == rhel ]] && command -v subscription-manager >/dev/null 2>&1; then
    SUB_STATUS="$(subscription-manager status 2>&1 | grep -i 'Overall Status' || echo 'Overall Status: unknown')"
    say "  $SUB_STATUS"
    say "  If unsubscribed, run: subscription-manager register --auto-attach"
  fi
  confirm "Continue and let the package manager report its own errors?" n || exit 0
fi

if ! $PKG makecache --refresh >>"$LOG_FILE" 2>&1; then
  warn "Metadata refresh failed. Check the proxy or repository configuration."
  confirm "Continue anyway?" n || exit 0
else
  say "Repository metadata is usable."
fi

# ---------------------------------------------------------------------------
# Package installation -- required vs optional
# ---------------------------------------------------------------------------

step "Installing packages"

# Required: the script or the platform genuinely cannot proceed without these
REQUIRED=(podman lvm2 xfsprogs e2fsprogs util-linux tar gzip curl openssl jq policycoreutils-python-utils)
# Optional: nice to have, absence is logged and tolerated
OPTIONAL=(newt python3 python3-pip rsync unzip git chrony firewalld setroubleshoot-server bash-completion)

[[ "$ROLE" == "PATCH-01" ]] && OPTIONAL+=(skopeo buildah) || true

want_install=()
for p in "${REQUIRED[@]}" "${OPTIONAL[@]}"; do
  rpm -q "$p" >/dev/null 2>&1 || want_install+=("$p")
done

if ((${#want_install[@]} == 0)); then
  say "All packages already present."
else
  say "To install: ${want_install[*]}"
  confirm "Install these from the configured repositories?" y || exit 0

  # First attempt: one transaction. --skip-broken keeps an unavailable
  # optional package from aborting the whole set.
  if ! run $PKG install -y --skip-broken --setopt=install_weak_deps=False "${want_install[@]}"; then
    warn "Bulk install failed; retrying package by package."
    for p in "${want_install[@]}"; do
      if run $PKG install -y "$p"; then
        log "installed: $p"
      else
        warn "Could not install: $p"
      fi
    done
  fi
fi

# Verify only the required set; optional failures are already logged
MISSING_REQUIRED=()
if [[ "$DRY_RUN" != yes ]]; then
  for p in "${REQUIRED[@]}"; do
    rpm -q "$p" >/dev/null 2>&1 || MISSING_REQUIRED+=("$p")
  done
fi
if ((${#MISSING_REQUIRED[@]} > 0)); then
  die "Required packages are still missing: ${MISSING_REQUIRED[*]}"
fi
say "Required packages satisfied."

for c in podman pvcreate vgcreate lvcreate mkfs.xfs; do
  command -v "$c" >/dev/null 2>&1 || [[ "$DRY_RUN" == yes ]] \
    || warn "Expected command not on PATH after install: $c"
done

# ---------------------------------------------------------------------------
# Storage discovery
# ---------------------------------------------------------------------------

ROOT_SRC="$(findmnt -n -o SOURCE / 2>/dev/null || echo none)"
ROOT_DISK=""
if [[ "$ROOT_SRC" != none ]]; then
  ROOT_DISK="$(lsblk -no PKNAME "$ROOT_SRC" 2>/dev/null | head -1 || true)"
fi

# device_state <dev>  ->  free | inuse:<reason> | signature:<type>
device_state() {
  local dev="$1" base holders fstype parts mnt size
  base="$(basename "$dev")"

  # Pseudo and removable devices are never valid targets
  case "$base" in
    zram*|loop*|ram*|dm-*|sr*|fd*)
      printf 'inuse:pseudo or removable device'; return ;;
  esac

  # lsblk is more reliable than blockdev, which can return 0 without privileges
  size="$(lsblk -bdno SIZE "$dev" 2>/dev/null | tr -d ' ' || true)"
  if [[ "$size" =~ ^[0-9]+$ ]] && (( size > 0 && size < 1073741824 )); then
    printf 'inuse:smaller than 1 GiB'; return
  fi

  if [[ -n "$ROOT_DISK" && "$base" == "$ROOT_DISK" ]]; then
    printf 'inuse:carries the root filesystem'; return
  fi

  holders="$(ls -1 "/sys/block/$base/holders" 2>/dev/null | wc -l || echo 0)"
  if (( holders > 0 )); then
    printf 'inuse:has device-mapper holders'; return
  fi

  mnt="$(lsblk -no MOUNTPOINTS "$dev" 2>/dev/null | grep -v '^\s*$' | head -1 || true)"
  if [[ -n "$mnt" ]]; then
    printf 'inuse:mounted at %s' "$mnt"; return
  fi

  if command -v pvs >/dev/null 2>&1; then
    if pvs --noheadings -o pv_name 2>/dev/null | grep -qw "$dev"; then
      printf 'inuse:already an LVM physical volume'; return
    fi
  fi

  parts="$(lsblk -no NAME "$dev" 2>/dev/null | wc -l || echo 1)"
  if (( parts > 1 )); then
    printf 'signature:partition table'; return
  fi

  fstype="$(blkid -p -o value -s TYPE "$dev" 2>/dev/null || true)"
  if [[ -n "$fstype" ]]; then
    printf 'signature:%s' "$fstype"; return
  fi

  printf 'free'
}

CANDIDATES=()
declare -A DEV_SIZE=() DEV_STATE=() DEV_MODEL=()

if [[ "$DO_STORAGE" == yes ]]; then
  step "Discovering block devices"

  while read -r name size type model; do
    [[ "$type" == disk ]] || continue
    st="$(device_state "$name")"
    DEV_SIZE["$name"]="$size"
    DEV_STATE["$name"]="$st"
    DEV_MODEL["$name"]="${model:-}"
    printf '  %-14s %-9s %-12s %s\n' "$name" "$size" "${st%%:*}" "${st#*:}"
    [[ "$st" == free* || "$st" == signature* ]] && CANDIDATES+=("$name") || true
  done < <(lsblk -dnpo NAME,SIZE,TYPE,MODEL 2>/dev/null || true)

  if ((${#CANDIDATES[@]} == 0)); then
    say "No usable spare devices found."
  fi
fi

# ---------------------------------------------------------------------------
# Storage plan
# ---------------------------------------------------------------------------

if [[ "$DO_STORAGE" == yes ]]; then
  step "Planning storage"

  EXISTING_VGS=()
  if command -v vgs >/dev/null 2>&1; then
    while read -r vg vfree; do
      [[ -n "$vg" ]] && EXISTING_VGS+=("$vg ($vfree free)") || true
    done < <(vgs --noheadings -o vg_name,vg_free --units g 2>/dev/null | awk '{print $1" "$2}' || true)
  fi

  say "Options:"
  say "  1) Create a new volume group from spare device(s)"
  say "  2) Create a logical volume in an existing volume group"
  say "  3) Skip storage - use a directory on the current filesystem"
  ((${#EXISTING_VGS[@]})) && say "     existing VGs: ${EXISTING_VGS[*]}" || true

  CHOICE="$(ask "Choose 1, 2 or 3" "$( ((${#CANDIDATES[@]})) && echo 1 || echo 3 )")"

  case "$CHOICE" in
    1)
      ((${#CANDIDATES[@]})) || die "No spare devices available for a new volume group."
      say "Candidate devices: ${CANDIDATES[*]}"
      picked="$(ask "Device(s) to use, space separated" "${CANDIDATES[0]}")"
      read -r -a STORAGE_DEVICES <<<"$picked"

      for d in "${STORAGE_DEVICES[@]}"; do
        [[ -b "$d" ]] || die "Not a block device: $d"
        st="${DEV_STATE[$d]:-$(device_state "$d")}"
        case "$st" in
          inuse:*)
            die "Refusing to use $d - ${st#inuse:}" ;;
          signature:*)
            warn "$d carries an existing ${st#signature:}. ALL DATA ON IT WILL BE DESTROYED."
            typed="$(ask "Type the device path exactly to confirm erasure of $d" "")"
            [[ "$typed" == "$d" ]] || die "Confirmation did not match. Aborting without changes." ;;
        esac
      done

      STORAGE_MODE=newvg
      STORAGE_VG="$(ask "New volume group name" "vg_patch")"
      [[ "$STORAGE_VG" =~ ^[a-zA-Z0-9._+-]+$ ]] || die "Invalid volume group name."
      if command -v vgs >/dev/null 2>&1 && vgs --noheadings -o vg_name 2>/dev/null | grep -qw "$STORAGE_VG"; then
        die "Volume group $STORAGE_VG already exists. Choose option 2 to use it."
      fi
      ;;
    2)
      ((${#EXISTING_VGS[@]})) || die "No existing volume groups found."
      STORAGE_MODE=extend
      STORAGE_VG="$(ask "Existing volume group to use" "${EXISTING_VGS[0]%% *}")"
      vgs --noheadings -o vg_name 2>/dev/null | grep -qw "$STORAGE_VG" \
        || die "Volume group not found: $STORAGE_VG"
      ;;
    *)
      STORAGE_MODE=skip
      say "Storage step will be skipped."
      ;;
  esac

  if [[ "$STORAGE_MODE" != skip ]]; then
    STORAGE_FSTYPE="$(ask "Filesystem type (xfs or ext4)" "xfs")"
    case "$STORAGE_FSTYPE" in
      xfs|ext4) ;;
      *) die "Unsupported filesystem: $STORAGE_FSTYPE" ;;
    esac

    say ""
    say "Volume layout:"
    say "  single) one volume for everything - simplest, no stranded space,"
    say "          but a runaway repository sync can fill the same filesystem"
    say "          as the database and the backups."
    say "  split)  a separate volume per function - a full repository volume"
    say "          cannot take down PostgreSQL or destroy the backups."
    STORAGE_LAYOUT="$(ask "Layout (single or split)" "split")"
    case "$STORAGE_LAYOUT" in
      single|split) ;;
      *) die "Layout must be 'single' or 'split'." ;;
    esac

    # Volume table: lvname:relative-path-under-base:percent-of-VG
    # Percentages of the whole VG, so the same table works on any disk size.
    # The remainder is deliberately left as free extents for LVM snapshots
    # before upgrades, and for growing whichever volume fills first.
    if [[ "$STORAGE_LAYOUT" == split ]]; then
      if [[ "$ROLE" == "PATCH-01" ]]; then
        VOL_TABLE=(
          "lv_pulp:data/pulp:60"
          "lv_backups:backups:12"
          "lv_containers:images:9"
          "lv_pgsql:data/postgres:7"
          "lv_logs:logs:2"
          "lv_redis:data/redis:1"
        )
      else
        VOL_TABLE=(
          "lv_models:models:55"
          "lv_containers:images:20"
          "lv_logs:logs:5"
        )
      fi
    else
      VOL_TABLE=("lv_patch::88")
    fi

    # Validate the table and check for name collisions up front
    TOTAL_PCT=0
    for entry in "${VOL_TABLE[@]}"; do
      IFS=: read -r vname vpath vpct <<<"$entry"
      [[ "$vname" =~ ^[a-zA-Z0-9._+-]+$ ]] || die "Invalid volume name in table: $vname"
      [[ "$vpct" =~ ^[0-9]{1,3}$ ]] || die "Invalid percentage for $vname: $vpct"
      TOTAL_PCT=$((TOTAL_PCT + vpct))
      if lvs --noheadings -o lv_name "$STORAGE_VG" 2>/dev/null | grep -qw "$vname"; then
        die "Logical volume $STORAGE_VG/$vname already exists. Remove it or choose another VG."
      fi
    done
    (( TOTAL_PCT > 0 && TOTAL_PCT <= 95 )) \
      || die "Volume table totals ${TOTAL_PCT}% - must be 1-95% to leave snapshot headroom."
    say "Allocating ${TOTAL_PCT}% of the volume group, leaving $((100 - TOTAL_PCT))% free for snapshots."
  fi
fi

# ---------------------------------------------------------------------------
# Base directory
# ---------------------------------------------------------------------------

step "Choosing the base directory"

if [[ -z "$PATCH_BASE" ]]; then
  PATCH_BASE="$(ask "Base directory for platform data" "/patch")"
fi
[[ "$PATCH_BASE" == /* ]] || die "Base directory must be an absolute path."
PATCH_BASE="${PATCH_BASE%/}"

case "$PATCH_BASE" in
  ""|/|/bin|/boot|/dev|/etc|/home|/lib|/lib64|/proc|/root|/run|/sbin|/sys|/tmp|/usr|/var|/var/lib|/var/log)
    die "Refusing to use the system directory: $PATCH_BASE" ;;
esac

[[ "$STORAGE_MODE" != skip ]] && STORAGE_MOUNT="$PATCH_BASE" || true

# If storage is being skipped, check where the base directory actually lands
if [[ "$STORAGE_MODE" == skip ]]; then
  probe="$PATCH_BASE"
  while [[ ! -e "$probe" && "$probe" != "/" ]]; do probe="$(dirname "$probe")"; done
  FS_TARGET="$(findmnt -n -o TARGET -T "$probe" 2>/dev/null || echo unknown)"
  FS_SOURCE="$(findmnt -n -o SOURCE -T "$probe" 2>/dev/null || echo unknown)"
  FS_TYPE="$(findmnt -n -o FSTYPE -T "$probe" 2>/dev/null || echo unknown)"
  FREE_GIB="$(df -PB1 "$probe" 2>/dev/null | awk 'NR==2{printf "%d",$4/1073741824}' || echo 0)"

  say "Base will live on $FS_SOURCE ($FS_TYPE) mounted at $FS_TARGET, ~${FREE_GIB} GiB free."

  if [[ "$FS_TARGET" == "/" ]]; then
    warn "$PATCH_BASE is on the ROOT filesystem. Repository growth can fill / and"
    warn "take down PostgreSQL, journald and the container runtime with it."
    confirm "Continue with the base directory on /?" n || exit 0
  fi

  if [[ "$ROLE" == "PATCH-01" ]] && (( FREE_GIB < 1024 )); then
    warn "Only ~${FREE_GIB} GiB free. RHEL 8/9/10 + Oracle Linux 8/9/10 + Ubuntu"
    warn "repositories need roughly 1-2 TiB with immediate sync on security repos."
    confirm "Continue anyway?" n || exit 0
  fi
else
  FS_SOURCE="vg:$STORAGE_VG"
  FS_TYPE="$STORAGE_FSTYPE"
  FS_TARGET="$PATCH_BASE"
  FREE_GIB=0
fi

# ---------------------------------------------------------------------------
# Plan review
# ---------------------------------------------------------------------------

# print_vol_table: show the planned volumes with resolved sizes
print_vol_table() {
  local vg_size_g="" entry vname vpath vpct mp est
  if [[ "$STORAGE_MODE" == newvg ]]; then
    local total=0 d dsz
    for d in "${STORAGE_DEVICES[@]}"; do
      dsz="$(lsblk -bdno SIZE "$d" 2>/dev/null | tr -d ' ' || echo 0)"
      [[ "$dsz" =~ ^[0-9]+$ ]] && total=$((total + dsz)) || true
    done
    vg_size_g=$((total / 1073741824))
  else
    vg_size_g="$(vgs --noheadings --units g -o vg_size "$STORAGE_VG" 2>/dev/null | tr -dc '0-9.' | cut -d. -f1 || echo 0)"
  fi
  printf '\n  %-16s %-26s %6s  %s\n' "VOLUME" "MOUNT POINT" "SHARE" "APPROX"
  for entry in "${VOL_TABLE[@]}"; do
    IFS=: read -r vname vpath vpct <<<"$entry"
    if [[ -n "$vpath" ]]; then mp="$PATCH_BASE/$vpath"; else mp="$PATCH_BASE"; fi
    if [[ "$vg_size_g" =~ ^[0-9]+$ ]] && (( vg_size_g > 0 )); then
      est="$(( vg_size_g * vpct / 100 ))G"
    else
      est="-"
    fi
    printf '  %-16s %-26s %5s%%  %s\n' "$vname" "$mp" "$vpct" "$est"
  done
  if [[ "$vg_size_g" =~ ^[0-9]+$ ]] && (( vg_size_g > 0 )); then
    printf '  %-16s %-26s %5s%%  %sG  (snapshots, growth)\n' \
      "(unallocated)" "-" "$((100 - TOTAL_PCT))" "$(( vg_size_g * (100 - TOTAL_PCT) / 100 ))"
  fi
  echo
}

step "Plan"

cat <<PLAN
  Role:            $ROLE
  OS:              $OS_PRETTY ($ARCH)
  Base directory:  $PATCH_BASE
  Storage mode:    $STORAGE_MODE
PLAN
if [[ "$STORAGE_MODE" == newvg ]]; then
  cat <<PLAN
  Devices:         ${STORAGE_DEVICES[*]}   (WILL BE ERASED)
  Volume group:    $STORAGE_VG  (new)
  Layout:          $STORAGE_LAYOUT
  Filesystem:      $STORAGE_FSTYPE
PLAN
  print_vol_table
elif [[ "$STORAGE_MODE" == extend ]]; then
  cat <<PLAN
  Volume group:    $STORAGE_VG  (existing)
  Layout:          $STORAGE_LAYOUT
  Filesystem:      $STORAGE_FSTYPE
PLAN
  print_vol_table
else
  echo "  Storage:         using the existing filesystem at $FS_TARGET"
fi
if [[ "$RELOCATE_PODMAN" == yes ]]; then
  echo "  Podman store:    $PATCH_BASE/images/storage  (moved off /var/lib/containers)"
else
  echo "  Podman store:    left at the default location"
fi
echo "  Dry run:         $DRY_RUN"

confirm "Proceed with this plan?" y || { say "Aborted, nothing changed."; exit 0; }

# ---------------------------------------------------------------------------
# Storage execution
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Storage execution
#
# Multiple volumes are created as a unit. If any step fails partway, the
# rollback unwinds in reverse order: unmount what was mounted, restore the
# original fstab, then remove the logical volumes that were created. A partial
# failure must never leave the host with an fstab that breaks the next boot.
# ---------------------------------------------------------------------------

CREATED_LVS=()
MOUNTED_PATHS=()
NEW_PVS=()
NEW_VG=""

rollback_storage() {
  local rc=$?
  if [[ "$DRY_RUN" == yes ]]; then return 0; fi
  warn "Rolling back storage changes..."

  # Unmount in reverse order so nested mounts come off first
  local i
  for (( i=${#MOUNTED_PATHS[@]}-1; i>=0; i-- )); do
    umount "${MOUNTED_PATHS[$i]}" >>"$LOG_FILE" 2>&1 \
      && log "unmounted ${MOUNTED_PATHS[$i]}" \
      || warn "Could not unmount ${MOUNTED_PATHS[$i]}"
  done

  if [[ -n "$FSTAB_BACKUP" && -f "$FSTAB_BACKUP" ]]; then
    cp -a "$FSTAB_BACKUP" /etc/fstab
    warn "Restored /etc/fstab from $FSTAB_BACKUP"
  fi

  for (( i=${#CREATED_LVS[@]}-1; i>=0; i-- )); do
    lvremove -f "${CREATED_LVS[$i]}" >>"$LOG_FILE" 2>&1 \
      && log "removed ${CREATED_LVS[$i]}" \
      || warn "Could not remove ${CREATED_LVS[$i]}"
  done

  # Only remove a VG this script created; never touch a pre-existing one
  if [[ -n "$NEW_VG" ]]; then
    vgremove -f "$NEW_VG" >>"$LOG_FILE" 2>&1 && log "removed vg $NEW_VG" || true
    local pv
    for pv in "${NEW_PVS[@]}"; do
      pvremove -f "$pv" >>"$LOG_FILE" 2>&1 && log "removed pv $pv" || true
    done
  fi

  warn "Rollback complete. The system is back to its previous state."
  return $rc
}

if [[ "$STORAGE_MODE" != skip ]]; then
  step "Building storage"

  if [[ "$STORAGE_MODE" == newvg ]]; then
    for d in "${STORAGE_DEVICES[@]}"; do
      say "Wiping signatures on $d"
      run wipefs -a "$d" || die "wipefs failed on $d"
      run pvcreate -ff -y "$d" || die "pvcreate failed on $d"
      NEW_PVS+=("$d")
    done
    say "Creating volume group $STORAGE_VG"
    run vgcreate "$STORAGE_VG" "${STORAGE_DEVICES[@]}" || die "vgcreate failed."
    NEW_VG="$STORAGE_VG"
  fi

  # From here on, any failure triggers a full rollback
  trap 'rollback_storage; exit 1' ERR

  # Back up fstab once, before the first modification
  if [[ "$DRY_RUN" != yes ]]; then
    FSTAB_BACKUP="/etc/fstab.phase0-$(date +%Y%m%d-%H%M%S).bak"
    cp -a /etc/fstab "$FSTAB_BACKUP"
    log "fstab backed up to $FSTAB_BACKUP"
  fi

  # Pass 1: create every LV and filesystem before touching fstab
  for entry in "${VOL_TABLE[@]}"; do
    IFS=: read -r vname vpath vpct <<<"$entry"
    LV_PATH="/dev/$STORAGE_VG/$vname"

    say "Creating $vname (${vpct}% of the volume group)"
    run lvcreate -l "${vpct}%VG" -n "$vname" "$STORAGE_VG" \
      || die "lvcreate failed for $vname."
    CREATED_LVS+=("$LV_PATH")

    if [[ "$STORAGE_FSTYPE" == xfs ]]; then
      run mkfs.xfs -f "$LV_PATH" || die "mkfs.xfs failed on $vname."
    else
      run mkfs.ext4 -F "$LV_PATH" || die "mkfs.ext4 failed on $vname."
    fi
  done

  # Pass 2: create mount points, add fstab entries, mount
  # Sorted by path depth so parent directories exist before nested mounts
  for entry in "${VOL_TABLE[@]}"; do
    IFS=: read -r vname vpath vpct <<<"$entry"
    LV_PATH="/dev/$STORAGE_VG/$vname"
    if [[ -n "$vpath" ]]; then
      MP="$PATCH_BASE/$vpath"
    else
      MP="$PATCH_BASE"
    fi

    run mkdir -p "$MP" || die "Could not create the mount point $MP."

    if [[ "$DRY_RUN" == yes ]]; then
      printf '  [dry-run] fstab: %s -> %s (%s)\n' "$LV_PATH" "$MP" "$STORAGE_FSTYPE"
      continue
    fi

    FS_UUID="$(blkid -s UUID -o value "$LV_PATH" 2>/dev/null || true)"
    [[ -n "$FS_UUID" ]] || die "Could not read the filesystem UUID for $vname."

    if grep -qs "[[:space:]]${MP}[[:space:]]" /etc/fstab; then
      warn "An fstab entry for $MP already exists; leaving it alone."
    else
      printf 'UUID=%s  %s  %s  defaults,noatime  0 0\n' \
        "$FS_UUID" "$MP" "$STORAGE_FSTYPE" >>/etc/fstab
      log "fstab entry added for $MP"
    fi

    if ! mount "$MP" >>"$LOG_FILE" 2>&1; then
      die "Mounting $MP failed."
    fi
    MOUNTED_PATHS+=("$MP")
    say "  mounted $MP ($(df -Ph "$MP" | awk 'NR==2{print $2}'))"
  done

  # Final gate: a bad fstab must not survive to the next boot
  if [[ "$DRY_RUN" != yes ]]; then
    systemctl daemon-reload >>"$LOG_FILE" 2>&1 || true
    if ! mount -a >>"$LOG_FILE" 2>&1; then
      die "'mount -a' failed, which would break the next boot."
    fi
    say "All volumes mounted and 'mount -a' is clean."
  fi

  # Storage is committed; restore the normal error trap
  trap 'rc=$?; [[ $rc -ne 0 ]] && log "TRAP rc=$rc line=${BASH_LINENO[0]:-$LINENO} cmd=${BASH_COMMAND:-?}"; exit $rc' ERR
fi

# ---------------------------------------------------------------------------
# Directory tree
# ---------------------------------------------------------------------------

step "Creating the directory tree"

if [[ "$ROLE" == "PATCH-01" ]]; then
  DIRS=(
    "$PATCH_BASE"
    "$PATCH_BASE/config" "$PATCH_BASE/config/nginx" "$PATCH_BASE/config/pulp"
    "$PATCH_BASE/config/api" "$PATCH_BASE/config/ui"
    "$PATCH_BASE/data" "$PATCH_BASE/data/pulp" "$PATCH_BASE/data/postgres"
    "$PATCH_BASE/data/redis"
    "$PATCH_BASE/certs" "$PATCH_BASE/secrets"
    "$PATCH_BASE/backups" "$PATCH_BASE/reports" "$PATCH_BASE/logs"
    "$PATCH_BASE/bundles" "$PATCH_BASE/images" "$PATCH_BASE/quadlet"
  )
else
  DIRS=(
    "$PATCH_BASE"
    "$PATCH_BASE/config" "$PATCH_BASE/config/nginx"
    "$PATCH_BASE/models" "$PATCH_BASE/certs" "$PATCH_BASE/secrets"
    "$PATCH_BASE/logs" "$PATCH_BASE/bundles" "$PATCH_BASE/images"
    "$PATCH_BASE/quadlet"
  )
fi

run mkdir -p "${DIRS[@]}" || die "Could not create the directory tree."
if [[ "$DRY_RUN" != yes ]]; then
  chown root:root "${DIRS[@]}"
  chmod 0750 "${DIRS[@]}"
  chmod 0700 "$PATCH_BASE/secrets" "$PATCH_BASE/certs"
fi
say "Created ${#DIRS[@]} directories under $PATCH_BASE"

# ---------------------------------------------------------------------------
# Podman storage relocation
#
# The container image store is moved off the default /var/lib/containers and
# onto the platform volume. This MUST happen before any image is pulled,
# otherwise the images sit on the root filesystem and the new location is
# shadowed and empty.
#
# Note: the store gets SELinux type container_var_lib_t via an equivalency
# rule, NOT container_file_t. Labelling it container_file_t breaks Podman
# under enforcing SELinux, which is why the data directories and the image
# store are handled separately below.
# ---------------------------------------------------------------------------

PODMAN_GRAPHROOT=""

if [[ "$RELOCATE_PODMAN" == yes ]]; then
  step "Pointing Podman at $PATCH_BASE/images"

  PODMAN_GRAPHROOT="$PATCH_BASE/images/storage"
  STORAGE_CONF="/etc/containers/storage.conf"

  CUR_GRAPHROOT="$(podman info --format '{{.Store.GraphRoot}}' 2>/dev/null || echo unknown)"
  say "Current graph root: $CUR_GRAPHROOT"
  say "Target graph root:  $PODMAN_GRAPHROOT"

  if [[ "$CUR_GRAPHROOT" == "$PODMAN_GRAPHROOT" ]]; then
    say "Already configured; nothing to change."
  else
    # Refuse to silently orphan existing content
    IMG_COUNT="$(podman images -q 2>/dev/null | sort -u | wc -l || echo 0)"
    CNT_COUNT="$(podman ps -a -q 2>/dev/null | wc -l || echo 0)"
    VOL_COUNT="$(podman volume ls -q 2>/dev/null | wc -l || echo 0)"
    log "existing content: images=$IMG_COUNT containers=$CNT_COUNT volumes=$VOL_COUNT"

    MIGRATE=no
    if (( IMG_COUNT > 0 || CNT_COUNT > 0 || VOL_COUNT > 0 )); then
      warn "Existing Podman content found at $CUR_GRAPHROOT:"
      warn "  images=$IMG_COUNT containers=$CNT_COUNT volumes=$VOL_COUNT"
      warn "Changing the graph root without migrating would leave it inaccessible."
      if confirm "Copy the existing store to the new location? (containers will be stopped)" n; then
        MIGRATE=yes
      else
        confirm "Change the graph root anyway and abandon that content?" n \
          || die "Aborted. Re-run with --keep-graphroot to leave Podman storage alone."
      fi
    fi

    run mkdir -p "$PATCH_BASE/images" || die "Could not create the image directory."

    if [[ "$MIGRATE" == yes ]]; then
      say "Stopping all containers"
      run podman stop --all --time 30 || warn "Some containers did not stop cleanly."
      # A plain cp loses SELinux labels, hard links and sparseness, all of
      # which the overlay store relies on. -aHAX preserves them.
      say "Copying the store (this can take a while)"
      run rsync -aHAX --info=progress2 "${CUR_GRAPHROOT%/}/" "$PODMAN_GRAPHROOT/" \
        || die "Store migration failed. Podman config was not changed."
      say "Store copied. The old location is left in place; remove it manually once verified."
    else
      run mkdir -p "$PODMAN_GRAPHROOT" || die "Could not create the graph root."
    fi

    # Write a managed storage.conf, preserving whatever was there
    if [[ "$DRY_RUN" != yes ]]; then
      run mkdir -p /etc/containers || true
      if [[ -f "$STORAGE_CONF" ]]; then
        STORAGE_CONF_BAK="$STORAGE_CONF.phase0-$(date +%Y%m%d-%H%M%S).bak"
        cp -a "$STORAGE_CONF" "$STORAGE_CONF_BAK"
        say "Backed up $STORAGE_CONF to $STORAGE_CONF_BAK"
      fi
      cat >"$STORAGE_CONF" <<STORAGEEOF
# Managed by patch01-bootstrap.sh v$VERSION on $(date -Is)
# runroot stays on tmpfs under /run; only the persistent store is relocated.
[storage]
driver = "overlay"
runroot = "/run/containers/storage"
graphroot = "$PODMAN_GRAPHROOT"

[storage.options]
additionalimagestores = []

[storage.options.overlay]
mountopt = "nodev,metacopy=on"
STORAGEEOF
      chmod 0644 "$STORAGE_CONF"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# SELinux labelling
#
# Two different types are needed:
#   - data volumes bind-mounted into containers  -> container_file_t
#   - the Podman image store                     -> container_var_lib_t,
#     applied by equivalency to /var/lib/containers
# ---------------------------------------------------------------------------

if [[ "$DRY_RUN" != yes && "$DO_SELINUX" != no ]] && command -v getenforce >/dev/null 2>&1; then
  SEL="$(getenforce 2>/dev/null || echo Disabled)"
  say "SELinux is $SEL"

  if [[ "$SEL" == Disabled ]]; then
    say "SELinux disabled - skipping labelling. Bind mounts need no :Z flag."
    log "SELinux disabled; labelling skipped by design."
  elif command -v semanage >/dev/null 2>&1; then

    # Data directories that containers bind-mount
    SEL_DATA_DIRS=("$PATCH_BASE/data" "$PATCH_BASE/config" "$PATCH_BASE/certs"
                   "$PATCH_BASE/secrets" "$PATCH_BASE/logs" "$PATCH_BASE/backups"
                   "$PATCH_BASE/reports" "$PATCH_BASE/bundles")
    [[ "$ROLE" == "AI-01" ]] && SEL_DATA_DIRS+=("$PATCH_BASE/models") || true

    for d in "${SEL_DATA_DIRS[@]}"; do
      [[ -d "$d" ]] || continue
      if semanage fcontext -a -t container_file_t "${d}(/.*)?" >>"$LOG_FILE" 2>&1; then
        log "fcontext added: $d -> container_file_t"
      else
        # -a fails if the rule exists; -m modifies it instead
        semanage fcontext -m -t container_file_t "${d}(/.*)?" >>"$LOG_FILE" 2>&1 \
          || warn "Could not set the SELinux context for $d"
      fi
    done

    # Podman image store: equivalency, not a direct label
    if [[ -n "$PODMAN_GRAPHROOT" && -d "$PATCH_BASE/images" ]]; then
      if semanage fcontext -a -e /var/lib/containers "$PATCH_BASE/images" >>"$LOG_FILE" 2>&1; then
        say "Added an SELinux equivalency: $PATCH_BASE/images = /var/lib/containers"
      else
        semanage fcontext -m -e /var/lib/containers "$PATCH_BASE/images" >>"$LOG_FILE" 2>&1 \
          || warn "Could not add the SELinux equivalency for $PATCH_BASE/images"
      fi
    fi

    say "Relabelling $PATCH_BASE (this can take a moment)"
    restorecon -RF "$PATCH_BASE" >>"$LOG_FILE" 2>&1 || warn "restorecon reported errors; see the log."
    say "Keep SELinux enforcing. Later phases label volumes rather than disabling it."
  else
    warn "semanage is unavailable; install policycoreutils-python-utils to set labels."
  fi
fi

# ---------------------------------------------------------------------------
# Network exposure audit
#
# With firewalld disabled there is no second layer: any service that binds
# 0.0.0.0 is immediately reachable on the network. This host is only supposed
# to expose 443. Everything else (PostgreSQL, Redis, the Pulp API, the
# llama-server) must bind 127.0.0.1 or, better, sit on a Podman network with
# no published host port at all.
#
# This is an audit, not a fix. It reports what is currently listening so the
# state is recorded in the baseline and visible before phase 1 deploys anything.
# ---------------------------------------------------------------------------

EXPOSED_COUNT=0
EXPOSURE_REPORT=""

audit_exposure() {
  local line addr port proto note bind src
  if command -v ss >/dev/null 2>&1; then
    src=ss
  elif command -v netstat >/dev/null 2>&1; then
    src=netstat
  else
    warn "Neither ss nor netstat is available; skipping the exposure audit."
    return 0
  fi

  step "Auditing listening sockets"
  log "exposure audit using: $src"

  if [[ "$DO_FIREWALL" != no ]]; then
    if systemctl is-active --quiet firewalld 2>/dev/null; then
      say "firewalld is active."
    else
      say "firewalld is not active - host port bindings are the only control."
    fi
  fi

  # Ports that must never be reachable off-host
  declare -A SENSITIVE=(
    [5432]="PostgreSQL"
    [6379]="Redis"
    [24817]="Pulp API"
    [24816]="Pulp content"
    [8080]="llama-server"
    [2375]="Docker API"
    [2376]="Docker API TLS"
  )

  while read -r proto _ _ addr _; do
    [[ -n "$addr" ]] || continue
    port="${addr##*:}"
    [[ "$port" =~ ^[0-9]+$ ]] || continue
    # Strip the port to get the bind address
    bind="${addr%:*}"
    bind="${bind#\[}"; bind="${bind%\]}"

    case "$bind" in
      127.0.0.1|::1|localhost) note="localhost only - fine" ;;
      0.0.0.0|::|'*')
        if [[ -n "${SENSITIVE[$port]:-}" ]]; then
          note="EXPOSED - ${SENSITIVE[$port]} should bind 127.0.0.1"
          EXPOSED_COUNT=$((EXPOSED_COUNT+1))
        elif [[ "$port" == 443 ]]; then
          note="expected - the single external ingress"
        elif [[ "$port" == 22 ]]; then
          note="SSH - expected"
        else
          note="all interfaces - confirm this is intended"
        fi
        ;;
      *) note="bound to $bind" ;;
    esac

    printf '  %-6s %-24s %s\n' "$proto" "$addr" "$note"
    EXPOSURE_REPORT+="$proto $addr - $note"$'\n'
  done < <(
    if [[ "$src" == ss ]]; then
      ss -ltnH 2>/dev/null || true
    else
      # netstat -ltn: reshape to "PROTO recvq sendq local peer" like ss -ltnH
      netstat -ltn 2>/dev/null | awk '/^tcp/{print "LISTEN", $2, $3, $4, $5}' || true
    fi
  )

  if (( EXPOSED_COUNT > 0 )); then
    warn "$EXPOSED_COUNT sensitive service(s) are bound to all interfaces."
    warn "With firewalld disabled these are reachable from the network."
    warn "In Quadlet use: PublishPort=127.0.0.1:PORT:PORT  (never PublishPort=PORT:PORT)"
    warn "Better still, publish nothing and let containers talk over a Podman network."
  else
    say "No sensitive service is bound to all interfaces."
  fi
  return 0
}

if [[ "$DRY_RUN" != yes ]]; then
  audit_exposure || true
fi

# ---------------------------------------------------------------------------
# Record the baseline
# ---------------------------------------------------------------------------

step "Recording the baseline"

CONF="$ETC_DIR/phase0.env"
if [[ "$DRY_RUN" != yes ]]; then
  cat >"$CONF" <<CONFEOF
# Generated by patch01-bootstrap.sh v$VERSION on $(date -Is)
# Variables are prefixed to avoid collisions when sourced or passed to Podman.
PP_PHASE0_VERSION=$VERSION
PP_ROLE=$ROLE
PP_HOSTNAME=$(hostname -s 2>/dev/null || echo unknown)
PP_OS_ID=$OS_ID
PP_OS_VERSION=$OS_VER
PP_ARCH=$ARCH
PP_BASE=$PATCH_BASE
PP_CONFIG_DIR=$PATCH_BASE/config
PP_DATA_DIR=$PATCH_BASE/data
PP_CERTS_DIR=$PATCH_BASE/certs
PP_SECRETS_DIR=$PATCH_BASE/secrets
PP_QUADLET_DIR=$PATCH_BASE/quadlet
PP_LOGS_DIR=$PATCH_BASE/logs
PP_STORAGE_MODE=$STORAGE_MODE
PP_STORAGE_LAYOUT=$STORAGE_LAYOUT
PP_STORAGE_VG=$STORAGE_VG
PP_STORAGE_VOLUMES="${VOL_TABLE[*]}"
PP_VG_CREATED=$([[ -n "$NEW_VG" ]] && echo yes || echo no)
PP_PVS="${NEW_PVS[*]:-}"
PP_FSTAB_BACKUP=${FSTAB_BACKUP:-none}
PP_FS_SOURCE=$FS_SOURCE
PP_FS_TYPE=$FS_TYPE
PP_FS_TARGET=$FS_TARGET
PP_EXTERNAL_HTTPS_PORT=443
PP_CONTAINER_ENGINE=podman
PP_PODMAN_GRAPHROOT=${PODMAN_GRAPHROOT:-default}
PP_PODMAN_STORAGE_CONF=/etc/containers/storage.conf
PP_SELINUX_STATE=$(getenforce 2>/dev/null || echo Disabled)
PP_FIREWALLD_ACTIVE=$(systemctl is-active firewalld 2>/dev/null || echo inactive)
PP_EXPOSED_SENSITIVE_PORTS=$EXPOSED_COUNT
CONFEOF
  chmod 0600 "$CONF"

  REPORT="$STATE_DIR/phase0-report.txt"
  {
    echo "PHASE 0 BASELINE - $ROLE"
    echo "Generated: $(date -Is)"
    echo
    echo "OS:        $OS_PRETTY"
    echo "Arch:      $ARCH"
    echo "CPU:       $(nproc 2>/dev/null || echo '?')"
    echo "RAM GiB:   $(awk '/MemTotal/{printf "%.1f",$2/1048576}' /proc/meminfo 2>/dev/null || echo '?')"
    echo "Base:      $PATCH_BASE"
    echo "Storage:   $STORAGE_MODE / $STORAGE_LAYOUT  vg=$STORAGE_VG"
    if [[ "$STORAGE_MODE" != skip ]]; then
      echo
      echo "Volumes:"
      df -Ph --output=source,size,avail,target 2>/dev/null \
        | grep -E "vg_|$PATCH_BASE" | sed 's/^/  /' || echo "  (none)"
    fi
    echo "Podman:    $(podman --version 2>/dev/null || echo 'not installed')"
    echo "GraphRoot: $(podman info --format '{{.Store.GraphRoot}}' 2>/dev/null || echo unknown)"
    echo "SELinux:   $(getenforce 2>/dev/null || echo unknown)"
    echo "firewalld: $(systemctl is-active firewalld 2>/dev/null || echo inactive)"
    echo
    echo "Listening sockets at setup:"
    printf '%s' "${EXPOSURE_REPORT:-  (none recorded)}" | sed 's/^/  /'
    echo "Sensitive ports on all interfaces: $EXPOSED_COUNT"
    echo "fstab bak: ${FSTAB_BACKUP:-none}"
    echo "Log:       $LOG_FILE"
  } >"$REPORT"
  chmod 0600 "$REPORT"

  date -Is >"$STATE_DIR/PHASE0_COMPLETE"
  chmod 0600 "$STATE_DIR/PHASE0_COMPLETE"
fi

# ---------------------------------------------------------------------------
# Final validation
# ---------------------------------------------------------------------------

step "Validating"

FAILS=0
if [[ "$DRY_RUN" != yes ]]; then
  [[ -d "$PATCH_BASE/config" ]] || { warn "Missing $PATCH_BASE/config"; FAILS=$((FAILS+1)); }
  [[ -f "$CONF" ]]              || { warn "Missing $CONF";              FAILS=$((FAILS+1)); }
  podman info >/dev/null 2>>"$LOG_FILE" || { warn "podman info failed";  FAILS=$((FAILS+1)); }
  if [[ -n "$PODMAN_GRAPHROOT" ]]; then
    ACTUAL_GR="$(podman info --format '{{.Store.GraphRoot}}' 2>/dev/null || echo unknown)"
    if [[ "$ACTUAL_GR" == "$PODMAN_GRAPHROOT" ]]; then
      say "Podman graph root confirmed: $ACTUAL_GR"
    else
      warn "Podman reports graph root $ACTUAL_GR, expected $PODMAN_GRAPHROOT"
      FAILS=$((FAILS+1))
    fi
  fi
  if [[ "$STORAGE_MODE" != skip ]]; then
    for entry in "${VOL_TABLE[@]}"; do
      IFS=: read -r vname vpath vpct <<<"$entry"
      if [[ -n "$vpath" ]]; then MP="$PATCH_BASE/$vpath"; else MP="$PATCH_BASE"; fi
      if findmnt -n "$MP" >/dev/null 2>&1; then
        log "verified mount: $MP"
      else
        warn "$MP is not mounted"; FAILS=$((FAILS+1))
      fi
    done
  fi
  (( FAILS == 0 )) || die "$FAILS validation check(s) failed. See $LOG_FILE"
fi

echo
echo "================================================================"
echo " PHASE 0 COMPLETE - $ROLE"
echo "================================================================"
printf ' Base:      %s\n' "$PATCH_BASE"
printf ' Storage:   %s\n' "$STORAGE_MODE"
if [[ "$STORAGE_MODE" != skip ]]; then
  printf ' Layout:    %s (%d volume(s))\n' "$STORAGE_LAYOUT" "${#VOL_TABLE[@]}"
fi
[[ -n "$PODMAN_GRAPHROOT" ]] && printf ' Podman:    %s\n' "$PODMAN_GRAPHROOT" || true
printf ' Config:    %s\n' "$CONF"
printf ' Log:       %s\n' "$LOG_FILE"
[[ -n "$FSTAB_BACKUP" ]] && printf ' fstab bak: %s\n' "$FSTAB_BACKUP" || true
echo
echo " No container images were pulled. No services were deployed."
if (( EXPOSED_COUNT > 0 )); then
  echo " NOTE: $EXPOSED_COUNT sensitive port(s) are bound to all interfaces - see the log."
fi
echo " Reminder for phase 1: bind internal services to 127.0.0.1, expose only 443."
echo " Next: phase 1 - offline image bundle and Quadlet units."
[[ "$DRY_RUN" == yes ]] && echo " (dry run - nothing was actually changed)" || true
