#!/usr/bin/env bash
set -Eeuo pipefail
umask 027

VERSION="1.0.0"
LOG="/tmp/qwen-setup-$(date +%Y%m%d-%H%M%S).log"

log(){ echo "$(date '+%F %T') $*" >>"$LOG"; }
fail(){
  local m="$1"; log "ERROR: $m"
  if command -v whiptail >/dev/null 2>&1; then
    whiptail --title "Qwen Setup - ERROR" --msgbox "$m

Log:
$LOG" 18 78 || true
  else
    echo "ERROR: $m" >&2
  fi
  exit 1
}
trap 'rc=$?; log "ERROR rc=$rc line=${BASH_LINENO[0]:-$LINENO} cmd=${BASH_COMMAND:-unknown}"; exit $rc' ERR

[[ $EUID -eq 0 ]] || { echo "Run as root."; exit 1; }
[[ -f /etc/os-release ]] || fail "/etc/os-release missing."
source /etc/os-release
[[ "${VERSION_ID%%.*}" == "9" ]] || fail "Supported: RHEL 9 / Oracle Linux 9.
Detected: ${PRETTY_NAME:-unknown}"
case "${ID:-}" in rhel|ol) ;; *) [[ -f /etc/oracle-release ]] || fail "Unsupported OS: ${PRETTY_NAME:-unknown}" ;; esac
[[ "$(uname -m)" == "x86_64" ]] || fail "x86_64 is required."

if ! command -v whiptail >/dev/null 2>&1; then
  read -r -p "Install interactive UI package 'newt'? [Y/n]: " a
  a="${a:-Y}"
  [[ "${a,,}" =~ ^(y|yes)$ ]] || exit 1
  dnf install -y newt >>"$LOG" 2>&1 || fail "Could not install newt."
fi

CPU="$(nproc)"
RAM="$(awk '/MemTotal/{printf "%d",$2/1024/1024}' /proc/meminfo)"

whiptail --title "Qwen + llama.cpp Setup" --msgbox "Version $VERSION

OS: ${PRETTY_NAME}
CPU: $CPU logical CPU(s)
RAM: ~${RAM} GiB

Interactive choices:
• base install path / existing mountpoint
• llama.cpp source archive
• Qwen GGUF model
• model copy or use-in-place
• CPU threads
• context size
• bind address and port
• systemd service

This script does NOT format or mount disks.
It does NOT modify SELinux or firewalld." 27 82

