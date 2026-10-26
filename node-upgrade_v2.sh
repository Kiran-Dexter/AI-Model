#!/usr/bin/env bash
#
# node-upgrade.sh - Offline (air-gapped) Node.js upgrade for RHEL 8
#
# Upgrades the EXISTING Node.js in the place it is installed, using an official
# nodejs.org tarball you copied to /tmp (e.g. /tmp/node-v24.22.1-linux-x64.tar.xz).
#
#   * Detects how the current Node was installed:
#       - RPM (RHEL AppStream / NodeSource)  -> builds a single RPM from the tarball
#                                               and upgrades it with rpm -Uvh
#                                               (old nodejs/npm RPMs are replaced)
#       - tarball in a prefix (/usr/local)   -> replaced in place
#       - versioned dir + symlinks (/opt/node-v22...) -> new dir, symlinks switched,
#                                               old dir removed after tests pass
#   * Verifies the SHA-256 against SHASUMS256.txt (if you copied it too)
#   * Self-tests the new binary BEFORE touching the system, and again AFTER
#   * Backs up the old install and offers automatic rollback on failure
#   * Keeps your global npm packages and npm prefix working
#
# Usage:
#   sudo ./node-upgrade.sh                      # interactive upgrade
#   sudo ./node-upgrade.sh -t /tmp/node-v24.22.1-linux-x64.tar.xz
#   sudo ./node-upgrade.sh --dry-run            # verify + self-test only, change nothing
#        ./node-upgrade.sh --check              # self-test the node currently on PATH
#   sudo ./node-upgrade.sh --rollback /var/backups/node-upgrade/<timestamp>
#
# Options:
#   -t, --tarball FILE   tarball to install (default: pick from /tmp)
#   -d, --dir DIR        directory to search for tarballs (default: /tmp)
#   -p, --node PATH      the existing node binary to upgrade (default: auto-detect)
#   -y, --yes            accept defaults, no prompts
#   -n, --dry-run        stop after pre-flight tests
#   -c, --check          only run the self-test against an installed node
#   -r, --rollback DIR   restore a previous install from a backup directory
#   -h, --help           show this help

set -Eeuo pipefail
umask 022

TARBALL=""; SEARCH_DIR="/tmp"; NODE_ARG=""
ASSUME_YES=0; DRY_RUN=0; CHECK_ONLY=0; ROLLBACK_DIR=""
BACKUP_BASE="/var/backups/node-upgrade"
STAMP=$(date +%Y%m%d-%H%M%S)
LOG=""; WORK=""; STAGE=""; BACKUP_DIR=""; INSTALL_STARTED=0
MODE=""; PREFIX=""; OLD_NODE=""; OLD_REAL=""; OLD_VER="none"; NEW_VER=""
LINK_DIR=""; NEW_DIR=""; OLD_NPM_PREFIX=""; BUILT_RPM=""
RPM_PKGS=()
CHOICE=1

if [[ -t 1 ]]; then R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; B=$'\e[1m'; N=$'\e[0m'
else R=""; G=""; Y=""; B=""; N=""; fi

# ---------------------------------------------------------------- helpers ---
log()  { [[ -n $LOG ]] && printf '%s\n' "$*" >>"$LOG" || true; }
say()  { printf '%s\n' "$*"; log "$*"; }
info() { say ""; say "${B}==> $*${N}"; }
ok()   { say "  ${G}PASS${N} $*"; }
warn() { say "  ${Y}WARN${N} $*"; }
bad()  { say "  ${R}FAIL${N} $*"; }
die()  { say "${R}ERROR:${N} $*"; exit 1; }

usage() { sed -n '2,/^$/{s/^# \{0,1\}//;p}' "$0"; }

ask() { # ask "question" [y|n default]
  local q=$1 def=${2:-n} hint ans
  [[ $def == y ]] && hint="[Y/n]" || hint="[y/N]"
  if (( ASSUME_YES )); then say "$q $hint -> ${def} (auto)"; [[ $def == y ]]; return; fi
  read -r -p "$q $hint " ans </dev/tty || ans=""
  ans=${ans:-$def}; log "$q -> $ans"
  [[ $ans =~ ^[Yy] ]]
}

