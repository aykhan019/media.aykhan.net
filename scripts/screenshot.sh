#!/usr/bin/env bash
# =============================================================================
# screenshot_upload.sh v1.1.0 — take a screenshot (macOS/Linux) and upload it
# to a free image host. Prints ONLY the final image URL to stdout.
# Auto-installs a screenshot tool (and curl) if missing.
#
# Local usage:
#   ./screenshot_upload.sh                 # screenshot -> upload -> print URL
#   ./screenshot_upload.sh /path/img.png   # skip capture, upload existing file
#   ./screenshot_upload.sh -o shot.png     # keep the captured file at shot.png
#
# Remote usage (hosted at media.aykhan.net):
#   curl -sL https://media.aykhan.net/screenshot_upload.sh | bash
#   curl -sL https://media.aykhan.net/screenshot_upload.sh | bash -s -- -o shot.png
#
# Env overrides:
#   SCREENSHOT_UPLOADER=uguu   # force one uploader (img402|litterbox|uguu|quax|tempsh)
#   LITTERBOX_TIME=24h         # litterbox retention: 1h|12h|24h|72h (default 24h)
#   NO_INSTALL=1               # never install packages, fail instead
#
# Upload chain (all verified working 2026-08-06, no API key needed):
#   1. img402.dev    - direct image URL, <=1MB permanent / <=10MB 30 days
#   2. litterbox     - direct image URL, temporary (LITTERBOX_TIME)
#   3. uguu.se       - direct image URL, ~48h retention
#   4. qu.ax         - browser viewer page, ~30 days
#   5. temp.sh       - browser viewer page, ~3 days
# =============================================================================
set -u

VERSION="1.1.0"
LITTERBOX_TIME="${LITTERBOX_TIME:-24h}"
CURL_TIMEOUT=60
UA="screenshot-upload/$VERSION"

# ---- logging: everything goes to STDERR so stdout stays a clean URL --------
if [ -t 2 ]; then
  C_INFO='\033[0;36m'; C_OK='\033[0;32m'; C_WARN='\033[0;33m'; C_ERR='\033[0;31m'; C_OFF='\033[0m'
else
  C_INFO=''; C_OK=''; C_WARN=''; C_ERR=''; C_OFF=''
fi
info() { printf '%b[*]%b %s\n' "$C_INFO" "$C_OFF" "$*" >&2; }
ok()   { printf '%b[+]%b %s\n' "$C_OK"   "$C_OFF" "$*" >&2; }
warn() { printf '%b[!]%b %s\n' "$C_WARN" "$C_OFF" "$*" >&2; }
err()  { printf '%b[-]%b %s\n' "$C_ERR"  "$C_OFF" "$*" >&2; }

# =============================================================================
# 1. PRIVILEGES + PACKAGE MANAGER (for auto-install)
# =============================================================================
SUDO=""
init_sudo() {
  if [ "$(id -u)" -eq 0 ]; then
    SUDO=""
  elif command -v sudo >/dev/null 2>&1; then
    if sudo -n true 2>/dev/null; then
      SUDO="sudo -n"          # passwordless sudo
    elif [ -e /dev/tty ]; then
      SUDO="sudo"             # interactive: sudo prompts on /dev/tty even when piped
    else
      SUDO=""; return 1       # no tty, no passwordless sudo -> cannot install
    fi
  else
    return 1                  # no sudo at all
  fi
  return 0
}

PM=""
detect_pm() {
  local pm
  for pm in apt-get dnf yum pacman zypper apk brew; do
    if command -v "$pm" >/dev/null 2>&1; then PM="$pm"; return 0; fi
  done
  return 1
}

PM_UPDATED=0
# pm_install <pkg> [pkg2 ...] — tries candidates in order until one installs
pm_install() {
  [ "${NO_INSTALL:-0}" = "1" ] && return 1
  detect_pm || { err "No known package manager (apt/dnf/yum/pacman/zypper/apk/brew)"; return 1; }
  init_sudo || { err "Need root or sudo to install packages"; return 1; }
  local pkg
  for pkg in "$@"; do
    info "Installing '$pkg' via $PM ..."
    case "$PM" in
      apt-get)
        if [ "$PM_UPDATED" = "0" ]; then $SUDO apt-get update -qq >&2 2>&1; PM_UPDATED=1; fi
        $SUDO DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg" >&2 2>&1 && { ok "Installed: $pkg"; return 0; } ;;
      dnf)    $SUDO dnf install -y "$pkg"                  >&2 2>&1 && { ok "Installed: $pkg"; return 0; } ;;
      yum)    $SUDO yum install -y "$pkg"                  >&2 2>&1 && { ok "Installed: $pkg"; return 0; } ;;
      pacman) $SUDO pacman -Sy --noconfirm --needed "$pkg" >&2 2>&1 && { ok "Installed: $pkg"; return 0; } ;;
      zypper) $SUDO zypper -n install "$pkg"               >&2 2>&1 && { ok "Installed: $pkg"; return 0; } ;;
      apk)    $SUDO apk add "$pkg"                         >&2 2>&1 && { ok "Installed: $pkg"; return 0; } ;;
      brew)   brew install "$pkg"                          >&2 2>&1 && { ok "Installed: $pkg"; return 0; } ;;
    esac
    warn "Could not install '$pkg'"
  done
  return 1
}

