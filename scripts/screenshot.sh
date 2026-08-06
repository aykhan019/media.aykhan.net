#!/usr/bin/env bash
# =============================================================================
# screenshot_upload.sh v1.1.0 — take a screenshot (macOS/Linux) and upload it
# to a free image host. Prints ONLY the final image URL to stdout.
# Auto-installs a screenshot tool (and curl) if missing.
#
# Local usage:
#   ./screenshot_upload.sh
#   ./screenshot_upload.sh /path/img.png
#   ./screenshot_upload.sh -o shot.png
#
# Remote usage:
#   curl -sL https://media.aykhan.net/screenshot_upload.sh | bash
#   curl -sL https://media.aykhan.net/screenshot_upload.sh | bash -s -- -o shot.png
#
# Environment variables:
#   SCREENSHOT_UPLOADER=uguu
#   LITTERBOX_TIME=24h
#   NO_INSTALL=1
# =============================================================================
set -u

VERSION="1.1.0"
LITTERBOX_TIME="${LITTERBOX_TIME:-24h}"
CURL_TIMEOUT=60
UA="screenshot-upload/$VERSION"

# Logging goes to stderr so stdout contains only the final URL.
if [ -t 2 ]; then
  C_INFO='\033[0;36m'
  C_OK='\033[0;32m'
  C_WARN='\033[0;33m'
  C_ERR='\033[0;31m'
  C_OFF='\033[0m'
else
  C_INFO=''
  C_OK=''
  C_WARN=''
  C_ERR=''
  C_OFF=''
fi

info() { printf '%b[*]%b %s\n' "$C_INFO" "$C_OFF" "$*" >&2; }
ok()   { printf '%b[+]%b %s\n' "$C_OK" "$C_OFF" "$*" >&2; }
warn() { printf '%b[!]%b %s\n' "$C_WARN" "$C_OFF" "$*" >&2; }
err()  { printf '%b[-]%b %s\n' "$C_ERR" "$C_OFF" "$*" >&2; }

# =============================================================================
# Privileges and package manager
# =============================================================================

SUDO=""

init_sudo() {
  if [ "$(id -u)" -eq 0 ]; then
    SUDO=""
  elif command -v sudo >/dev/null 2>&1; then
    if sudo -n true 2>/dev/null; then
      SUDO="sudo -n"
    elif [ -e /dev/tty ]; then
      SUDO="sudo"
    else
      SUDO=""
      return 1
    fi
  else
    return 1
  fi

  return 0
}

PM=""

detect_pm() {
  local pm

  for pm in apt-get dnf yum pacman zypper apk brew; do
    if command -v "$pm" >/dev/null 2>&1; then
      PM="$pm"
      return 0
    fi
  done

  return 1
}

PM_UPDATED=0

pm_install() {
  [ "${NO_INSTALL:-0}" = "1" ] && return 1

  detect_pm || {
    err "No known package manager found"
    return 1
  }

  init_sudo || {
    err "Need root or sudo to install packages"
    return 1
  }

  local pkg

  for pkg in "$@"; do
    info "Installing '$pkg' via $PM ..."

    case "$PM" in
      apt-get)
        if [ "$PM_UPDATED" = "0" ]; then
          $SUDO apt-get update -qq >&2 2>&1
          PM_UPDATED=1
        fi

        $SUDO env DEBIAN_FRONTEND=noninteractive \
          apt-get install -y "$pkg" >&2 2>&1 &&
          {
            ok "Installed: $pkg"
            return 0
          }
        ;;

      dnf)
        $SUDO dnf install -y "$pkg" >&2 2>&1 &&
          {
            ok "Installed: $pkg"
            return 0
          }
        ;;

      yum)
        $SUDO yum install -y "$pkg" >&2 2>&1 &&
          {
            ok "Installed: $pkg"
            return 0
          }
        ;;

      pacman)
        $SUDO pacman -Sy --noconfirm --needed "$pkg" >&2 2>&1 &&
          {
            ok "Installed: $pkg"
            return 0
          }
        ;;

      zypper)
        $SUDO zypper -n install "$pkg" >&2 2>&1 &&
          {
            ok "Installed: $pkg"
            return 0
          }
        ;;

      apk)
        $SUDO apk add "$pkg" >&2 2>&1 &&
          {
            ok "Installed: $pkg"
            return 0
          }
        ;;

      brew)
        brew install "$pkg" >&2 2>&1 &&
          {
            ok "Installed: $pkg"
            return 0
          }
        ;;
    esac

    warn "Could not install '$pkg'"
  done

  return 1
}

