#!/usr/bin/env bash
set -Eeuo pipefail
umask 027

VERSION="1.0.0"
LOG="/tmp/qwen-cleanup-$(date +%Y%m%d-%H%M%S).log"

log(){ printf '%s %s\n' "$(date '+%F %T')" "$*" >>"$LOG"; }

die(){
  local msg="$1"
  log "ERROR: $msg"
  if command -v whiptail >/dev/null 2>&1; then
    whiptail --title "Qwen Cleanup - ERROR" --msgbox "$msg

Log:
$LOG" 18 78 || true
  else
    echo "ERROR: $msg" >&2
    echo "Log: $LOG" >&2
  fi
  exit 1
}

[[ "$EUID" -eq 0 ]] || { echo "Run as root."; exit 1; }

have_whiptail(){ command -v whiptail >/dev/null 2>&1; }

ask_yes_no(){
  local title="$1" text="$2" default_no="${3:-yes}"
  if have_whiptail; then
    if [[ "$default_no" == "yes" ]]; then
      whiptail --title "$title" --defaultno --yesno "$text" 16 78
    else
      whiptail --title "$title" --yesno "$text" 16 78
    fi
  else
    local ans
    if [[ "$default_no" == "yes" ]]; then
      read -r -p "$text [y/N]: " ans
      [[ "${ans,,}" =~ ^(y|yes)$ ]]
    else
      read -r -p "$text [Y/n]: " ans
      ans="${ans:-Y}"
      [[ "${ans,,}" =~ ^(y|yes)$ ]]
    fi
  fi
}

ask_input(){
  local title="$1" text="$2" default="$3"
  if have_whiptail; then
    whiptail --title "$title" --inputbox "$text" 12 78 "$default" 3>&1 1>&2 2>&3
  else
    local ans
    read -r -p "$text [$default]: " ans
    echo "${ans:-$default}"
  fi
}

DEFAULT_CFG=""
for c in /AI/config/qwen.env /Tools/AI/config/qwen.env /opt/qwen/config/qwen.env; do
  [[ -f "$c" ]] && { DEFAULT_CFG="$c"; break; }
done
[[ -n "$DEFAULT_CFG" ]] || DEFAULT_CFG="/AI/config/qwen.env"

CFG="$(ask_input "Qwen Configuration" "Path to qwen.env." "$DEFAULT_CFG")" || exit 0

BASE=""
MODEL=""
LLAMA_SERVER=""
SERVICE="qwen-ai"
SERVICE_USER="qwenai"

if [[ -f "$CFG" ]]; then
  # shellcheck disable=SC1090
  source "$CFG"
  BASE="${BASE:-${BASE_DIR:-}}"
  MODEL="${MODEL:-${MODEL_PATH:-}}"
  LLAMA_SERVER="${LLAMA_SERVER:-}"
fi

if [[ -z "$BASE" && "$CFG" == */config/qwen.env ]]; then
  BASE="${CFG%/config/qwen.env}"
fi

if [[ -z "$BASE" ]]; then
  BASE="$(ask_input "Installation Base" "Enter the Qwen installation directory." "/AI")" || exit 0
fi
BASE="${BASE%/}"

case "$BASE" in
  ""|/|/bin|/boot|/dev|/etc|/home|/lib|/lib64|/proc|/root|/run|/sbin|/sys|/tmp|/usr|/var|/Tools)
    die "Refusing unsafe cleanup base:

$BASE

Expected a dedicated directory such as /AI or /Tools/AI."
  ;;
esac

if [[ -z "$MODEL" ]]; then
  for c in /Tools/Qwen3-8B-Q4_K_M.gguf "$BASE/models/Qwen3-8B-Q4_K_M.gguf"; do
    [[ -f "$c" ]] && { MODEL="$c"; break; }
  done
fi

SERVICE_FILE=""
if [[ -f "/etc/systemd/system/${SERVICE}.service" ]]; then
  SERVICE_FILE="/etc/systemd/system/${SERVICE}.service"
else
  SERVICE_FILE="$(systemctl show -p FragmentPath --value "${SERVICE}.service" 2>/dev/null || true)"
fi

if [[ -n "$SERVICE_FILE" && -f "$SERVICE_FILE" ]]; then
  u="$(awk -F= '$1=="User"{print $2; exit}' "$SERVICE_FILE" || true)"
  [[ -n "$u" ]] && SERVICE_USER="$u"
fi

SERVICE_STATE="not found"
if systemctl list-unit-files --type=service 2>/dev/null | awk '{print $1}' | grep -Fxq "${SERVICE}.service"; then
  SERVICE_STATE="$(systemctl is-active "${SERVICE}.service" 2>/dev/null || true)"
fi

BASE_SIZE="not present"
[[ -d "$BASE" ]] && BASE_SIZE="$(du -sh "$BASE" 2>/dev/null | awk '{print $1}' || echo unknown)"

MODEL_SIZE="not present"
[[ -n "$MODEL" && -f "$MODEL" ]] && MODEL_SIZE="$(du -h "$MODEL" 2>/dev/null | awk '{print $1}' || echo unknown)"

SUMMARY="Detected Qwen test installation

Config:
$CFG

Base:
$BASE
Size: $BASE_SIZE

Model:
${MODEL:-not detected}
Size: $MODEL_SIZE

Service:
${SERVICE}.service
State: $SERVICE_STATE
Unit: ${SERVICE_FILE:-not detected}