choose() { # choose "prompt" item... -> sets CHOICE (1-based)
  local prompt=$1; shift
  local i=1 item ans
  say "$prompt"
  for item in "$@"; do say "   $i) $item"; i=$((i+1)); done
  if (( ASSUME_YES )); then CHOICE=1; say "   -> 1 (auto)"; return; fi
  while :; do
    read -r -p "   Enter 1-$#: " ans </dev/tty || ans=""
    if [[ $ans =~ ^[0-9]+$ ]] && (( ans >= 1 && ans <= $# )); then CHOICE=$ans; log "-> $ans"; return; fi
  done
}

cleanup() { [[ -n $WORK && -d $WORK ]] && rm -rf "$WORK"; return 0; }

on_err() {
  local rc=$? line=$1
  trap - ERR
  # failures inside $(...) / <(...) sub-shells are handled by the caller
  (( BASH_SUBSHELL == 0 )) || exit "$rc"
  say "${R}Unexpected failure at line $line (exit $rc).${N}"
  if (( INSTALL_STARTED )) && [[ -f ${BACKUP_DIR:-/nonexistent}/meta.env ]]; then
    if ask "Roll back to the previous Node.js now?" y; then do_rollback "$BACKUP_DIR"; fi
  fi
  [[ -n $LOG ]] && say "Log: $LOG"
  exit "$rc"
}
trap 'on_err $LINENO' ERR
trap cleanup EXIT

fix_selinux() { command -v restorecon >/dev/null 2>&1 && restorecon -RF "$@" 2>/dev/null || true; }

# ------------------------------------------------------------- self-test ---
write_selftest() {
  cat >"$1" <<'JS'
'use strict';
const assert = require('assert');
let failed = 0;
async function t(name, fn, soft) {
  try { await fn(); console.log('PASS ' + name); }
  catch (e) { console.log((soft ? 'WARN ' : 'FAIL ') + name + ': ' + ((e && e.message) || e)); if (!soft) failed++; }
}
(async () => {
  const crypto = require('crypto'), zlib = require('zlib'), fs = require('fs'), os = require('os'),
        path = require('path'), tls = require('tls'), http = require('http');
  await t('crypto: SHA-256 known answer', () => assert.strictEqual(
    crypto.createHash('sha256').update('abc').digest('hex'),
    'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad'));
  await t('crypto: random bytes differ', () => assert.notStrictEqual(
    crypto.randomBytes(32).toString('hex'), crypto.randomBytes(32).toString('hex')));
  await t('crypto: AES-256-GCM round trip', () => {
    const key = crypto.randomBytes(32), iv = crypto.randomBytes(12);
    const c = crypto.createCipheriv('aes-256-gcm', key, iv);
    const enc = Buffer.concat([c.update('secret'), c.final()]), tag = c.getAuthTag();
    const d = crypto.createDecipheriv('aes-256-gcm', key, iv); d.setAuthTag(tag);
    assert.strictEqual(Buffer.concat([d.update(enc), d.final()]).toString(), 'secret');
  });
  await t('zlib: brotli round trip', () => {
    const b = Buffer.concat([crypto.randomBytes(2048), Buffer.alloc(8192, 'a')]);
    assert.ok(zlib.brotliDecompressSync(zlib.brotliCompressSync(b)).equals(b));
  });
  await t('zlib: gzip round trip', () => {
    const b = Buffer.alloc(8192, 'node');
    assert.ok(zlib.gunzipSync(zlib.gzipSync(b)).equals(b));
  });
  await t('tls: ciphers and root CAs present', () => {
    assert.ok(tls.getCiphers().length > 10, 'no ciphers');
    assert.ok(tls.rootCertificates.length > 50, 'root CA store looks empty');
  });
  await t('fs: write/read temp file', () => {
    const f = path.join(os.tmpdir(), 'node-selftest-' + process.pid);
    fs.writeFileSync(f, 'ok'); const v = fs.readFileSync(f, 'utf8'); fs.unlinkSync(f);
    assert.strictEqual(v, 'ok');
  });
  await t('child_process: spawn node', () => {
    const r = require('child_process').spawnSync(process.execPath, ['-e', 'process.stdout.write("ok")']);
    assert.strictEqual(String(r.stdout), 'ok');
  });
  await t('worker_threads: run a worker', () => new Promise((res, rej) => {
    const { Worker } = require('worker_threads');
    const w = new Worker('require("worker_threads").parentPort.postMessage(6*7)', { eval: true });
    w.once('message', m => { w.terminate(); m === 42 ? res() : rej(new Error('got ' + m)); });
    w.once('error', rej);
  }));
  await t('http: local server round trip', () => new Promise((res, rej) => {
    const srv = http.createServer((q, s) => s.end('pong'));
    const timer = setTimeout(() => { srv.close(); rej(new Error('timeout')); }, 5000);
    srv.listen(0, '127.0.0.1', () => {
      http.get({ host: '127.0.0.1', port: srv.address().port, path: '/', agent: false }, r => {
        let d = ''; r.on('data', c => d += c);
        r.on('end', () => { clearTimeout(timer); srv.close(); d === 'pong' ? res() : rej(new Error(d)); });
      }).on('error', e => { clearTimeout(timer); srv.close(); rej(e); });
    });
  }));
  await t('Intl: full ICU (de-DE number format)', () =>
    assert.strictEqual(new Intl.NumberFormat('de-DE').format(1234.5), '1.234,5'), true);
  console.log(`INFO node ${process.version}, openssl ${process.versions.openssl}, v8 ${process.versions.v8}, icu ${process.versions.icu || 'none'}`);
  console.log('DONE ' + failed);
})();
JS
}

# run_selftest NODE_BIN NPM_CLI_JS [EXPECTED_VERSION]  -> returns number of failures
run_selftest() {
  local node=$1 npmcli=$2 expect=${3:-} fails=0 line v done_seen=0 js="$WORK/selftest.js"
  [[ -f $js ]] || write_selftest "$js"
  if ! v=$("$node" -v 2>&1); then bad "node does not start: $v"; return 1; fi
  if [[ -n $expect && $v != "v$expect" ]]; then bad "version is $v, expected v$expect"; fails=$((fails+1))
  else ok "node starts: $v"; fi
  while IFS= read -r line; do
    case $line in
      PASS\ *) ok "${line#PASS }" ;;
      WARN\ *) warn "${line#WARN }" ;;
      FAIL\ *) bad "${line#FAIL }"; fails=$((fails+1)) ;;
      INFO\ *) say "       ${line#INFO }" ;;
      DONE\ *) done_seen=1 ;;
      *)       say "       $line" ;;
    esac
  done < <("$node" "$js" 2>&1 || true)
  (( done_seen )) || { bad "self-test script did not finish (node crashed?)"; fails=$((fails+1)); }
  if [[ -f $npmcli ]]; then
    if v=$("$node" "$npmcli" -v 2>&1); then ok "npm runs: $v"; else bad "npm failed: $v"; fails=$((fails+1)); fi
    local npxcli; npxcli="$(dirname "$npmcli")/npx-cli.js"
    if [[ -f $npxcli ]]; then
      if v=$("$node" "$npxcli" -v 2>&1); then ok "npx runs: $v"; else bad "npx failed: $v"; fails=$((fails+1)); fi
    fi
  else
    warn "npm not found at $npmcli (skipped)"
  fi
  return "$fails"
}

npm_cli_for() { # npm_cli_for NODE_BIN -> path of npm-cli.js next to that node
  local real; real=$(readlink -f "$1")
  printf '%s\n' "$(dirname "$(dirname "$real")")/lib/node_modules/npm/bin/npm-cli.js"
}

list_globals() { # list_globals PREFIX -> global npm packages (excluding npm/corepack)
  local d="$1/lib/node_modules" e s
  [[ -d $d ]] || return 0
  for e in "$d"/*; do
    [[ -e $e ]] || continue
    case ${e##*/} in
      npm|corepack) ;;
      @*) for s in "$e"/*; do [[ -e $s ]] && printf '%s/%s\n' "${e##*/}" "${s##*/}"; done ;;
      *) printf '%s\n' "${e##*/}" ;;
    esac
  done | sort
}

# ------------------------------------------------------------- pre-flight ---
preflight() {
  info "Pre-flight checks"
  (( EUID == 0 )) || die "Run as root: sudo $0 $*"
  if [[ -f /etc/redhat-release ]]; then ok "OS: $(cat /etc/redhat-release)"
  else warn "Not a RHEL-family system; continuing anyway"; fi
  local m; m=$(uname -m)
  case $m in
    x86_64) ARCH=x64 ;; aarch64) ARCH=arm64 ;; ppc64le) ARCH=ppc64le ;; s390x) ARCH=s390x ;;
    *) die "Unsupported CPU architecture: $m" ;;
  esac
  ok "Architecture: $m (tarball must be linux-$ARCH)"
  local glibc; glibc=$(ldd --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+$' || echo "?")
  ok "glibc: $glibc"
  command -v tar >/dev/null && command -v xz >/dev/null || die "tar and xz are required"
}