ask_path(){
  local title="$1" prompt="$2" def="$3" kind="${4:-any}" v
  while true; do
    v="$(whiptail --title "$title" --inputbox "$prompt" 13 82 "$def" 3>&1 1>&2 2>&3)" || return 1
    [[ "$v" == /* ]] || { whiptail --msgbox "Use an absolute path beginning with /." 9 64; continue; }
    [[ ! "$v" =~ [[:space:]] ]] || { whiptail --msgbox "Paths containing spaces are not supported." 9 64; continue; }
    if [[ "$kind" == file && ! -f "$v" ]]; then
      whiptail --msgbox "File not found:

$v" 11 76
      continue
    fi
    echo "$v"; return 0
  done
}

ask_num(){
  local title="$1" prompt="$2" def="$3" min="$4" max="$5" v
  while true; do
    v="$(whiptail --title "$title" --inputbox "$prompt" 11 70 "$def" 3>&1 1>&2 2>&3)" || return 1
    if [[ "$v" =~ ^[0-9]+$ ]] && (( v>=min && v<=max )); then echo "$v"; return 0; fi
    whiptail --msgbox "Enter a whole number between $min and $max." 9 60
  done
}

SRC_TAR="$(ask_path "llama.cpp Source" "Full path to llama.cpp source .tar.gz

Example:
/root/llama.cpp-b10867.tar.gz" "/root/llama.cpp-b10867.tar.gz" file)" || exit 0

MODEL_SRC="$(ask_path "Qwen Model" "Full path to the Qwen GGUF model

Example:
/root/Qwen3-8B-Q4_K_M.gguf" "/root/Qwen3-8B-Q4_K_M.gguf" file)" || exit 0

[[ "$SRC_TAR" == *.tar.gz || "$SRC_TAR" == *.tgz ]] || fail "Source must be .tar.gz or .tgz"
[[ "$MODEL_SRC" == *.gguf ]] || fail "Model must be a .gguf file."
tar -tzf "$SRC_TAR" >/dev/null 2>&1 || fail "Invalid llama.cpp tar.gz archive."

BASE="$(ask_path "Install Location" "Choose the base directory on your EXISTING filesystem/mount.

Examples:
/AI
/data/AI
/qwen
/mnt/ai/qwen

Nothing is mounted or formatted by this script." "/AI")" || exit 0

case "$BASE" in
  /|/bin|/boot|/dev|/etc|/lib|/lib64|/proc|/run|/sbin|/sys|/usr|/var)
    fail "Unsafe base path: $BASE

Choose a dedicated path such as /AI or /data/AI."
  ;;
esac

SRC_DIR="$BASE/src"
MODEL_DIR="$BASE/models"
BIN_DIR="$BASE/bin"
CFG_DIR="$BASE/config"
LOG_DIR="$BASE/logs"

MODEL_NAME="$(basename "$MODEL_SRC")"
MCHOICE="$(whiptail --title "Model Location" --menu "Choose how to use the GGUF model:" 16 82 3 \
  "1" "COPY model into $MODEL_DIR" \
  "2" "USE model in its current location" \
  "0" "Cancel" 3>&1 1>&2 2>&3)" || exit 0

case "$MCHOICE" in
  1) MODEL="$MODEL_DIR/$MODEL_NAME"; COPY_MODEL=yes ;;
  2) MODEL="$MODEL_SRC"; COPY_MODEL=no ;;
  *) exit 0 ;;
esac

TDEF="$CPU"; (( TDEF>6 )) && TDEF=6
THREADS="$(ask_num "CPU Threads" "Inference threads.

Detected CPUs: $CPU
Recommended starting value for this project: $TDEF" "$TDEF" 1 "$CPU")" || exit 0

CTX="$(whiptail --title "Context Size" --menu "Initial context size:" 17 72 5 \
  "4096" "4K - lowest RAM" \
  "8192" "8K - RECOMMENDED" \
  "16384" "16K - more RAM" \
  "32768" "32K - not recommended initially on 16 GB" \
  "CUSTOM" "Enter another value" 3>&1 1>&2 2>&3)" || exit 0
[[ "$CTX" != CUSTOM ]] || CTX="$(ask_num "Custom Context" "Context tokens:" 8192 512 131072)" || exit 0

HOST="$(whiptail --title "Bind Address" --menu "Where should llama-server listen?" 17 82 3 \
  "127.0.0.1" "Localhost only - RECOMMENDED" \
  "0.0.0.0" "All interfaces - advanced" \
  "CUSTOM" "Enter specific IP" 3>&1 1>&2 2>&3)" || exit 0

if [[ "$HOST" == CUSTOM ]]; then
  HOST="$(whiptail --title "Bind Address" --inputbox "Enter bind IP:" 10 64 "127.0.0.1" 3>&1 1>&2 2>&3)" || exit 0
fi
if [[ "$HOST" == 0.0.0.0 ]]; then
  whiptail --title "Warning" --defaultno --yesno "0.0.0.0 exposes the API on every interface.

This script does not change firewall rules.

Continue?" 14 72 || HOST="127.0.0.1"
fi

PORT="$(ask_num "Server Port" "llama-server port:" 8080 1024 65535)" || exit 0
ALIAS="$(whiptail --title "API Model Alias" --inputbox "Model name exposed by the API:" 10 68 "qwen-patch-ai" 3>&1 1>&2 2>&3)" || exit 0
[[ -n "$ALIAS" ]] || ALIAS="qwen-patch-ai"

JOBS="$(ask_num "Build Jobs" "Parallel compile jobs.

Detected CPUs: $CPU" "$CPU" 1 "$CPU")" || exit 0

MAKE_SERVICE=no
START_SERVICE=no
SERVICE="qwen-ai"
SVCUSER="qwenai"

if whiptail --title "systemd" --yesno "Create a systemd service? (Recommended)" 10 66; then
  MAKE_SERVICE=yes
  SERVICE="$(whiptail --title "Service Name" --inputbox "Service name without .service:" 10 66 "$SERVICE" 3>&1 1>&2 2>&3)" || exit 0
  [[ "$SERVICE" =~ ^[A-Za-z0-9_.@-]+$ ]] || fail "Invalid service name."
  SVCUSER="$(whiptail --title "Service User" --inputbox "Dedicated local service account:" 10 66 "$SVCUSER" 3>&1 1>&2 2>&3)" || exit 0
  [[ "$SVCUSER" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]] || fail "Invalid service user."
  whiptail --title "Autostart" --yesno "Enable and start $SERVICE.service after setup?" 10 70 && START_SERVICE=yes
fi

SMOKE=no
whiptail --title "Smoke Test" --yesno "Load the model once after compilation and run a short test?" 11 72 && SMOKE=yes

PKGS=(gcc gcc-c++ cmake make openssl-devel libgomp tar gzip curl)
MISSING=()
for p in "${PKGS[@]}"; do rpm -q "$p" >/dev/null 2>&1 || MISSING+=("$p"); done
INSTALL_PKGS=no
if ((${#MISSING[@]}>0)); then
  whiptail --title "Dependencies" --yesno "Missing packages:

${MISSING[*]}

Install them now from configured DNF repositories?" 16 78 || fail "Required packages are missing."
  INSTALL_PKGS=yes
fi

REVIEW="INSTALL PLAN

Base path:
$BASE

Source:
$SRC_TAR

Model source:
$MODEL_SRC

Runtime model:
$MODEL
Copy model: $COPY_MODEL

Threads: $THREADS
Context: $CTX
Listen: $HOST:$PORT
Alias: $ALIAS
Build jobs: $JOBS

systemd: $MAKE_SERVICE
Service: $SERVICE
User: $SVCUSER
Auto-start: $START_SERVICE
Smoke test: $SMOKE

No disks are formatted or mounted.
SELinux/firewalld are untouched."

whiptail --title "Review" --yesno "$REVIEW

Proceed?" 39 86 || exit 0

if [[ "$INSTALL_PKGS" == yes ]]; then
  dnf install -y "${MISSING[@]}" >>"$LOG" 2>&1 || fail "Dependency installation failed."
fi

for c in gcc g++ cmake make tar gzip curl; do command -v "$c" >/dev/null 2>&1 || fail "Missing command after package check: $c"; done

mkdir -p "$SRC_DIR" "$MODEL_DIR" "$BIN_DIR" "$CFG_DIR" "$LOG_DIR"

if [[ "$COPY_MODEL" == yes ]]; then
  if [[ -e "$MODEL" ]] && ! cmp -s "$MODEL_SRC" "$MODEL"; then
    whiptail --title "Existing Model" --defaultno --yesno "A different file exists at:

$MODEL

Overwrite it?" 14 78 || fail "Cancelled."
  fi
  if [[ ! -e "$MODEL" ]] || ! cmp -s "$MODEL_SRC" "$MODEL"; then
    whiptail --infobox "Copying model to:

$MODEL" 9 76
    cp -f --reflink=auto "$MODEL_SRC" "$MODEL" >>"$LOG" 2>&1 || fail "Model copy failed."
  fi
fi

ARCHIVE="$SRC_DIR/$(basename "$SRC_TAR")"
[[ "$SRC_TAR" == "$ARCHIVE" ]] || cp -f "$SRC_TAR" "$ARCHIVE" >>"$LOG" 2>&1 || fail "Source copy failed."

TOP="$(tar -tzf "$ARCHIVE" | head -n1 | cut -d/ -f1)"
[[ -n "$TOP" ]] || fail "Could not determine source directory."
LLAMA_SRC="$SRC_DIR/$TOP"

if [[ -d "$LLAMA_SRC" ]]; then
  whiptail --title "Existing Source" --yesno "Source directory exists:

$LLAMA_SRC

Delete and re-extract it?" 14 76 || fail "Cancelled."
  rm -rf -- "$LLAMA_SRC"
fi

tar -xzf "$ARCHIVE" -C "$SRC_DIR" >>"$LOG" 2>&1 || fail "Source extraction failed."
[[ -f "$LLAMA_SRC/CMakeLists.txt" ]] || fail "CMakeLists.txt not found after extraction."

BUILD="$LLAMA_SRC/build"

whiptail --infobox "Configuring llama.cpp CPU build...

Log:
$LOG" 10 76

cmake -S "$LLAMA_SRC" -B "$BUILD" \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=OFF \
  -DLLAMA_BUILD_TESTS=OFF \
  -DLLAMA_BUILD_EXAMPLES=OFF \
  -DLLAMA_BUILD_TOOLS=ON \
  -DLLAMA_BUILD_SERVER=ON \
  -DLLAMA_BUILD_UI=OFF \
  -DLLAMA_OPENSSL=ON \
  >>"$LOG" 2>&1 || fail "CMake configuration failed."

whiptail --infobox "Compiling llama-server and llama-cli with $JOBS job(s)...

Log:
$LOG" 10 76

cmake --build "$BUILD" --config Release -j "$JOBS" --target llama-server llama-cli >>"$LOG" 2>&1 || fail "Compilation failed."

[[ -x "$BUILD/bin/llama-server" ]] || fail "llama-server was not built."
[[ -x "$BUILD/bin/llama-cli" ]] || fail "llama-cli was not built."

install -m 0755 "$BUILD/bin/llama-server" "$BIN_DIR/llama-server"
install -m 0755 "$BUILD/bin/llama-cli" "$BIN_DIR/llama-cli"

cat >"$CFG_DIR/qwen.env" <<EOF
INSTALLER_VERSION="$VERSION"
BASE="$BASE"
LLAMA_SOURCE="$LLAMA_SRC"
LLAMA_SERVER="$BIN_DIR/llama-server"
LLAMA_CLI="$BIN_DIR/llama-cli"
MODEL="$MODEL"
ALIAS="$ALIAS"
THREADS="$THREADS"
CONTEXT="$CTX"
HOST="$HOST"
PORT="$PORT"
EOF
chmod 0640 "$CFG_DIR/qwen.env"

if [[ "$MAKE_SERVICE" == yes ]]; then
  id "$SVCUSER" >/dev/null 2>&1 || useradd --system --home-dir "$BASE" --shell /sbin/nologin "$SVCUSER"
  GRP="$(id -gn "$SVCUSER")"

  chown root:"$GRP" "$BASE" "$MODEL_DIR" "$BIN_DIR" "$CFG_DIR" 2>/dev/null || true
  chmod 0750 "$BASE" "$MODEL_DIR" "$BIN_DIR" "$CFG_DIR"

  if [[ "$COPY_MODEL" == yes ]]; then
    chown root:"$GRP" "$MODEL"
    chmod 0640 "$MODEL"
  else
    runuser -u "$SVCUSER" -- test -r "$MODEL" || fail "Service user $SVCUSER cannot read:

$MODEL

Rerun and choose COPY model, or adjust permissions."
  fi

  UNIT="/etc/systemd/system/$SERVICE.service"
  cat >"$UNIT" <<EOF
[Unit]
Description=Qwen AI llama.cpp Server
After=network.target

[Service]
Type=simple
User=$SVCUSER
Group=$GRP
WorkingDirectory=$BASE
ExecStart=$BIN_DIR/llama-server --model $MODEL --alias $ALIAS --threads $THREADS --ctx-size $CTX --host $HOST --port $PORT --jinja
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ReadWritePaths=$BASE
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
  chmod 0644 "$UNIT"
  systemctl daemon-reload

  if [[ "$START_SERVICE" == yes ]]; then
    systemctl enable --now "$SERVICE.service" >>"$LOG" 2>&1 || fail "Service failed to start.

Check:
systemctl status $SERVICE.service
journalctl -u $SERVICE.service -n 100"
  fi
fi

SMOKE_RESULT="not requested"
if [[ "$SMOKE" == yes ]]; then
  if [[ "$MAKE_SERVICE" == yes && "$START_SERVICE" == yes ]]; then
    sleep 3
    if curl -fsS --max-time 8 "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then
      SMOKE_RESULT="server health PASS"
    else
      SMOKE_RESULT="server health not ready; check service log"
    fi
  else
    set +e
    timeout 180 "$BIN_DIR/llama-cli" -m "$MODEL" -t "$THREADS" -c "$CTX" -n 16 -p "Reply with exactly: MODEL_OK" >>"$LOG" 2>&1
    R=$?
    set -e
    [[ $R -eq 0 ]] && SMOKE_RESULT="local model PASS" || SMOKE_RESULT="local model test failed/timed out; see log"
  fi
fi

SUCCESS="INSTALLATION COMPLETE

Base:
$BASE

Model:
$MODEL

Server:
$BIN_DIR/llama-server

CLI:
$BIN_DIR/llama-cli

Listen:
$HOST:$PORT

Threads:
$THREADS

Context:
$CTX

systemd:
$MAKE_SERVICE

Smoke:
$SMOKE_RESULT

Config:
$CFG_DIR/qwen.env

Log:
$LOG"

whiptail --title "SUCCESS" --msgbox "$SUCCESS" 30 84

clear
echo "============================================================"
echo " QWEN AI READY"
echo "============================================================"
echo "Base:    $BASE"
echo "Model:   $MODEL"
echo "Server:  $BIN_DIR/llama-server"
echo "CLI:     $BIN_DIR/llama-cli"
echo "Listen:  $HOST:$PORT"
echo "Config:  $CFG_DIR/qwen.env"
echo "Log:     $LOG"
[[ "$MAKE_SERVICE" == yes ]] && echo "Service: $SERVICE.service"
