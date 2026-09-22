#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# AI-01 : local LLM inference server
#
#   PATCH-01 --HTTPS 443--> NGINX (AI-01) --127.0.0.1:8080--> llama-server
#
# Everything is detected, nothing assumed:
#   - which llama-server binary is present, and whether it actually runs here
#     (release binaries built on Ubuntu can need a newer glibc than RHEL 9)
#   - which GGUF model is present, and whether it is intact
#   - which llama-server flags this build supports
#   - CPU cores, instruction sets and RAM, to size threads and context
#
# Security model:
#   - llama-server listens on 127.0.0.1 only
#   - NGINX on 443 accepts ONLY the PATCH-01 address; everyone else gets 403.
#     firewalld is disabled on this estate, so this allow-list is the network
#     control, not a second layer
#   - requests need an API key as well, so the allow-list is not the only gate
#   - only the three endpoints PATCH-01 needs are exposed
#   - the service runs as an unprivileged user under systemd sandboxing, and
#     the model and binaries are read-only to it
#
# Usage:
#   ./ai01-setup.sh --patch01-ip 10.20.1.5
#   ./ai01-setup.sh --patch01-ip 10.20.1.5 --dry-run
#   ./ai01-setup.sh --check
#   ./ai01-setup.sh --bench            measure tokens per second
#   ./ai01-setup.sh --show-key         print the API key for PATCH-01
# ---------------------------------------------------------------------------

set -Eeuo pipefail
umask 027

BASE=/llm
BIN_DIR=$BASE/bin
MODEL_DIR=$BASE/models
CONF_DIR=$BASE/config
CERT_DIR=$BASE/certs
LOG_DIR=$BASE/logs
CACHE_DIR=$BASE/cache
SVC_USER=llm
LISTEN_PORT=8080

PATCH01_IP=""
DRY_RUN=no; CHECK_ONLY=no; BENCH=no; SHOW_KEY=no
CTX=""; THREADS=""; PARALLEL=2

while (($#)); do
  case "$1" in
    --patch01-ip) PATCH01_IP="${2:-}"; shift ;;
    --ctx)        CTX="${2:-}"; shift ;;
    --threads)    THREADS="${2:-}"; shift ;;
    --parallel)   PARALLEL="${2:-2}"; shift ;;
    --dry-run)    DRY_RUN=yes ;;
    --check)      CHECK_ONLY=yes ;;
    --bench)      BENCH=yes ;;
    --show-key)   SHOW_KEY=yes ;;
    -h|--help)    sed -n '2,35p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

mkdir -p "$LOG_DIR"
RUNLOG="$LOG_DIR/setup-$(date +%Y%m%d-%H%M%S).log"
: >"$RUNLOG"; chmod 0600 "$RUNLOG"