ensure_curl() {
  command -v curl >/dev/null 2>&1 && return 0
  warn "curl not found — attempting auto-install"
  pm_install curl || { err "curl is required. Install it manually (e.g. apt install curl)"; return 1; }
}

# =============================================================================
# 2. SCREENSHOT — pick a capture tool based on OS / display server
# =============================================================================
is_wayland() { [ "${XDG_SESSION_TYPE:-}" = "wayland" ] || [ -n "${WAYLAND_DISPLAY:-}" ]; }

find_shot_tool() {
  local t
  if is_wayland; then
    for t in grim gnome-screenshot spectacle; do
      command -v "$t" >/dev/null 2>&1 && { printf '%s' "$t"; return 0; }
    done
  else
    for t in maim scrot import gnome-screenshot spectacle; do
      command -v "$t" >/dev/null 2>&1 && { printf '%s' "$t"; return 0; }
    done
  fi
  return 1
}

install_screenshot_tool() {
  if is_wayland; then
    pm_install grim gnome-screenshot
  else
    pm_install scrot maim imagemagick gnome-screenshot
  fi
}

capture_with() {
  case "$1" in
    screencapture)     screencapture -x "$2" ;;
    grim)              grim "$2" ;;
    maim)              maim "$2" ;;
    scrot)             scrot "$2" ;;
    import)            import -window root "$2" ;;
    gnome-screenshot)  gnome-screenshot -f "$2" ;;
    spectacle)         spectacle -b -n -o "$2" ;;
    *)                 return 1 ;;
  esac
}