pick_tarball() {
  info "Locating Node.js tarball"
  if [[ -z $TARBALL ]]; then
    local -a found=()
    mapfile -t found < <(find "$SEARCH_DIR" -maxdepth 1 -type f \
      \( -name 'node-v*-linux-*.tar.xz' -o -name 'node-v*-linux-*.tar.gz' \) 2>/dev/null | sort -V)
    (( ${#found[@]} )) || die "No node-v*-linux-*.tar.xz in $SEARCH_DIR. Copy it there first (from https://nodejs.org/dist/)."
    if (( ${#found[@]} == 1 )); then TARBALL=${found[0]}
    else choose "Several tarballs found. Which one?" "${found[@]}"; TARBALL=${found[CHOICE-1]}; fi
  fi
  [[ -f $TARBALL ]] || die "Tarball not found: $TARBALL"
  TARBALL=$(readlink -f "$TARBALL")
  ok "Tarball: $TARBALL"
  [[ $(basename "$TARBALL") == *"-linux-$ARCH."* ]] || die "Tarball is not for linux-$ARCH: $(basename "$TARBALL")"
}

verify_checksum() {
  info "Verifying download integrity"
  local name dir sums line actual expected
  name=$(basename "$TARBALL"); dir=$(dirname "$TARBALL"); sums="$dir/SHASUMS256.txt"
  actual=$(sha256sum "$TARBALL" | awk '{print $1}')
  if [[ -f $sums ]]; then
    line=$(awk -v n="$name" '$2 == n {print $1}' "$sums")
    if [[ -z $line ]]; then
      warn "$name is not listed in SHASUMS256.txt (wrong version of the file?)"
      ask "Continue without checksum verification?" n || die "Aborted."
    else
      expected=$line
      [[ $actual == "$expected" ]] || die "SHA-256 MISMATCH - the tarball is corrupt or tampered with.
       expected $expected
       actual   $actual"
      ok "SHA-256 matches SHASUMS256.txt"
    fi
  else
    warn "SHASUMS256.txt not found next to the tarball."
    say  "       SHA-256 of tarball: $actual"
    say  "       Compare it with https://nodejs.org/dist/v<version>/SHASUMS256.txt"
    ask "Continue without automatic verification?" n || die "Aborted. Copy SHASUMS256.txt into $dir and re-run."
  fi
}

stage_and_pretest() {
  info "Unpacking to a staging area (system not touched yet)"
  WORK=$(mktemp -d /tmp/node-upgrade.XXXXXX)
  tar -xf "$TARBALL" -C "$WORK" --no-same-owner
  STAGE=$(find "$WORK" -mindepth 1 -maxdepth 1 -type d -name 'node-v*' | head -1)
  [[ -n $STAGE && -x $STAGE/bin/node ]] || die "Tarball does not contain bin/node"
  local v
  v=$("$STAGE/bin/node" -v 2>&1) || die "New node binary cannot run on this system: $v
       (usually means glibc is too old for this Node version)"
  NEW_VER=${v#v}
  ok "Unpacked Node.js v$NEW_VER"

  info "Pre-flight self-test of the NEW binary"
  local fails=0
  run_selftest "$STAGE/bin/node" "$STAGE/lib/node_modules/npm/bin/npm-cli.js" "$NEW_VER" || fails=$?
  if (( fails )); then
    bad "$fails pre-flight test(s) failed."
    ask "Continue anyway? (not recommended)" n || die "Aborted before any change was made."
  else
    ok "All pre-flight tests passed"
  fi
}

# ---------------------------------------------------------- detect current ---
detect_existing() {
  info "Finding the existing Node.js installation"
  local -a cands=() labels=()
  local p v owner
  if [[ -n $NODE_ARG ]]; then
    [[ -x $NODE_ARG ]] || die "Not an executable: $NODE_ARG"
    cands=("$NODE_ARG")
  else
    for p in "$(command -v node 2>/dev/null || true)" /usr/bin/node /usr/local/bin/node /opt/*/bin/node /usr/local/*/bin/node; do
      [[ -n $p && -x $p && $p != "$WORK"* ]] || continue
      [[ " ${cands[*]-} " == *" $p "* ]] || cands+=("$p")
    done
  fi
  for p in "${cands[@]}"; do
    v=$("$p" -v 2>/dev/null || echo "?")
    owner=$(rpm -qf "$(readlink -f "$p")" 2>/dev/null || echo "not from an RPM")
    labels+=("$p  ($v, $owner)")
  done
  labels+=("Enter another path" "No existing Node - fresh install")

  choose "Which Node.js should be upgraded?" "${labels[@]}"
  if (( CHOICE <= ${#cands[@]} )); then
    OLD_NODE=${cands[CHOICE-1]}
  elif (( CHOICE == ${#cands[@]} + 1 )); then
    read -r -p "   Path to the existing node binary: " OLD_NODE </dev/tty
    [[ -x $OLD_NODE ]] || die "Not an executable: $OLD_NODE"
  else
    OLD_NODE=""
  fi

  if [[ -z $OLD_NODE ]]; then
    MODE=inplace; OLD_VER=none
    local pfx="/usr/local"
    if (( ! ASSUME_YES )); then read -r -p "   Install prefix [/usr/local]: " pfx </dev/tty; pfx=${pfx:-/usr/local}; fi
    PREFIX=$pfx
    ok "Fresh install into $PREFIX"
    return
  fi

  OLD_REAL=$(readlink -f "$OLD_NODE")
  OLD_VER=$("$OLD_REAL" -v 2>/dev/null || echo "v?"); OLD_VER=${OLD_VER#v}
  PREFIX=$(dirname "$(dirname "$OLD_REAL")")
  ok "Existing: $OLD_NODE -> $OLD_REAL (v$OLD_VER), prefix $PREFIX"

  if rpm -qf "$OLD_REAL" >/dev/null 2>&1; then
    mapfile -t RPM_PKGS < <(rpm -qa --qf '%{NAME}\n' nodejs nodejs-libs nodejs-full-i18n \
                              nodejs-docs nodejs-devel npm 2>/dev/null | sort -u)
    ok "Installed by RPM: $(rpm -qf "$OLD_REAL")"
    if command -v rpmbuild >/dev/null 2>&1; then
      MODE=rpm
    else
      warn "rpmbuild is not installed, so a replacement RPM cannot be built."
      choose "How do you want to continue?" \
        "Abort (install it from RHEL media: dnf install rpm-build, then re-run)" \
        "Remove the old RPMs and install the tarball files into $PREFIX (not tracked by rpm)"
      (( CHOICE == 1 )) && die "Aborted. Install rpm-build and re-run."
      MODE=rpm-replace
    fi
  elif [[ -L $OLD_NODE && $(basename "$PREFIX") =~ ^node-v[0-9] ]]; then
    MODE=versioned
    LINK_DIR=$(dirname "$OLD_NODE")
    NEW_DIR="$(dirname "$PREFIX")/$(basename "$STAGE")"
    ok "Versioned directory with symlinks in $LINK_DIR"
  else
    MODE=inplace
    ok "Plain tarball install in $PREFIX"
  fi

  local newmaj=${NEW_VER%%.*} oldmaj=${OLD_VER%%.*}
  if [[ $OLD_VER == "$NEW_VER" ]]; then
    ask "v$NEW_VER is already installed. Reinstall it?" n || die "Nothing to do."
  elif [[ $oldmaj =~ ^[0-9]+$ ]] && (( newmaj < oldmaj )); then
    warn "This is a DOWNGRADE (v$OLD_VER -> v$NEW_VER)."
    ask "Continue with the downgrade?" n || die "Aborted."
  fi

  # npm global prefix of the old install
  local npmcli; npmcli=$(npm_cli_for "$OLD_REAL")
  if [[ -f $npmcli ]]; then
    OLD_NPM_PREFIX=$("$OLD_REAL" "$npmcli" prefix -g 2>/dev/null || true)
  elif command -v npm >/dev/null 2>&1; then
    OLD_NPM_PREFIX=$(PATH="$(dirname "$OLD_REAL"):$PATH" npm prefix -g 2>/dev/null || true)
  fi
  [[ -n $OLD_NPM_PREFIX ]] && ok "npm global prefix: $OLD_NPM_PREFIX"
}

prepare_npmrc() {
  # Keep npm's global prefix (where global packages live) the same as before.
  local target=$PREFIX
  [[ $MODE == versioned ]] && target=$NEW_DIR
  # official tarballs ship no etc/npmrc; drop one if present so it can't move globals
  rm -f "$STAGE/etc/npmrc"
  if [[ -n $PREFIX && -f $PREFIX/etc/npmrc ]]; then
    mkdir -p "$STAGE/etc"; cp -p "$PREFIX/etc/npmrc" "$STAGE/etc/npmrc"
    ok "Carrying over existing $PREFIX/etc/npmrc"
  elif [[ -n $OLD_NPM_PREFIX && $OLD_NPM_PREFIX != "$target" && $OLD_NPM_PREFIX != "$PREFIX" ]]; then
    say "  Global npm packages currently live under $OLD_NPM_PREFIX;"
    say "  the new npm would default to $target."
    if ask "Keep using $OLD_NPM_PREFIX for global npm packages?" y; then
      mkdir -p "$STAGE/etc"; printf 'prefix=%s\n' "$OLD_NPM_PREFIX" >"$STAGE/etc/npmrc"
      ok "Will write prefix=$OLD_NPM_PREFIX to the new npmrc"
    fi
  fi
}

# Find installed RPMs (other than the ones we already replace) that own files the
# new Node.js would write. Those are the packages rpm would report as conflicts.
check_conflicts() {
  [[ $MODE != versioned && -n $PREFIX ]] || return 0
  command -v rpm >/dev/null 2>&1 || return 0
  info "Checking for RPM package conflicts"
  local targets="$WORK/conflict-targets" owners="$WORK/conflict-owners" pairs="$WORK/conflict-pairs" p o
  (cd "$STAGE" && find bin include lib share etc \( -type f -o -type l \) 2>/dev/null) \
    | while IFS= read -r p; do [[ -e $PREFIX/$p || -L $PREFIX/$p ]] && printf '%s\n' "$PREFIX/$p"; done >"$targets" || true
  if [[ ! -s $targets ]]; then ok "No existing files would be overwritten"; return 0; fi
  xargs -a "$targets" -d '\n' rpm -qf --qf '%{NAME}\n' >"$owners" 2>/dev/null || true
  # rpm -qf prints one line per path, in order; "file ... is not owned" lines contain spaces
  paste -d '\t' "$owners" "$targets" | awk -F'\t' '$1 !~ / / && $1 != "" && $1 != "nodejs-upstream"' >"$pairs" || true

  local -a extra=()
  while IFS=$'\t' read -r o p; do
    [[ " ${RPM_PKGS[*]-} " == *" $o "* || " ${extra[*]-} " == *" $o "* ]] || extra+=("$o")
  done <"$pairs"

  if (( ${#extra[@]} == 0 )); then
    ok "No other packages own files the new Node.js will write"
    return 0
  fi
  warn "These installed packages own files the new Node.js would overwrite:"
  for o in "${extra[@]}"; do
    say "         $(rpm -q "$o")"
    awk -F'\t' -v n="$o" '$1 == n {print "             " $2}' "$pairs" | head -3 | tee -a "${LOG:-/dev/null}"
    local cnt; cnt=$(awk -F'\t' -v n="$o" '$1 == n' "$pairs" | wc -l)
    (( cnt > 3 )) && say "             ... and $((cnt-3)) more file(s)"
    local deps; deps=$(rpm -q --whatrequires "$o" 2>/dev/null | grep -v 'no package requires' | tr '\n' ' ' || true)
    [[ -n $deps ]] && say "             required by: $deps"
  done
  say "  They are almost always parts of the old Node.js (headers, docs, bundled tools)."
  choose "How do you want to resolve this?" \
    "Replace them as part of the upgrade (backed up first, removed in the same rpm transaction)" \
    "Abort - change nothing so I can review"
  (( CHOICE == 1 )) || die "Aborted - nothing was changed. Review with: rpm -qf <file>, rpm -qi <package>"
  RPM_PKGS+=("${extra[@]}")
  [[ $MODE == inplace ]] && MODE=rpm-replace
  ok "Will also replace: ${extra[*]}"
}

show_plan() {
  info "Plan"
  say "  Current : ${OLD_NODE:-<none>} (v$OLD_VER)"
  say "  New     : v$NEW_VER from $(basename "$TARBALL")"
  case $MODE in
    rpm)         say "  Method  : build RPM 'nodejs-upstream-$NEW_VER' and rpm -Uvh it into $PREFIX"
                 say "            replaces RPMs: ${RPM_PKGS[*]}" ;;
    rpm-replace) say "  Method  : rpm -e ${RPM_PKGS[*]}, then copy files into $PREFIX" ;;
    inplace)     say "  Method  : replace files in $PREFIX (bin, lib/node_modules/npm, include/node, share)" ;;
    versioned)   say "  Method  : install to $NEW_DIR, repoint symlinks in $LINK_DIR, remove $PREFIX after tests pass" ;;
  esac
  say "  Backup  : $BACKUP_BASE/$STAMP"
  local procs; procs=$(pgrep -a -x node 2>/dev/null || true)
  if [[ -n $procs ]]; then
    warn "Running node processes keep using the OLD binary until restarted:"
    printf '%s\n' "$procs" | sed 's/^/         /' | tee -a "${LOG:-/dev/null}"
  fi
}

# ------------------------------------------------------------------ backup ---
# Keep the old packages' .rpm files in the backup so a rollback can reinstall
# them properly. Looks next to the tarball, in the dnf/yum cache and $OLD_RPM_DIR.
save_old_rpms() {
  local nevra f found=0 missing=() d
  local -a dirs=("$(dirname "$TARBALL")" /var/cache/dnf /var/cache/yum)
  [[ -n ${OLD_RPM_DIR:-} ]] && dirs=("$OLD_RPM_DIR" "${dirs[@]}")
  mkdir -p "$BACKUP_DIR/rpms"
  while IFS= read -r nevra; do
    [[ -z $nevra || $nevra == *"not installed"* ]] && continue
    f=""
    for d in "${dirs[@]}"; do
      [[ -d $d ]] || continue
      f=$(find "$d" -name "$nevra.rpm" -type f 2>/dev/null | head -1)
      [[ -n $f ]] && break
    done
    if [[ -n $f ]]; then cp -p "$f" "$BACKUP_DIR/rpms/"; found=$((found+1)); else missing+=("$nevra"); fi
  done <"$BACKUP_DIR/rpms.txt"
  if (( ${#missing[@]} == 0 )); then
    ok "Saved all $found old .rpm files - rollback will reinstall the old packages exactly"
  else
    warn "Old .rpm files not found for: ${missing[*]}"
    warn "Rollback will still restore the old files, but rpm will not list those packages."
    say  "       For a full rollback, put those .rpm files in $(dirname "$TARBALL") (or set OLD_RPM_DIR) and re-run."
    if (( found == 0 )); then rmdir "$BACKUP_DIR/rpms" 2>/dev/null || true; fi
  fi
}

backup_existing() {
  info "Backing up the current installation"
  BACKUP_DIR="$BACKUP_BASE/$STAMP"
  mkdir -p "$BACKUP_DIR"; chmod 700 "$BACKUP_DIR"
  local list="$BACKUP_DIR/files.list" rel p
  : >"$list"
  case $MODE in
    rpm|rpm-replace)
      rpm -q "${RPM_PKGS[@]}" >"$BACKUP_DIR/rpms.txt" 2>/dev/null || true
      save_old_rpms
      rpm -ql "${RPM_PKGS[@]}" 2>/dev/null | while IFS= read -r p; do
        [[ -e $p || -L $p ]] && [[ ! -d $p || -L $p ]] && printf '%s\n' "${p#/}"
      done >>"$list" || true
      ;;&
    rpm-replace|inplace)
      for rel in bin/node bin/npm bin/npx bin/corepack lib/node_modules/npm lib/node_modules/corepack \
                 include/node share/doc/node share/man/man1/node.1 share/systemtap/tapset/node.stp etc/npmrc; do
        p="$PREFIX/$rel"; [[ -e $p || -L $p ]] && printf '%s\n' "${p#/}" >>"$list"
      done
      ;;
    versioned)
      for p in "$LINK_DIR"/*; do
        [[ -L $p ]] && [[ $(readlink -f "$p") == "$PREFIX"/* ]] && printf '%s\n' "${p#/}" >>"$list"
      done
      ;;
  esac
  if [[ -s $list ]]; then
    tar -czpf "$BACKUP_DIR/files.tgz" -C / --no-recursion -T <(
      # include directories' contents explicitly for inplace dirs
      while IFS= read -r rel; do
        if [[ -d /$rel && ! -L /$rel ]]; then (cd / && find "$rel"); else printf '%s\n' "$rel"; fi
      done <"$list")
    ok "Saved $(wc -l <"$list") item(s) to $BACKUP_DIR/files.tgz"
  else
    ok "Nothing to back up (fresh install)"
  fi
  [[ -n $OLD_NPM_PREFIX ]] && list_globals "$OLD_NPM_PREFIX" >"$BACKUP_DIR/npm-globals.txt"
  {
    printf 'MODE=%q\nPREFIX=%q\nOLD_VER=%q\nNEW_VER=%q\nLINK_DIR=%q\nNEW_DIR=%q\nOLD_NODE=%q\n' \
      "$MODE" "$PREFIX" "$OLD_VER" "$NEW_VER" "$LINK_DIR" "$NEW_DIR" "$OLD_NODE"
  } >"$BACKUP_DIR/meta.env"
  [[ -s $BACKUP_DIR/npm-globals.txt ]] && ok "Recorded $(wc -l <"$BACKUP_DIR/npm-globals.txt") global npm package(s)"
  return 0
}

# ----------------------------------------------------------------- install ---
copy_stage_into() { # copy_stage_into PREFIX
  local dst=$1 d
  mkdir -p "$dst"
  rm -rf "$dst/lib/node_modules/npm" "$dst/lib/node_modules/corepack" "$dst/include/node"
  for d in bin include lib share etc; do
    [[ -d $STAGE/$d ]] && cp -a "$STAGE/$d" "$dst/"
  done
  fix_selinux "$dst/bin" "$dst/lib/node_modules" "$dst/include/node" "$dst/share" 2>/dev/null
  return 0
}

install_inplace() {
  info "Installing v$NEW_VER into $PREFIX"
  INSTALL_STARTED=1
  copy_stage_into "$PREFIX"
  ok "Files installed"
}

install_rpm_replace() {
  info "Removing old RPMs and installing v$NEW_VER into $PREFIX"
  INSTALL_STARTED=1
  rpm -e --nodeps "${RPM_PKGS[@]}"
  ok "Removed: ${RPM_PKGS[*]}"
  copy_stage_into "$PREFIX"
  ok "Files installed"
}

install_versioned() {
  info "Installing v$NEW_VER into $NEW_DIR"
  if [[ -e $NEW_DIR && $NEW_DIR != "$PREFIX" ]]; then
    ask "$NEW_DIR already exists. Replace it?" y || die "Aborted."
    rm -rf "$NEW_DIR"
  fi
  INSTALL_STARTED=1
  cp -a "$STAGE" "$NEW_DIR"
  # migrate global packages that lived inside the old versioned dir
  local e n=0
  for e in "$PREFIX"/lib/node_modules/*; do
    [[ -e $e ]] || continue
    case ${e##*/} in npm|corepack) continue ;; esac
    [[ -e $NEW_DIR/lib/node_modules/${e##*/} ]] || { cp -a "$e" "$NEW_DIR/lib/node_modules/"; n=$((n+1)); }
  done
  for e in "$PREFIX"/bin/*; do
    case ${e##*/} in node|npm|npx|corepack) continue ;; esac
    [[ -e $NEW_DIR/bin/${e##*/} || -L $NEW_DIR/bin/${e##*/} ]] || cp -a "$e" "$NEW_DIR/bin/"
  done
  (( n )) && ok "Migrated $n global npm package(s) from the old directory"
  fix_selinux "$NEW_DIR"
  # repoint every symlink in LINK_DIR that pointed into the old dir
  local l tgt rel
  for l in "$LINK_DIR"/*; do
    [[ -L $l ]] || continue
    tgt=$(readlink "$l") || continue
    [[ $tgt == /* ]] || tgt=$(readlink -f "$l")
    [[ $tgt == "$PREFIX"/* ]] || continue
    rel=${tgt#"$PREFIX"/}
    if [[ -e $NEW_DIR/$rel ]]; then ln -sfn "$NEW_DIR/$rel" "$l"; ok "Relinked $l -> $NEW_DIR/$rel"
    else warn "No $rel in new version; left $l unchanged"; fi
  done
}

install_rpm() {
  local out attempt nevra name
  local -a more=() needed=()
  for attempt in 1 2 3 4; do
    build_rpm
    info "Dry run: rpm -Uvh --test $(basename "$BUILT_RPM")"
    if out=$(rpm -Uvh --test "$BUILT_RPM" 2>&1); then
      ok "No conflicts - transaction test passed"
      break
    fi
    say "$out" | sed 's/^/       /'
    (( attempt < 4 )) || die "Still conflicting after several attempts - nothing was changed. See $LOG"
    more=(); needed=()
    # file conflicts:  "... conflicts with file from package NEVRA"
    while IFS= read -r nevra; do
      name=$(rpm -q --qf '%{NAME}\n' "$nevra" 2>/dev/null | head -1)
      [[ -n $name && " ${RPM_PKGS[*]-} " != *" $name "* ]] && more+=("$name")
    done < <(printf '%s\n' "$out" | grep -oP 'conflicts with (file from package )?\K[^ ]+' | sort -u || true)
    # dependency problems: "X is needed by (installed) NEVRA"
    while IFS= read -r nevra; do
      name=$(rpm -q --qf '%{NAME}\n' "$nevra" 2>/dev/null | head -1)
      [[ -n $name && " ${RPM_PKGS[*]-} " != *" $name "* ]] && needed+=("$name")
    done < <(printf '%s\n' "$out" | grep -oP 'is needed by \(installed\) \K[^ ]+' | sort -u || true)
    if (( ${#more[@]} == 0 && ${#needed[@]} == 0 )); then
      die "rpm reported a problem the script cannot resolve automatically (shown above). Nothing was changed."
    fi
    (( ${#more[@]} ))   && warn "Packages owning conflicting files: ${more[*]}"
    if (( ${#needed[@]} )); then
      warn "Installed packages that depend on the old Node.js packages: ${needed[*]}"
      warn "Replacing them UNINSTALLS them. Only do this if they are Node.js add-ons (e.g. nodejs-nodemon),"
      warn "not applications you still need - otherwise choose Abort and check: rpm -qi <package>"
    fi
    if (( ${#needed[@]} )); then
      # removing dependents is never the default (also with --yes)
      choose "How do you want to resolve this?" \
        "Abort - change nothing (default)" \
        "Rebuild the RPM so it also replaces/UNINSTALLS: ${more[*]-} ${needed[*]-}"
      (( CHOICE == 2 )) || die "Aborted - nothing was changed. ${needed[*]} need(s) the old Node.js version; check with: rpm -qR <package>"
    else
      choose "How do you want to resolve this?" \
        "Rebuild the RPM so it also replaces: ${more[*]-}" \
        "Abort - change nothing"
      (( CHOICE == 1 )) || die "Aborted - nothing was changed."
    fi
    RPM_PKGS+=("${more[@]}" "${needed[@]}")
    mapfile -t RPM_PKGS < <(printf '%s\n' "${RPM_PKGS[@]}" | sort -u)
    # refresh the backup so it also holds the newly added packages' files
    backup_existing >/dev/null
  done
  cp -p "$BUILT_RPM" "$BACKUP_DIR/"; cp -p "$BUILT_RPM" /tmp/
  ok "Saved a copy of $(basename "$BUILT_RPM") in /tmp for other servers"

  info "Installing $(basename "$BUILT_RPM")"
  if ! out=$(rpm -Uvh "$BUILT_RPM" 2>&1); then
    say "$out"
    die "rpm -Uvh failed (the transaction was not applied; your old Node is untouched)."
  fi
  INSTALL_STARTED=1
  say "$out" | sed 's/^/       /'
  ok "Installed: $(rpm -q nodejs-upstream)"
  if command -v dnf >/dev/null 2>&1; then
    dnf -q -y module reset nodejs --disablerepo='*' >/dev/null 2>&1 \
      && ok "dnf module state for nodejs reset" || true
  fi
}

# Capabilities the replacement RPM provides, so packages that depend on the old
# nodejs/npm RPMs (nodemon, apps, native add-ons) stay satisfied.
rpm_provides() {
  local isa npmver abi v8abi newmaj name line
  isa=$(uname -m | tr '_' '-')
  newmaj=${NEW_VER%%.*}
  npmver=$(sed -n 's/^ *"version": *"\([^"]*\)".*/\1/p' "$STAGE/lib/node_modules/npm/package.json" | head -1)
  abi=$("$STAGE/bin/node" -p 'process.versions.modules' 2>/dev/null || true)
  v8abi=$("$STAGE/bin/node" -p 'process.versions.v8.split(".").slice(0,2).join(".")' 2>/dev/null || true)
  {
    for name in nodejs nodejs-libs nodejs-devel nodejs-full-i18n nodejs-docs; do
      printf 'Provides: %s = 1:%s\n' "$name" "$NEW_VER"
      [[ $name == nodejs-docs ]] || printf 'Provides: %s(%s) = 1:%s\n' "$name" "$isa" "$NEW_VER"
    done
    [[ -n $npmver ]] && printf 'Provides: npm = 1:%s\nProvides: npm(npm) = %s\n' "$npmver" "$npmver" || printf 'Provides: npm\n'
    printf 'Provides: nodejs(engine) = %s\n' "$NEW_VER"
    if [[ -n $abi ]]; then
      printf 'Provides: nodejs(abi) = %s\nProvides: nodejs(abi%s) = %s\n' "$abi" "$newmaj" "$abi"
    fi
    [[ -n $v8abi ]] && printf 'Provides: nodejs(v8-abi) = %s\nProvides: nodejs(v8-abi%s) = %s\n' "$v8abi" "$v8abi" "$v8abi"
    # anything else the old packages provided (except shared libraries, config()
    # and bundled() markers, and ABIs of a different Node major version)
    if (( ${#RPM_PKGS[@]} )); then
      rpm -q --provides "${RPM_PKGS[@]}" 2>/dev/null | while IFS= read -r line; do
        name=${line%% *}
        case $name in
          *.so*|config\(*|bundled\(*|nodejs|nodejs-libs|nodejs-devel|nodejs-full-i18n|nodejs-docs|npm|npm\(npm\)) continue ;;
          nodejs\(engine\)|nodejs\(abi\)|nodejs\(abi*\)|nodejs\(v8-abi*\)|*\(${isa}\)) continue ;;
        esac
        [[ " ${RPM_PKGS[*]} " == *" $name "* ]] && continue
        printf 'Provides: %s\n' "$name"
      done
    fi
  } | sort -u
}

build_rpm() {
  info "Building RPM nodejs-upstream-$NEW_VER"
  local top="$WORK/rpmbuild" spec filelist f p
  rm -rf "${WORK:?}/rpmbuild"
  mkdir -p "$top"/{SPECS,SOURCES,BUILD,BUILDROOT,RPMS,SRPMS}
  spec="$top/SPECS/nodejs-upstream.spec"; filelist="$top/files.list"
  {
    for f in "$STAGE"/bin/*; do printf '%s/bin/%s\n' "$PREFIX" "${f##*/}"; done
    [[ -d $STAGE/include/node ]] && printf '%s/include/node\n' "$PREFIX"
    printf '%%dir %s/lib/node_modules\n' "$PREFIX"
    for f in "$STAGE"/lib/node_modules/*; do printf '%s/lib/node_modules/%s\n' "$PREFIX" "${f##*/}"; done
    [[ -d $STAGE/share/doc/node ]] && printf '%s/share/doc/node\n' "$PREFIX"
    (cd "$STAGE" && find share -type f ! -path 'share/doc/node/*') | while IFS= read -r p; do printf '%s/%s\n' "$PREFIX" "$p"; done
    [[ -f $STAGE/etc/npmrc ]] && printf '%%config(noreplace) %s/etc/npmrc\n' "$PREFIX"
  } >"$filelist"

  local obs="" prov
  prov=$(rpm_provides)
  for p in "${RPM_PKGS[@]}"; do obs+="Obsoletes:      $p"$'\n'; done

  cat >"$spec" <<SPEC
%global debug_package %{nil}
%global __os_install_post %{nil}
%global __arch_install_post %{nil}
%global _build_id_links none
%global _missing_build_ids_terminate_build 0

Name:           nodejs-upstream
Version:        $NEW_VER
Release:        1%{?dist}
Summary:        Node.js $NEW_VER (official nodejs.org binary)
License:        MIT
URL:            https://nodejs.org
AutoReqProv:    no
Requires:       glibc
$prov
$obs
%description
Official Node.js $NEW_VER Linux binary from nodejs.org, packaged as an RPM
by node-upgrade.sh. Replaces the distribution nodejs/npm packages.

%install
mkdir -p %{buildroot}$PREFIX
for d in bin include lib share etc; do
  if [ -d "$STAGE/\$d" ]; then cp -a "$STAGE/\$d" %{buildroot}$PREFIX/; fi
done

%files -f $filelist
SPEC

  rpmbuild --quiet --define "_topdir $top" -bb "$spec" >>"${LOG:-/dev/null}" 2>&1 \
    || die "rpmbuild failed - see $LOG (nothing was changed)"
  BUILT_RPM=$(find "$top/RPMS" -name 'nodejs-upstream-*.rpm' | head -1)
  [[ -n $BUILT_RPM ]] || die "rpmbuild produced no RPM"
  ok "Built $(basename "$BUILT_RPM") (replaces: ${RPM_PKGS[*]})"
}

# --------------------------------------------------------------- post-test ---
post_test() {
  info "Post-install self-test"
  hash -r
  local bin fails=0
  case $MODE in versioned) bin=$LINK_DIR ;; *) bin=$PREFIX/bin ;; esac
  run_selftest "$bin/node" "$(npm_cli_for "$bin/node")" "$NEW_VER" || fails=$?

  local onpath; onpath=$(command -v node 2>/dev/null || true)
  if [[ -n $onpath && $(readlink -f "$onpath") != "$(readlink -f "$bin/node")" ]]; then
    warn "'node' on root's PATH is $onpath, not $bin/node - another Node shadows the new one"
  else
    ok "'node' on PATH resolves to the new binary"
  fi

  if [[ -s ${BACKUP_DIR:-/x}/npm-globals.txt ]]; then
    local newpfx missing
    newpfx=$("$bin/node" "$(npm_cli_for "$bin/node")" prefix -g 2>/dev/null || true)
    missing=$(comm -23 "$BACKUP_DIR/npm-globals.txt" <(list_globals "$newpfx") || true)
    if [[ -z $missing ]]; then ok "All global npm packages still present ($newpfx)"
    else warn "Global npm packages not visible to the new npm: $(echo $missing)"; fi
  fi

  if [[ $MODE == rpm ]]; then
    local vout; vout=$(rpm -V nodejs-upstream 2>&1 || true)
    if [[ -z $vout ]]; then ok "rpm -V nodejs-upstream: all files verified"
    else warn "rpm -V reported differences:"; say "$vout"; fi
    local left; left=$(rpm -q "${RPM_PKGS[@]}" 2>/dev/null | grep -v 'not installed' || true)
    [[ -z $left ]] && ok "Old RPMs removed - only one Node.js installed" || warn "Still installed: $left"
  fi
  return "$fails"
}

# ---------------------------------------------------------------- rollback ---
do_rollback() {
  local dir=$1
  [[ -f $dir/meta.env ]] || die "No meta.env in $dir - not a node-upgrade backup"
  # shellcheck disable=SC1091
  source "$dir/meta.env"
  info "Rolling back to v$OLD_VER ($MODE install)"
  # Best case: reinstall the original RPMs, which also restores the rpm database
  if [[ $MODE == rpm* && -d $dir/rpms ]] && [[ $(find "$dir/rpms" -name '*.rpm' | wc -l) -eq $(grep -vc 'not installed' "$dir/rpms.txt") ]]; then
    local -a old=("$dir"/rpms/*.rpm)
    [[ $MODE == rpm ]] && { rpm -e --nodeps nodejs-upstream 2>/dev/null && ok "Removed nodejs-upstream" || true; }
    if [[ $MODE == rpm-replace ]]; then
      rm -rf "$PREFIX/lib/node_modules/npm" "$PREFIX/lib/node_modules/corepack" "$PREFIX/include/node"
    fi
    if rpm -Uvh --oldpackage --replacepkgs --replacefiles "${old[@]}" >>"${LOG:-/dev/null}" 2>&1; then
      ok "Reinstalled the original packages: $(tr '\n' ' ' <"$dir/rpms.txt")"
      hash -r
      local nb="$PREFIX/bin/node"
      [[ -x $nb ]] && ok "$nb -v now reports: $("$nb" -v 2>&1)"
      return 0
    fi
    warn "Reinstalling the original RPMs failed (see $LOG); restoring files from the backup instead"
  fi
  case $MODE in
    rpm)
      rpm -e --nodeps nodejs-upstream 2>/dev/null && ok "Removed nodejs-upstream" || true ;;
    rpm-replace|inplace)
      rm -rf "$PREFIX/lib/node_modules/npm" "$PREFIX/lib/node_modules/corepack" "$PREFIX/include/node"
      if [[ $OLD_VER == none ]]; then
        rm -f "$PREFIX"/bin/{node,npm,npx,corepack}
        rm -rf "$PREFIX/share/doc/node"
        ok "Removed fresh install from $PREFIX"
      fi ;;
  esac
  if [[ -f $dir/old-dir.tgz ]]; then
    tar -xzpf "$dir/old-dir.tgz" -C /
    ok "Restored old directory $PREFIX"
  fi
  if [[ -f $dir/files.tgz ]]; then
    tar -xzpf "$dir/files.tgz" -C /
    ok "Restored files from $dir/files.tgz"
  fi
  case $MODE in
    versioned*)
      if [[ -n $NEW_DIR && -d $NEW_DIR && $NEW_DIR != "$PREFIX" ]] && ask "Delete $NEW_DIR?" y; then
        rm -rf "$NEW_DIR"; ok "Removed $NEW_DIR"
      fi ;;
    rpm|rpm-replace)
      warn "Old files are back, but the rpm database no longer lists the old packages."
      [[ -f $dir/rpms.txt ]] && say "       Reinstall them from RPM files when convenient: $(tr '\n' ' ' <"$dir/rpms.txt")" ;;
  esac
  fix_selinux "$PREFIX/bin" "$PREFIX/lib/node_modules" 2>/dev/null
  hash -r
  local nb="$PREFIX/bin/node" v
  [[ $MODE == versioned* && -n $LINK_DIR ]] && nb="$LINK_DIR/node"
  if [[ -x $nb ]]; then v=$("$nb" -v 2>&1 || echo "fails to run"); ok "$nb -v now reports: $v"
  else warn "$nb not present after rollback"; fi
}

finish() {
  if [[ $MODE == versioned && -d $PREFIX && $PREFIX != "$NEW_DIR" ]]; then
    if ask "Remove the old version directory $PREFIX (only one Node will remain)?" y; then
      tar -czpf "$BACKUP_DIR/old-dir.tgz" -C / "${PREFIX#/}"
      ok "Archived $PREFIX to $BACKUP_DIR/old-dir.tgz (for rollback)"
      rm -rf "$PREFIX"; ok "Removed $PREFIX"
      sed -i 's/^MODE=.*/MODE=versioned-old-removed/' "$BACKUP_DIR/meta.env"
    fi
  fi
  info "Done: Node.js v$OLD_VER -> v$NEW_VER"
  say "  Backup  : $BACKUP_DIR"
  say "  Log     : $LOG"
  say "  Undo    : sudo $0 --rollback $BACKUP_DIR"
  [[ -n $BUILT_RPM ]] && say "  RPM     : /tmp/$(basename "$BUILT_RPM")  (reuse on other servers: rpm -Uvh)"
  say "  Next    : restart services that run node; run 'npm rebuild' in apps with native modules."
}

# -------------------------------------------------------------------- main ---
while (( $# )); do
  case $1 in
    -t|--tarball)  TARBALL=${2:?missing file}; shift 2 ;;
    -d|--dir)      SEARCH_DIR=${2:?missing dir}; shift 2 ;;
    -p|--node)     NODE_ARG=${2:?missing path}; shift 2 ;;
    -y|--yes)      ASSUME_YES=1; shift ;;
    -n|--dry-run)  DRY_RUN=1; shift ;;
    -c|--check)    CHECK_ONLY=1; shift ;;
    -r|--rollback) ROLLBACK_DIR=${2:?missing backup dir}; shift 2 ;;
    -h|--help)     usage; exit 0 ;;
    *)             die "Unknown option: $1 (see --help)" ;;
  esac
done

if (( CHECK_ONLY )); then
  WORK=$(mktemp -d /tmp/node-upgrade.XXXXXX)
  n=${NODE_ARG:-$(command -v node || true)}
  [[ -n $n ]] || die "No node found on PATH (use -p /path/to/node)"
  info "Self-test of $n"
  fails=0; run_selftest "$n" "$(npm_cli_for "$n")" || fails=$?
  (( fails )) && { bad "$fails test(s) failed"; exit 1; }
  ok "All tests passed"; exit 0
fi

(( EUID == 0 )) || die "Run as root: sudo $0"
mkdir -p /var/log
LOG="/var/log/node-upgrade-$STAMP.log"; : >"$LOG"; chmod 600 "$LOG"

if [[ -n $ROLLBACK_DIR ]]; then
  do_rollback "$ROLLBACK_DIR"; exit 0
fi

say "${B}Node.js offline upgrade - $(date)${N}"
preflight
pick_tarball
verify_checksum
stage_and_pretest
detect_existing
check_conflicts
prepare_npmrc
show_plan

if (( DRY_RUN )); then
  info "Dry run complete - nothing was changed."
  exit 0
fi
ask "Proceed with the upgrade?" y || die "Aborted - nothing was changed."

backup_existing
case $MODE in
  rpm)         install_rpm ;;
  rpm-replace) install_rpm_replace ;;
  inplace)     install_inplace ;;
  versioned)   install_versioned ;;
esac

fails=0; post_test || fails=$?
if (( fails )); then
  bad "$fails post-install test(s) failed."
  if ask "Roll back to v$OLD_VER?" y; then
    do_rollback "$BACKUP_DIR"
    die "Upgrade rolled back."
  fi
  warn "Keeping v$NEW_VER despite failures."
fi
finish