ensure_curl() {
  command -v curl >/dev/null 2>&1 && return 0

  warn "curl not found — attempting auto-install"

  pm_install curl || {
    err "curl is required. Install it manually."
    return 1
  }
}

# =============================================================================
# Screenshot capture
# =============================================================================

is_wayland() {
  [ "${XDG_SESSION_TYPE:-}" = "wayland" ] ||
    [ -n "${WAYLAND_DISPLAY:-}" ]
}

find_shot_tool() {
  local tool

  if is_wayland; then
    for tool in grim gnome-screenshot spectacle; do
      if command -v "$tool" >/dev/null 2>&1; then
        printf '%s' "$tool"
        return 0
      fi
    done
  else
    for tool in maim scrot import gnome-screenshot spectacle; do
      if command -v "$tool" >/dev/null 2>&1; then
        printf '%s' "$tool"
        return 0
      fi
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
    screencapture)
      screencapture -x "$2"
      ;;
    grim)
      grim "$2"
      ;;
    maim)
      maim "$2"
      ;;
    scrot)
      scrot "$2"
      ;;
    import)
      import -window root "$2"
      ;;
    gnome-screenshot)
      gnome-screenshot -f "$2"
      ;;
    spectacle)
      spectacle -b -n -o "$2"
      ;;
    *)
      return 1
      ;;
  esac
}