take_screenshot() {
  local out="$1" os tool
  os="$(uname -s)"

  case "$os" in
    Darwin)
      # macOS: screencapture + curl are built in, nothing to install
      command -v screencapture >/dev/null 2>&1 || { err "screencapture not found"; return 1; }
      info "OS: macOS — using screencapture"
      capture_with screencapture "$out"
      ;;

    Linux|*BSD*)
      # Running from a root shell / agent without session env? Target the user's X session.
      if ! is_wayland && [ -z "${DISPLAY:-}" ]; then
        export DISPLAY=:0
        info "DISPLAY was empty — defaulting to :0"
      fi
      if [ "$(id -u)" -eq 0 ] && [ -z "${XAUTHORITY:-}" ]; then
        local xa
        for xa in /run/user/*/gdm/Xauthority /run/user/*/.Xauthority /home/*/.Xauthority; do
          if [ -f "$xa" ]; then export XAUTHORITY="$xa"; info "Using XAUTHORITY=$xa"; break; fi
        done
      fi

      if is_wayland; then info "OS: $os (Wayland)"; else info "OS: $os (X11)"; fi

      tool=$(find_shot_tool) || tool=""
      if [ -z "$tool" ]; then
        warn "No screenshot tool found — attempting auto-install"
        install_screenshot_tool && tool=$(find_shot_tool)
      fi
      if [ -z "$tool" ]; then
        err "No screenshot tool available and auto-install failed."
        err "Manual install: apt install scrot (X11)  |  apt install grim (Wayland)  |  brew install --cask shottr (macOS not needed)"
        return 1
      fi
      info "Using: $tool"
      capture_with "$tool" "$out"
      ;;

    MINGW*|MSYS*|CYGWIN*)
      err "Windows: use PowerShell capture instead (not covered by this script)"
      return 1
      ;;

    *)
      err "Unsupported OS: $os"
      return 1
      ;;
  esac

  [ -s "$out" ] || { err "Capture ran but produced no file (no active display/session?)"; return 1; }
  return 0
}

# =============================================================================
# 3. UPLOADERS — each: $1=file path, prints URL to stdout, 0=success / 1=fail
# =============================================================================

# pull "url":"..." out of a JSON blob without jq
json_url() {
  printf '%s' "$1" \
    | sed -n 's/.*"url"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
    | sed 's/\\\//\//g'
}

valid_url() { case "$1" in http://*|https://*) return 0 ;; *) return 1 ;; esac }

# --- 1) img402.dev (primary) — free, no key; <=1MB permanent, <=10MB 30d ----
upload_img402() {
  local r url
  r=$(curl -sf -m "$CURL_TIMEOUT" -A "$UA" -X POST "https://img402.dev/api/free" -F "image=@$1" 2>/dev/null) || return 1
  url=$(json_url "$r")
  valid_url "$url" || return 1
  printf '%s\n' "$url"
}

# --- 2) litterbox.catbox.moe — temp host (1h-72h), plain-text URL ------------
upload_litterbox() {
  local url
  url=$(curl -sf -m "$CURL_TIMEOUT" -A "$UA" \
        -F "reqtype=fileupload" -F "time=$LITTERBOX_TIME" \
        -F "fileToUpload=@$1" \
        "https://litterbox.catbox.moe/resources/internals/api.php" 2>/dev/null) || return 1
  url=$(printf '%s' "$url" | tr -d '[:space:]')
  valid_url "$url" || return 1
  printf '%s\n' "$url"
}

# --- 3) uguu.se — ~48h retention, JSON ---------------------------------------
upload_uguu() {
  local r url
  r=$(curl -sf -m "$CURL_TIMEOUT" -A "$UA" \
      -F "files[]=@$1" \
      "https://uguu.se/upload.php?output=json" 2>/dev/null) || return 1
  url=$(json_url "$r")
  valid_url "$url" || return 1
  printf '%s\n' "$url"
}

# --- 4) qu.ax — ~30d retention, browser viewer page, JSON ---------------------
upload_quax() {
  local r url
  r=$(curl -sf -m "$CURL_TIMEOUT" -A "$UA" \
      -F "files[]=@$1" \
      "https://qu.ax/upload.php" 2>/dev/null) || return 1
  url=$(json_url "$r")
  valid_url "$url" || return 1
  printf '%s\n' "$url"
}

# --- 5) temp.sh — ~3d retention, browser viewer page, plain-text URL ----------
upload_tempsh() {
  local url
  url=$(curl -sf -m "$CURL_TIMEOUT" -A "$UA" \
        -F "file=@$1" \
        "https://temp.sh/upload" 2>/dev/null) || return 1
  url=$(printf '%s' "$url" | tr -d '[:space:]')
  valid_url "$url" || return 1
  printf '%s\n' "$url"
}

UPLOADERS="img402 litterbox uguu quax tempsh"

upload_with_fallback() {
  local file="$1" name url chain
  chain="${SCREENSHOT_UPLOADER:-$UPLOADERS}"
  for name in $chain; do
    info "Trying uploader: $name"
    url=$(upload_"$name" "$file")
    if [ $? -eq 0 ] && valid_url "$url"; then
      ok "Uploaded via $name"
      printf '%s\n' "$url"   # the ONLY thing on stdout
      return 0
    fi
    warn "$name failed — falling back"
  done
  err "All uploaders failed"
  return 1
}

# =============================================================================
# 4. MAIN — wrapped so a truncated `curl | bash` download can't half-execute
# =============================================================================
main() {
  local keep_file="" input_file="" shot size rc

  while [ $# -gt 0 ]; do
    case "$1" in
      -o|--output)  keep_file="$2"; shift 2 ;;
      -v|--version) printf 'screenshot_upload.sh v%s\n' "$VERSION" >&2; exit 0 ;;
      -h|--help)    sed -n '2,25p' "$0" >&2; exit 0 ;;
      *)            input_file="$1"; shift ;;
    esac
  done

  info "screenshot_upload.sh v$VERSION"

  ensure_curl || exit 1

  if [ -n "$input_file" ]; then
    [ -f "$input_file" ] || { err "File not found: $input_file"; exit 1; }
    shot="$input_file"
    info "Using existing file: $shot"
  else
    if [ -n "$keep_file" ]; then
      shot="$keep_file"
    else
      shot="$(mktemp /tmp/screenshot_XXXXXX.png)"
    fi
    take_screenshot "$shot" || { [ -z "$keep_file" ] && rm -f "$shot"; exit 1; }
  fi

  size=$(wc -c < "$shot" | tr -d ' ')
  ok "Screenshot ready: $shot ($size bytes)"

  upload_with_fallback "$shot"
  rc=$?

  [ -z "$keep_file" ] && [ -z "$input_file" ] && rm -f "$shot"
  exit $rc
}

main "$@"