log()  { printf '%s  %s\n' "$(date '+%F %T')" "$*" >>"$RUNLOG"; }
say()  { printf '%s\n' "$*"; log "OUT: $*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; log "WARN: $*"; }
step() { printf '\n==> %s\n' "$*"; log "STEP: $*"; }
die()  { log "FATAL: $1"; printf '\nERROR: %s\nLog: %s\n' "$1" "$RUNLOG" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run as root."
[[ -d "$BASE" ]] || die "$BASE does not exist. Mount the /llm volume first."

KEY_FILE="$CONF_DIR/api-key"

# ---------------------------------------------------------------------------
# Small modes
# ---------------------------------------------------------------------------
if [[ "$SHOW_KEY" == yes ]]; then
  [[ -f "$KEY_FILE" ]] || die "No API key yet. Run the setup first."
  echo; echo "API key for PATCH-01 (store it in /patch/secrets on PATCH-01):"
  echo; cat "$KEY_FILE"; echo
  exit 0
fi

api_key() { cat "$KEY_FILE" 2>/dev/null || true; }

bench() {
  local key; key="$(api_key)"
  [[ -n "$key" ]] || die "No API key; run setup first."
  step "Benchmark: one short explanation, as PATCH-01 will ask for"
  local body='{"messages":[{"role":"system","content":"You explain Linux security advisories to system administrators. Be brief and factual."},{"role":"user","content":"Explain in three sentences why a server running kernel 5.14.0-427 is affected when the fix is in 5.14.0-570, and why it needs a reboot after updating."}],"max_tokens":160,"temperature":0.2,"chat_template_kwargs":{"enable_thinking":false}}'
  local t0 t1 out
  t0=$(date +%s.%N)
  out="$(curl -s --max-time 300 -H "Authorization: Bearer $key" -H 'Content-Type: application/json' \
         -d "$body" "http://127.0.0.1:$LISTEN_PORT/v1/chat/completions" || true)"
  t1=$(date +%s.%N)
  [[ -n "$out" ]] || die "No response from llama-server."
  printf '%s' "$out" | python3 -c '
import json,sys
try:
    d=json.load(sys.stdin)
except Exception as e:
    print("unparseable response:", e); sys.exit(1)
if "error" in d:
    print("error:", d["error"]); sys.exit(1)
t=d.get("timings",{}); u=d.get("usage",{})
print("  prompt:     %s tokens at %.1f tokens/s" % (u.get("prompt_tokens","?"), t.get("prompt_per_second",0)))
print("  generation: %s tokens at %.1f tokens/s" % (u.get("completion_tokens","?"), t.get("predicted_per_second",0)))
txt=d["choices"][0]["message"].get("content","").strip()
print("\n  answer:\n    " + txt.replace("\n","\n    "))
'
  awk -v a="$t0" -v b="$t1" 'BEGIN{printf "\n  wall clock: %.1fs\n", b-a}'
  say ""
  say "  For comparison: PATCH-01 caches each explanation by content, so one"
  say "  answer serves every server with the same advisory and versions."
}

if [[ "$BENCH" == yes ]]; then bench; exit 0; fi

# ---------------------------------------------------------------------------
# Check mode
# ---------------------------------------------------------------------------
if [[ "$CHECK_ONLY" == yes ]]; then
  step "Checking AI-01"
  FAILS=0
  systemctl is-active --quiet llama-server && say "llama-server service: active" \
    || { warn "llama-server service is not active"; FAILS=$((FAILS+1)); }

  if curl -sf --max-time 10 "http://127.0.0.1:$LISTEN_PORT/health" >/dev/null; then
    say "llama-server health: ok"
  else
    warn "llama-server /health failed"; FAILS=$((FAILS+1))
  fi

  # llama-server must not be reachable except on loopback
  if command -v ss >/dev/null; then
    LST="$(ss -ltnH "sport = :$LISTEN_PORT" 2>/dev/null | awk '{print $4}' || true)"
    if printf '%s\n' "$LST" | grep -qvE '^(127\.0\.0\.1|\[::1\]):' && [[ -n "$LST" ]]; then
      warn "llama-server is listening beyond loopback: $LST"; FAILS=$((FAILS+1))
    else
      say "llama-server bound to loopback only: ${LST:-none}"
    fi
  fi

  systemctl is-active --quiet nginx && say "nginx: active" \
    || { warn "nginx is not active"; FAILS=$((FAILS+1)); }
  CODE="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 https://127.0.0.1/health || echo 000)"
  [[ "$CODE" == "200" ]] && say "HTTPS /health through nginx: 200" \
    || { warn "HTTPS /health through nginx returned $CODE"; FAILS=$((FAILS+1)); }

  # Unexposed paths must be refused even from an allowed address
  CODE="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 https://127.0.0.1/slots || echo 000)"
  [[ "$CODE" == "404" ]] && say "unexposed endpoint /slots refused: 404" \
    || { warn "/slots returned $CODE, expected 404"; FAILS=$((FAILS+1)); }

  # A request without the key must fail
  CODE="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 20 -H 'Content-Type: application/json' \
    -d '{"messages":[{"role":"user","content":"hi"}],"max_tokens":1}' \
    https://127.0.0.1/v1/chat/completions || echo 000)"
  [[ "$CODE" == "401" ]] && say "request without API key refused: 401" \
    || { warn "request without API key returned $CODE, expected 401"; FAILS=$((FAILS+1)); }

  (cd "$MODEL_DIR" && sha256sum -c --quiet SHA256SUMS 2>/dev/null) && say "model checksum: ok" \
    || { warn "model checksum does not match SHA256SUMS"; FAILS=$((FAILS+1)); }

  (( FAILS == 0 )) && say "
All checks passed." || die "$FAILS check(s) failed."
  exit 0
fi

[[ -n "$PATCH01_IP" ]] || die "--patch01-ip is required: the only address allowed to call this server."
[[ "$PATCH01_IP" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || die "--patch01-ip must be an IPv4 address."

# ---------------------------------------------------------------------------
# Host
# ---------------------------------------------------------------------------
step "Host"
. /etc/os-release 2>/dev/null || true
say "OS:   ${PRETTY_NAME:-unknown}"
CPUS="$(nproc)"
RAM_MB="$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo)"
say "CPU:  $CPUS logical cores"
say "RAM:  $((RAM_MB/1024)) GiB"

FLAGS="$(grep -m1 '^flags' /proc/cpuinfo || true)"
ISA=()
for f in avx avx2 fma f16c avx512f avx512_vnni avx_vnni; do
  [[ " $FLAGS " == *" $f "* ]] && ISA+=("$f") || true
done
say "ISA:  ${ISA[*]:-none detected}"
[[ " $FLAGS " == *" avx2 "* ]] || warn "No AVX2: inference will be several times slower."

id "$SVC_USER" >/dev/null 2>&1 || useradd --system --home-dir "$BASE" --shell /sbin/nologin "$SVC_USER"

# ---------------------------------------------------------------------------
# Binary
# ---------------------------------------------------------------------------
step "Finding llama-server"

# Exclude the stable link this script creates, or a re-run would find it,
# and then point it at itself.
mapfile -t CANDS < <(find -L "$BIN_DIR" -type f -name 'llama-server' -perm -u+x \
                       ! -path "$BIN_DIR/llama-server" 2>/dev/null | sort)
if ((${#CANDS[@]} == 0)); then
  if find -L "$BIN_DIR" -maxdepth 3 -name CMakeLists.txt 2>/dev/null | grep -q .; then
    SRC="$(dirname "$(find -L "$BIN_DIR" -maxdepth 3 -name CMakeLists.txt | head -1)")"
    warn "No llama-server binary, but source code is present at $SRC."
    warn "Build it (needs gcc-c++, cmake and make, from PATCH-01's rhel9-appstream):"
    warn "  cd $SRC && cmake -B build -DGGML_NATIVE=ON -DLLAMA_CURL=OFF -DCMAKE_BUILD_TYPE=Release"
    warn "  cmake --build build -j$CPUS --target llama-server"
    die "Build llama-server, then re-run this script."
  fi
  die "No llama-server found under $BIN_DIR."
fi
LLAMA_BIN="$(readlink -f "${CANDS[0]}")"
((${#CANDS[@]} > 1)) && warn "Several found; using $LLAMA_BIN" || true
LLAMA_DIR="$(dirname "$(readlink -f "$LLAMA_BIN")")"
say "Binary: $LLAMA_BIN"

# Does it actually run on this OS? This is where an Ubuntu-built release fails.
MISSING="$(LD_LIBRARY_PATH="$LLAMA_DIR" ldd "$LLAMA_BIN" 2>&1 | grep -E 'not found' || true)"
VEROUT="$(LD_LIBRARY_PATH="$LLAMA_DIR" "$LLAMA_BIN" --version 2>&1 || true)"
if printf '%s\n%s' "$MISSING" "$VEROUT" | grep -q 'GLIBC_'; then
  NEED="$(printf '%s\n%s' "$MISSING" "$VEROUT" | grep -oE 'GLIBC_[0-9.]+' | sort -Vu | tail -1)"
  HAVE="$(ldd --version 2>&1 | head -1 | grep -oE '[0-9]+\.[0-9]+$')"
  warn "This binary needs $NEED but this OS has glibc $HAVE."
  warn "It was built on a newer distribution. Build llama.cpp from source on"
  warn "this host instead (source tarball for the same tag, b10867)."
  die "Binary incompatible with this OS."
fi
if [[ -n "$MISSING" ]]; then
  warn "Missing shared libraries:"; printf '  %s\n' "$MISSING" >&2
  die "llama-server cannot load its libraries."
fi
say "Runs on this OS: $(printf '%s' "$VEROUT" | grep -iE 'version|build' | head -1)"

HELP="$(LD_LIBRARY_PATH="$LLAMA_DIR" "$LLAMA_BIN" --help 2>&1 || true)"
has_flag() { printf '%s' "$HELP" | grep -qE -- "(^|[ ,])$1([ ,=]|$)"; }

# ---------------------------------------------------------------------------
# Model
# ---------------------------------------------------------------------------
step "Finding the model"

mapfile -t MODELS < <(find "$MODEL_DIR" -maxdepth 2 -type f -name '*.gguf' 2>/dev/null | sort)
((${#MODELS[@]})) || die "No .gguf model in $MODEL_DIR"
MODEL="${MODELS[0]}"
((${#MODELS[@]} > 1)) && warn "Several models; using $(basename "$MODEL")" || true

MAGIC="$(head -c 4 "$MODEL" 2>/dev/null || true)"
[[ "$MAGIC" == "GGUF" ]] || die "$(basename "$MODEL") does not start with GGUF: damaged or wrong format."

MODEL_MB=$(( $(stat -c %s "$MODEL") / 1024 / 1024 ))
say "Model: $(basename "$MODEL") (${MODEL_MB} MB)"

if [[ -f "$MODEL_DIR/SHA256SUMS" ]]; then
  if (cd "$MODEL_DIR" && sha256sum -c --quiet SHA256SUMS >>"$RUNLOG" 2>&1); then
    say "Checksum matches SHA256SUMS"
  else
    die "Model checksum does not match SHA256SUMS. The copy may be incomplete."
  fi
else
  (cd "$MODEL_DIR" && sha256sum ./*.gguf > SHA256SUMS)
  say "Recorded SHA256SUMS for future checks"
fi

# Memory: model plus KV cache plus headroom for the OS and nginx
(( RAM_MB > MODEL_MB + 3072 )) || warn "Only $RAM_MB MB RAM for a $MODEL_MB MB model: expect swapping."

# ---------------------------------------------------------------------------
# Sizing
# ---------------------------------------------------------------------------
step "Sizing"

# Leave one core for nginx and the OS on small hosts
[[ -n "$THREADS" ]] || THREADS=$(( CPUS > 4 ? CPUS - 1 : CPUS ))
# Context shared across parallel slots. Explanations are short: an advisory
# summary plus versions is well under 2k tokens per request.
[[ -n "$CTX" ]] || CTX=$(( 4096 * PARALLEL ))
say "threads=$THREADS  context=$CTX  parallel slots=$PARALLEL ($(( CTX / PARALLEL )) tokens each)"

# ---------------------------------------------------------------------------
# API key
# ---------------------------------------------------------------------------
step "API key"
mkdir -p "$CONF_DIR"
if [[ -s "$KEY_FILE" ]]; then
  say "Keeping the existing key."
else
  [[ "$DRY_RUN" == yes ]] || { openssl rand -hex 32 > "$KEY_FILE"; say "Generated a new key."; }
fi
[[ "$DRY_RUN" == yes ]] || { chown root:"$SVC_USER" "$KEY_FILE"; chmod 0640 "$KEY_FILE"; }

# ---------------------------------------------------------------------------
# Arguments, using only flags this build supports
# ---------------------------------------------------------------------------
ARGS=(-m "$MODEL" --host 127.0.0.1 --port "$LISTEN_PORT"
      -c "$CTX" -t "$THREADS" -np "$PARALLEL")

if has_flag --api-key-file; then
  ARGS+=(--api-key-file "$KEY_FILE")        # key stays out of the process list
elif has_flag --api-key; then
  warn "This build lacks --api-key-file; the key will be visible in ps output."
  ARGS+=(--api-key "$(api_key)")
else
  die "This llama-server build supports no API key option."
fi
has_flag --jinja      && ARGS+=(--jinja)       || true   # correct Qwen3 chat template
has_flag --no-webui   && ARGS+=(--no-webui)    || true   # no browser UI on a server
has_flag --metrics    && ARGS+=(--metrics)     || true
has_flag --slot-save-path && ARGS+=(--slot-save-path "$CACHE_DIR") || true

say "Supported extras: $(printf '%s ' "${ARGS[@]}" | grep -oE -- '--(jinja|no-webui|metrics|slot-save-path)' | tr '\n' ' ' || true)"

if [[ "$DRY_RUN" == yes ]]; then
  step "Dry run"
  K="$(api_key)"
  if [[ -n "$K" ]]; then say "Would run: $LLAMA_BIN ${ARGS[*]//$K/<key>}"
  else say "Would run: $LLAMA_BIN ${ARGS[*]}"; fi
  say "Would allow only $PATCH01_IP on 443."
  exit 0
fi

# ---------------------------------------------------------------------------
# systemd service
# ---------------------------------------------------------------------------
step "Installing the llama-server service"

ln -sfn "$LLAMA_BIN" "$BIN_DIR/llama-server"

# Arguments stored one per line, so paths with spaces survive
printf '%s\n' "${ARGS[@]}" > "$CONF_DIR/llama-server.args"
chown root:"$SVC_USER" "$CONF_DIR/llama-server.args"; chmod 0640 "$CONF_DIR/llama-server.args"

cat > "$CONF_DIR/run-llama-server.sh" <<EOF
#!/usr/bin/env bash
# Generated by ai01-setup.sh. Reads one argument per line.
mapfile -t A < "$CONF_DIR/llama-server.args"
export LD_LIBRARY_PATH="$LLAMA_DIR"
exec "$BIN_DIR/llama-server" "\${A[@]}"
EOF
chmod 0750 "$CONF_DIR/run-llama-server.sh"; chown root:"$SVC_USER" "$CONF_DIR/run-llama-server.sh"

chown -R root:"$SVC_USER" "$BIN_DIR" "$MODEL_DIR"
find "$BIN_DIR" "$MODEL_DIR" -type d -exec chmod 0750 {} \;
find "$MODEL_DIR" -type f -exec chmod 0640 {} \;
chown "$SVC_USER":"$SVC_USER" "$LOG_DIR" "$CACHE_DIR" 2>/dev/null || mkdir -p "$CACHE_DIR"
chown "$SVC_USER":"$SVC_USER" "$CACHE_DIR"

# Memory ceiling: model plus generous KV cache, so a runaway cannot take the
# whole host down with it
MEM_MAX=$(( MODEL_MB + 4096 ))

cat > /etc/systemd/system/llama-server.service <<EOF
[Unit]
Description=llama.cpp inference server for PATCH-01 (loopback only)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$SVC_USER
Group=$SVC_USER
ExecStart=$CONF_DIR/run-llama-server.sh
Restart=on-failure
RestartSec=5
# The model takes a while to map on first start
TimeoutStartSec=300

MemoryMax=${MEM_MAX}M
LimitNOFILE=65536

# Sandbox: read-only system, no privilege gain, writes only where needed
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictSUIDSGID=yes
LockPersonality=yes
RestrictNamespaces=yes
ReadWritePaths=$LOG_DIR $CACHE_DIR
# Loopback only, even if the listen address were changed by mistake
IPAddressDeny=any
IPAddressAllow=localhost

StandardOutput=append:$LOG_DIR/llama-server.log
StandardError=append:$LOG_DIR/llama-server.log

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable llama-server >/dev/null 2>&1
systemctl restart llama-server

say "Waiting for the model to load..."
for i in $(seq 1 180); do
  if curl -sf --max-time 5 "http://127.0.0.1:$LISTEN_PORT/health" >/dev/null 2>&1; then
    say "llama-server is ready (${i}s)"; break
  fi
  if ! systemctl is-active --quiet llama-server; then
    warn "llama-server stopped. Last log lines:"
    tail -25 "$LOG_DIR/llama-server.log" >&2 || true
    die "llama-server failed to start."
  fi
  if (( i == 180 )); then tail -25 "$LOG_DIR/llama-server.log" >&2; die "Not ready after 180s."; fi
  sleep 1
done

# ---------------------------------------------------------------------------
# NGINX on 443
# ---------------------------------------------------------------------------
step "NGINX on 443"

if ! command -v nginx >/dev/null 2>&1; then
  warn "nginx is not installed. AI-01 has no internet, but PATCH-01 mirrors"
  warn "RHEL 9 AppStream, which contains nginx. Point dnf at it:"
  warn ""
  warn "  cat > /etc/yum.repos.d/patch01.repo <<'REPO'"
  warn "  [patch01-rhel9-baseos]"
  warn "  name=PATCH-01 RHEL 9 BaseOS"
  warn "  baseurl=https://SGPINFAPPXU01/pulp/content/rhel9-baseos/"
  warn "  sslverify=0"
  warn "  gpgcheck=1"
  warn "  gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-redhat-release"
  warn "  [patch01-rhel9-appstream]"
  warn "  name=PATCH-01 RHEL 9 AppStream"
  warn "  baseurl=https://SGPINFAPPXU01/pulp/content/rhel9-appstream/"
  warn "  sslverify=0"
  warn "  gpgcheck=1"
  warn "  gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-redhat-release"
  warn "  REPO"
  warn "  dnf install -y nginx"
  warn ""
  die "Install nginx, then re-run. llama-server is already running."
fi

FQDN="$(hostname -f 2>/dev/null || hostname)"
IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
if [[ ! -s "$CERT_DIR/ai01.crt" ]]; then
  mkdir -p "$CERT_DIR"
  openssl req -x509 -nodes -newkey rsa:2048 -days 825 \
    -keyout "$CERT_DIR/ai01.key" -out "$CERT_DIR/ai01.crt" \
    -subj "/CN=$FQDN/O=Patch Platform/OU=AI-01" \
    -addext "subjectAltName=DNS:$FQDN,DNS:$(hostname -s),IP:$IP,IP:127.0.0.1" \
    -addext "extendedKeyUsage=serverAuth" >>"$RUNLOG" 2>&1 || die "Certificate generation failed."
  chmod 0600 "$CERT_DIR/ai01.key"; chmod 0644 "$CERT_DIR/ai01.crt"
  say "Created a self-signed placeholder certificate for $FQDN"
fi

cat > /etc/nginx/conf.d/ai01-llm.conf <<EOF
# Generated by ai01-setup.sh. Only PATCH-01 may connect.
server {
    listen 443 ssl;
    server_name _;

    ssl_certificate     $CERT_DIR/ai01.crt;
    ssl_certificate_key $CERT_DIR/ai01.key;
    ssl_protocols       TLSv1.2 TLSv1.3;
    server_tokens       off;

    # firewalld is disabled here, so this list is the network control
    allow $PATCH01_IP;
    allow 127.0.0.1;
    deny  all;

    client_max_body_size 256k;

    location = /health {
        proxy_pass http://127.0.0.1:$LISTEN_PORT/health;
    }

    # The only inference endpoint PATCH-01 uses. The API key is enforced by
    # llama-server itself.
    location = /v1/chat/completions {
        proxy_pass http://127.0.0.1:$LISTEN_PORT/v1/chat/completions;
        proxy_http_version 1.1;
        proxy_set_header Authorization \$http_authorization;
        proxy_buffering off;
        # CPU generation is slow; do not cut long answers off
        proxy_read_timeout 600s;
        proxy_send_timeout 600s;
    }

    location = /v1/models {
        proxy_pass http://127.0.0.1:$LISTEN_PORT/v1/models;
        proxy_set_header Authorization \$http_authorization;
    }

    # Everything else, including slot management and the web UI, is closed
    location / { return 404; }
}
EOF

nginx -t >>"$RUNLOG" 2>&1 || { tail -15 "$RUNLOG" >&2; die "nginx configuration invalid."; }
systemctl enable nginx >/dev/null 2>&1
systemctl restart nginx
say "nginx serving 443, allowing only $PATCH01_IP"

# ---------------------------------------------------------------------------
# Verify and benchmark
# ---------------------------------------------------------------------------
step "Verifying"
CODE="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 https://127.0.0.1/health || echo 000)"
[[ "$CODE" == "200" ]] && say "HTTPS /health: 200" || warn "HTTPS /health returned $CODE"

bench || warn "Benchmark failed; see $LOG_DIR/llama-server.log"

cat > "$CONF_DIR/ai01.env" <<EOF
# Generated by ai01-setup.sh on $(date -Is)
AI01_FQDN="$FQDN"
AI01_URL="https://$FQDN"
AI01_ALLOWED_CLIENT="$PATCH01_IP"
AI01_MODEL="$(basename "$MODEL")"
AI01_BINARY="$LLAMA_BIN"
AI01_THREADS="$THREADS"
AI01_CTX="$CTX"
AI01_PARALLEL="$PARALLEL"
EOF
chmod 0640 "$CONF_DIR/ai01.env"

echo
echo "================================================================"
echo " AI-01 READY"
echo "================================================================"
printf ' URL:      https://%s\n' "$FQDN"
printf ' Model:    %s\n' "$(basename "$MODEL")"
printf ' Allowed:  %s only\n' "$PATCH01_IP"
printf ' Log:      %s/llama-server.log\n' "$LOG_DIR"
echo
echo " Next, on PATCH-01 you will need the API key:"
echo "   ./ai01-setup.sh --show-key"
echo
echo " Validate:   ./ai01-setup.sh --check"
echo " Benchmark:  ./ai01-setup.sh --bench"