take_screenshot() {
  local out="$1"
  local os
  local tool
  local xa

  os="$(uname -s)"

  case "$os" in
    Darwin)
      command -v screencapture >/dev/null 2>&1 || {
        err "screencapture not found"
        return 1
      }

      info "OS: macOS — using screencapture"
      capture_with screencapture "$out"
      ;;

    Linux|*BSD*)
      if ! is_wayland && [ -z "${DISPLAY:-}" ]; then
        export DISPLAY=:0
        info "DISPLAY was empty — defaulting to :0"
      fi

      if [ "$(id -u)" -eq 0 ] && [ -z "${XAUTHORITY:-}" ]; then
        for xa in \
          /run/user/*/gdm/Xauthority \
          /run/user/*/.Xauthority \
          /home/*/.Xauthority
        do
          if [ -f "$xa" ]; then
            export XAUTHORITY="$xa"
            info "Using XAUTHORITY=$xa"
            break
          fi
        done
      fi

      if is_wayland; then
        info "OS: $os (Wayland)"
      else
        info "OS: $os (X11)"
      fi

      tool="$(find_shot_tool)" || tool=""

      if [ -z "$tool" ]; then
        warn "No screenshot tool found — attempting auto-install"

        if install_screenshot_tool; then
          tool="$(find_shot_tool)" || tool=""
        fi
      fi

      if [ -z "$tool" ]; then
        err "No screenshot tool available and auto-install failed"
        return 1
      fi

      info "Using: $tool"
      capture_with "$tool" "$out"
      ;;

    MINGW*|MSYS*|CYGWIN*)
      err "Windows is not supported by this Bash script"
      return 1
      ;;

    *)
      err "Unsupported OS: $os"
      return 1
      ;;
  esac

  [ -s "$out" ] || {
    err "Capture produced no file"
    return 1
  }

  return 0
}

# =============================================================================
# Uploaders
# =============================================================================

json_url() {
  printf '%s' "$1" |
    sed -n 's/.*"url"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' |
    sed 's/\\\//\//g'
}

valid_url() {
  case "$1" in
    http://*|https://*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

upload_img402() {
  local response
  local url

  response="$(
    curl -sf \
      -m "$CURL_TIMEOUT" \
      -A "$UA" \
      -X POST \
      "https://img402.dev/api/free" \
      -F "image=@$1" \
      2>/dev/null
  )" || return 1

  url="$(json_url "$response")"
  valid_url "$url" || return 1
  printf '%s\n' "$url"
}

upload_litterbox() {
  local url

  url="$(
    curl -sf \
      -m "$CURL_TIMEOUT" \
      -A "$UA" \
      -F "reqtype=fileupload" \
      -F "time=$LITTERBOX_TIME" \
      -F "fileToUpload=@$1" \
      "https://litterbox.catbox.moe/resources/internals/api.php" \
      2>/dev/null
  )" || return 1

  url="$(printf '%s' "$url" | tr -d '[:space:]')"
  valid_url "$url" || return 1
  printf '%s\n' "$url"
}

upload_uguu() {
  local response
  local url

  response="$(
    curl -sf \
      -m "$CURL_TIMEOUT" \
      -A "$UA" \
      -F "files[]=@$1" \
      "https://uguu.se/upload.php?output=json" \
      2>/dev/null
  )" || return 1

  url="$(json_url "$response")"
  valid_url "$url" || return 1
  printf '%s\n' "$url"
}

upload_quax() {
  local response
  local url

  response="$(
    curl -sf \
      -m "$CURL_TIMEOUT" \
      -A "$UA" \
      -F "files[]=@$1" \
      "https://qu.ax/upload.php" \
      2>/dev/null
  )" || return 1

  url="$(json_url "$response")"
  valid_url "$url" || return 1
  printf '%s\n' "$url"
}

upload_tempsh() {
  local url

  url="$(
    curl -sf \
      -m "$CURL_TIMEOUT" \
      -A "$UA" \
      -F "file=@$1" \
      "https://temp.sh/upload" \
      2>/dev/null
  )" || return 1

  url="$(printf '%s' "$url" | tr -d '[:space:]')"
  valid_url "$url" || return 1
  printf '%s\n' "$url"
}

UPLOADERS="img402 litterbox uguu quax tempsh"

upload_with_fallback() {
  local file="$1"
  local name
  local url
  local chain

  chain="${SCREENSHOT_UPLOADER:-$UPLOADERS}"

  for name in $chain; do
    info "Trying uploader: $name"

    url="$(upload_"$name" "$file")"

    if [ $? -eq 0 ] && valid_url "$url"; then
      ok "Uploaded via $name"
      printf '%s\n' "$url"
      return 0
    fi

    warn "$name failed — falling back"
  done

  err "All uploaders failed"
  return 1
}

# =============================================================================
# Main
# =============================================================================

main() {
  local keep_file=""
  local input_file=""
  local shot
  local size
  local rc

  while [ "$#" -gt 0 ]; do
    case "$1" in
      -o|--output)
        if [ "$#" -lt 2 ]; then
          err "$1 requires a file path"
          exit 2
        fi

        keep_file="$2"
        shift 2
        ;;

      -v|--version)
        printf 'screenshot_upload.sh v%s\n' "$VERSION" >&2
        exit 0
        ;;

      -h|--help)
        sed -n '2,25p' "$0" >&2
        exit 0
        ;;

      *)
        input_file="$1"
        shift
        ;;
    esac
  done

  info "screenshot_upload.sh v$VERSION"

  ensure_curl || exit 1

  if [ -n "$input_file" ]; then
    [ -f "$input_file" ] || {
      err "File not found: $input_file"
      exit 1
    }

    shot="$input_file"
    info "Using existing file: $shot"
  else
    if [ -n "$keep_file" ]; then
      shot="$keep_file"
    else
      shot="$(mktemp /tmp/screenshot_XXXXXX.png)"
    fi

    if ! take_screenshot "$shot"; then
      if [ -z "$keep_file" ]; then
        rm -f "$shot"
      fi

      exit 1
    fi
  fi

  size="$(wc -c <"$shot" | tr -d ' ')"
  ok "Screenshot ready: $shot ($size bytes)"

  upload_with_fallback "$shot"
  rc=$?

  if [ -z "$keep_file" ] && [ -z "$input_file" ]; then
    rm -f "$shot"
  fi

  exit "$rc"
}

main "$@"