Service user:
$SERVICE_USER

Nothing outside these paths is removed."

if have_whiptail; then
  whiptail --title "Qwen Cleanup Wizard" --msgbox "$SUMMARY" 27 84
else
  echo "$SUMMARY"
fi

REMOVE_SERVICE=no
REMOVE_BASE=no
REMOVE_MODEL=no
REMOVE_USER=no
REMOVE_PACKAGES=no

if [[ -n "$SERVICE_FILE" || "$SERVICE_STATE" != "not found" ]]; then
  ask_yes_no "Remove systemd Service" "Stop, disable and remove:

${SERVICE}.service

Recommended: YES" "no" && REMOVE_SERVICE=yes
fi

if [[ -d "$BASE" ]]; then
  ask_yes_no "Remove Installation" "Remove the complete Qwen/llama.cpp tree:

$BASE

Size: $BASE_SIZE

This removes binaries, source, config and local logs.

Recommended on the test server: YES" "no" && REMOVE_BASE=yes
fi

if [[ -n "$MODEL" && -f "$MODEL" ]]; then
  ask_yes_no "Remove GGUF Model" "Also delete the downloaded model?

$MODEL
Size: $MODEL_SIZE

Choose NO if you want to reuse it on the real AI server." "yes" && REMOVE_MODEL=yes
fi

if id "$SERVICE_USER" >/dev/null 2>&1; then
  ask_yes_no "Remove Service Account" "Remove local service account:

$SERVICE_USER

Recommended on the test server: YES" "no" && REMOVE_USER=yes
fi

ask_yes_no "Remove Build Packages" "Also remove build packages such as gcc/cmake/make?

Recommended: NO

This script will NOT downgrade glibc or other shared system libraries." "yes" && REMOVE_PACKAGES=yes

PLAN="CLEANUP PLAN

Remove service:       $REMOVE_SERVICE
Remove install tree:  $REMOVE_BASE
Remove model:         $REMOVE_MODEL
Remove service user:  $REMOVE_USER
Remove build packages:$REMOVE_PACKAGES

Base:
$BASE

Model:
${MODEL:-not detected}

SELinux/firewalld are untouched.
No filesystem is formatted or unmounted.
Unrelated /Tools files are untouched."

ask_yes_no "FINAL CONFIRMATION" "$PLAN

Proceed?" "yes" || exit 0

log "Cleanup started"

if [[ "$REMOVE_SERVICE" == yes ]]; then
  systemctl stop "${SERVICE}.service" >>"$LOG" 2>&1 || true
  systemctl disable "${SERVICE}.service" >>"$LOG" 2>&1 || true
  [[ -n "$SERVICE_FILE" && -f "$SERVICE_FILE" ]] && rm -f -- "$SERVICE_FILE"
  [[ -f "/etc/systemd/system/${SERVICE}.service" ]] && rm -f -- "/etc/systemd/system/${SERVICE}.service"
  systemctl daemon-reload >>"$LOG" 2>&1 || true
  systemctl reset-failed "${SERVICE}.service" >>"$LOG" 2>&1 || true
fi

if [[ "$REMOVE_BASE" == yes && -d "$BASE" ]]; then
  rm -rf --one-file-system -- "$BASE"
  log "Removed base: $BASE"
fi

if [[ "$REMOVE_MODEL" == yes && -n "$MODEL" && -f "$MODEL" ]]; then
  rm -f -- "$MODEL"
  log "Removed model: $MODEL"
fi

if [[ "$REMOVE_USER" == yes ]] && id "$SERVICE_USER" >/dev/null 2>&1; then
  userdel "$SERVICE_USER" >>"$LOG" 2>&1 || true
  log "Removed user: $SERVICE_USER"
fi

if [[ "$REMOVE_PACKAGES" == yes ]]; then
  PKGS=()
  for p in gcc gcc-c++ cmake make openssl-devel; do
    rpm -q "$p" >/dev/null 2>&1 && PKGS+=("$p")
  done
  ((${#PKGS[@]}>0)) && dnf remove -y "${PKGS[@]}" >>"$LOG" 2>&1 || true
fi

SERVICE_REMAINS=NO
BASE_REMAINS=NO
MODEL_REMAINS=NO
USER_REMAINS=NO

systemctl list-unit-files --type=service 2>/dev/null | awk '{print $1}' | grep -Fxq "${SERVICE}.service" && SERVICE_REMAINS=YES || true
[[ -e "$BASE" ]] && BASE_REMAINS=YES
[[ -n "$MODEL" && -e "$MODEL" ]] && MODEL_REMAINS=YES
id "$SERVICE_USER" >/dev/null 2>&1 && USER_REMAINS=YES || true

RESULT="QWEN CLEANUP COMPLETE

Service remains:      $SERVICE_REMAINS
Install dir remains:  $BASE_REMAINS
Model remains:        $MODEL_REMAINS
Service user remains: $USER_REMAINS

Log:
$LOG"

have_whiptail && whiptail --title "Cleanup Complete" --msgbox "$RESULT" 20 76 || true

clear
echo "============================================================"
echo " QWEN CLEANUP COMPLETE"
echo "============================================================"
echo "Service remains:      $SERVICE_REMAINS"
echo "Install dir remains:  $BASE_REMAINS"
echo "Model remains:        $MODEL_REMAINS"
echo "Service user remains: $USER_REMAINS"
echo "Log: $LOG"
