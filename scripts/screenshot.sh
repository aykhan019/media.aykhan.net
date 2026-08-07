#!/usr/bin/env bash
# =============================================================================
# screenshot_upload_v2.sh - capture the visible display and upload it.
#
# Prints exactly one line on stdout: the final image URL.
# Every diagnostic goes to stderr.
#
# Usage:
#   screenshot_upload_v2.sh                    capture -> upload -> print URL
#   screenshot_upload_v2.sh -o shot.png        keep the capture at shot.png
#   screenshot_upload_v2.sh /path/img.png      upload an existing image
#   screenshot_upload_v2.sh -h                 help
#   screenshot_upload_v2.sh -v                 version
#
# Environment:
#   SCREENSHOT_UPLOADER  force one uploader: img402|litterbox|catbox|uguu|quax|tempsh
#   SCREENSHOT_DISPLAY   macOS/Windows display number, wlroots output name
#   LITTERBOX_TIME       1h|12h|24h|72h (default 24h)
#   MAX_BYTES            downscale a temporary copy above this size (default 9000000)
#   NO_INSTALL=1         never attempt any package installation
#
# Requires bash 3.2 or newer. No associative arrays, no eval.
# =============================================================================
set -u

VERSION="2.0.0"
UA="screenshot-upload-v2/$VERSION"
CURL_CONNECT=15
CURL_MAX=180

LITTERBOX_TIME="${LITTERBOX_TIME:-24h}"
MAX_BYTES="${MAX_BYTES:-9000000}"

# stdout is reserved for the URL alone. Park the real stdout on fd 3 and point
# fd 1 at stderr so that no subprocess can contaminate the contract, even one
# that ignores its own redirections. Command substitution is unaffected: it
# installs its own fd 1 in the child.
exec 3>&1
exec 1>&2

# ---- logging ----------------------------------------------------------------
if [ -t 2 ]; then
  C_INFO='\033[0;36m'; C_OK='\033[0;32m'; C_WARN='\033[0;33m'; C_ERR='\033[0;31m'; C_OFF='\033[0m'
else
  C_INFO=''; C_OK=''; C_WARN=''; C_ERR=''; C_OFF=''
fi
info() { printf '%b[*]%b %s\n' "$C_INFO" "$C_OFF" "$*" >&2; }
ok()   { printf '%b[+]%b %s\n' "$C_OK"   "$C_OFF" "$*" >&2; }
warn() { printf '%b[!]%b %s\n' "$C_WARN" "$C_OFF" "$*" >&2; }
die()  { printf '%b[-]%b %s\n' "$C_ERR"  "$C_OFF" "$*" >&2; }

emit_url() { printf '%s\n' "$1" >&3; }

# ---- scratch space ----------------------------------------------------------
# One directory holds every temporary file, so cleanup is a single quoted path
# and spaces in TMPDIR are harmless.
SCRATCH=""
WIN_SCRATCH=""

cleanup() {
  if [ -n "$SCRATCH" ] && [ -d "$SCRATCH" ]; then rm -rf "$SCRATCH"; fi
  if [ -n "$WIN_SCRATCH" ] && [ -d "$WIN_SCRATCH" ]; then rm -rf "$WIN_SCRATCH"; fi
  return 0
}
trap cleanup EXIT

make_scratch() {
  [ -n "$SCRATCH" ] && return 0
  SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/shotup2.XXXXXX") || return 1
  return 0
}

scratch_png() {
  # $1 = short basename stem
  printf '%s/%s.png' "$SCRATCH" "$1"
}

abspath() {
  case "$1" in
    /*) printf '%s' "$1" ;;
    *)  printf '%s/%s' "$PWD" "$1" ;;
  esac
}

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

is_uint() {
  case "${1:-}" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

# ---- file guards ------------------------------------------------------------
# Writing PNG bytes over a shell script is unrecoverable in practice, so the
# three ways it happens are refused outright.
guard_capture_target() {
  local f="$1" self
  case "$f" in
    *.sh|*.bash|*.zsh|*.command)
      die "Refusing to write image data to '$f': that is a script filename."
      return 1 ;;
  esac
  if [ -f "$f" ] && [ "$(head -c 2 "$f" 2>/dev/null)" = '#!' ]; then
    die "Refusing to overwrite '$f': the existing file starts with a shebang."
    return 1
  fi
  if [ -f "$0" ]; then
    self=$(abspath "$0")
    if [ "$f" = "$self" ]; then
      die "Refusing to overwrite the running script."
      return 1
    fi
  fi
  case "$f" in
    */*) if [ ! -d "${f%/*}" ]; then die "Directory does not exist: ${f%/*}"; return 1; fi ;;
  esac
  return 0
}

looks_like_image() {
  local sig
  sig=$(head -c 4 "$1" 2>/dev/null | od -An -tx1 | tr -d ' \n')
  case "$sig" in
    89504e47|ffd8ff??|47494638|52494646|424d??*) return 0 ;;
    *) return 1 ;;
  esac
}

file_size() { wc -c < "$1" | tr -d '[:space:]'; }

usage() {
  cat >&2 <<'EOF'
screenshot_upload_v2.sh - capture the visible display and upload it.
Only the resulting URL is printed on stdout; everything else is stderr.

Usage:
  screenshot_upload_v2.sh                  capture -> upload -> print URL
  screenshot_upload_v2.sh -o shot.png      keep the original capture at shot.png
  screenshot_upload_v2.sh /path/img.png    upload an existing image, no capture
  screenshot_upload_v2.sh -h               show this help
  screenshot_upload_v2.sh -v               show the version

Environment:
  SCREENSHOT_UPLOADER  img402 | litterbox | catbox | uguu | quax | tempsh
  SCREENSHOT_DISPLAY   macOS: display number (default: the one under the pointer);
                       wlroots: output name; Windows: 1-based screen index
  LITTERBOX_TIME       1h | 12h | 24h | 72h            (default 24h)
  MAX_BYTES            downscale a temp copy past this (default 9000000)
  NO_INSTALL=1         never attempt package installation
EOF
}

# =============================================================================
# 1. Package installation (Linux only, opt-out via NO_INSTALL=1)
# =============================================================================
SUDO=""
SUDO_READY=0

init_sudo() {
  [ "$SUDO_READY" = "1" ] && return 0
  if [ "$(id -u)" -eq 0 ]; then
    SUDO=""; SUDO_READY=1; return 0
  fi
  if command -v sudo >/dev/null 2>&1; then
    if sudo -n true >/dev/null 2>&1; then
      SUDO="sudo -n"; SUDO_READY=1; return 0
    fi
    if [ -t 0 ] || [ -r /dev/tty ]; then
      SUDO="sudo"; SUDO_READY=1; return 0
    fi
  fi
  return 1
}

PM=""
detect_pm() {
  local pm
  [ -n "$PM" ] && return 0
  for pm in apt-get dnf yum pacman zypper apk; do
    if command -v "$pm" >/dev/null 2>&1; then PM="$pm"; return 0; fi
  done
  return 1
}

# pkg_for <command> <package-manager> -> package name on stdout
pkg_for() {
  case "$1" in
    curl)             printf 'curl' ;;
    grim)             printf 'grim' ;;
    gnome-screenshot) printf 'gnome-screenshot' ;;
    maim)             printf 'maim' ;;
    scrot)            printf 'scrot' ;;
    spectacle)
      case "$2" in
        apt-get) printf 'kde-spectacle' ;;
        *)       printf 'spectacle' ;;
      esac ;;
    import)
      case "$2" in
        dnf|yum|zypper) printf 'ImageMagick' ;;
        *)              printf 'imagemagick' ;;
      esac ;;
    *) return 1 ;;
  esac
  return 0
}

APT_REFRESHED=0

# install_cmd <command> - installs the package providing <command>, if allowed
install_cmd() {
  local cmd="$1" pkg rc=0
  if command -v "$cmd" >/dev/null 2>&1; then return 0; fi
  if [ "${NO_INSTALL:-0}" = "1" ]; then
    die "'$cmd' is missing and NO_INSTALL=1 is set. Install it and re-run."
    return 1
  fi
  if ! detect_pm; then
    die "'$cmd' is missing and no supported package manager was found."
    die "Supported: apt-get, dnf, yum, pacman, zypper, apk."
    return 1
  fi
  pkg=$(pkg_for "$cmd" "$PM") || { die "No package mapping for '$cmd'."; return 1; }
  if ! init_sudo; then
    die "'$cmd' is missing. Install the '$pkg' package (root or sudo required)."
    return 1
  fi
  info "Installing '$pkg' with $PM ..."
  case "$PM" in
    apt-get)
      if [ "$APT_REFRESHED" = "0" ]; then
        $SUDO apt-get update -qq >/dev/null 2>&1
        APT_REFRESHED=1
      fi
      # sudo's env_reset drops caller-set variables, so pass it through env(1)
      $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$pkg" >/dev/null 2>&1 || rc=1 ;;
    dnf)    $SUDO dnf install -y -q "$pkg"                  >/dev/null 2>&1 || rc=1 ;;
    yum)    $SUDO yum install -y -q "$pkg"                  >/dev/null 2>&1 || rc=1 ;;
    pacman) $SUDO pacman -Sy --noconfirm --needed "$pkg"    >/dev/null 2>&1 || rc=1 ;;
    zypper) $SUDO zypper --non-interactive install "$pkg"   >/dev/null 2>&1 || rc=1 ;;
    apk)    $SUDO apk add --no-progress "$pkg"              >/dev/null 2>&1 || rc=1 ;;
    *)      rc=1 ;;
  esac
  if [ "$rc" -ne 0 ] || ! command -v "$cmd" >/dev/null 2>&1; then
    die "Could not install '$pkg'. Install it manually and re-run."
    return 1
  fi
  ok "Installed $pkg"
  return 0
}

ensure_curl() {
  command -v curl >/dev/null 2>&1 && return 0
  case "$(uname -s)" in
    Linux) install_cmd curl || return 1 ;;
    *)     die "curl is required but was not found."; return 1 ;;
  esac
  return 0
}

# =============================================================================
# 2. Platform detection
# =============================================================================
PLATFORM=""

detect_platform() {
  local os rel
  os=$(uname -s)
  case "$os" in
    Darwin) PLATFORM="macos"; return 0 ;;
    MINGW*|MSYS*|CYGWIN*) PLATFORM="windows"; return 0 ;;
    Linux)
      rel=""
      [ -r /proc/sys/kernel/osrelease ] && rel=$(lower "$(cat /proc/sys/kernel/osrelease 2>/dev/null)")
      case "$rel" in
        *microsoft*|*wsl*) PLATFORM="windows"; return 0 ;;
      esac
      if [ -n "${WSL_DISTRO_NAME:-}" ] || [ -n "${WSL_INTEROP:-}" ]; then
        PLATFORM="windows"; return 0
      fi
      PLATFORM="linux"; return 0 ;;
    *BSD*|DragonFly) PLATFORM="linux"; return 0 ;;
  esac
  die "Unsupported operating system: $os"
  return 1
}

is_wsl() { [ "$PLATFORM" = "windows" ] && [ "$(uname -s)" = "Linux" ]; }

# =============================================================================
# 3. macOS capture
# =============================================================================
# CGPreflightScreenCaptureAccess answers for the process that asks, and osascript
# is not always attributed the same way screencapture is, so its answer alone is
# not trustworthy in either direction.
macos_preflight() {
  local r
  command -v osascript >/dev/null 2>&1 || { printf 'unknown'; return 0; }
  r=$(osascript -l JavaScript \
        -e 'ObjC.import("CoreGraphics"); $.CGPreflightScreenCaptureAccess() ? "granted" : "denied"' \
        2>/dev/null) || { printf 'unknown'; return 0; }
  case "$r" in
    granted|denied) printf '%s' "$r" ;;
    *)              printf 'unknown' ;;
  esac
}

# Window titles are readable only with Screen Recording access, while the rest of
# the window list is not gated. "Several windows on screen, none of them titled"
# is therefore a direct observation of the denial, not an inference.
# Prints "<onscreen-windows> <titled-windows>".
macos_window_probe() {
  local r
  command -v osascript >/dev/null 2>&1 || { printf '0 0'; return 0; }
  r=$(osascript -l JavaScript -e 'ObjC.import("CoreGraphics");
var l = ObjC.deepUnwrap($.CGWindowListCopyWindowInfo(17, 0)) || [];
var t = 0, n = 0;
for (var i = 0; i < l.length; i++) {
  if (l[i].kCGWindowLayer !== 0) continue;
  t++;
  var nm = l[i].kCGWindowName;
  if (nm !== undefined && nm !== null && String(nm).length > 0) n++;
}
t + " " + n' 2>/dev/null) || { printf '0 0'; return 0; }
  case "$r" in
    [0-9]*' '[0-9]*) printf '%s' "$r" ;;
    *)               printf '0 0' ;;
  esac
}

# 1-based index of the display holding the mouse pointer, in NSScreen order
# (index 1 is the display carrying the menu bar). 0 means "could not tell".
# The pointer is used because it needs no permission, unlike asking the
# accessibility API which window is frontmost.
macos_pointer_display() {
  local r
  command -v osascript >/dev/null 2>&1 || { printf '0'; return 0; }
  r=$(osascript -l JavaScript -e 'ObjC.import("AppKit");
var m = $.NSEvent.mouseLocation;
var s = $.NSScreen.screens.js;
var pick = 0;
for (var i = 0; i < s.length; i++) {
  var f = s[i].frame;
  if (m.x >= f.origin.x && m.x < f.origin.x + f.size.width &&
      m.y >= f.origin.y && m.y < f.origin.y + f.size.height) { pick = i + 1; break; }
}
String(pick)' 2>/dev/null) || { printf '0'; return 0; }
  is_uint "$r" && printf '%s' "$r" || printf '0'
}

macos_check_permission() {
  local perm probe total named app
  perm=$(macos_preflight)
  probe=$(macos_window_probe)
  total="${probe%% *}"
  named="${probe##* }"
  app="${TERM_PROGRAM:-the terminal application you launched this from}"

  if { [ "$perm" = "denied" ] && [ "$named" -eq 0 ]; } || \
     { [ "$total" -gt 2 ] && [ "$named" -eq 0 ]; }; then
    die "Screen Recording permission is not granted ($total windows are on screen"
    die "and none of their titles are readable). macOS would hand back the desktop"
    die "background with no windows in it, so nothing is captured or uploaded."
    die "Grant it in System Settings > Privacy & Security > Screen Recording,"
    die "then enable $app."
    die "Afterwards quit that application completely and relaunch it: opening a"
    die "new tab or window does not pick up the new grant."
    return 1
  fi

  if [ "$perm" = "denied" ]; then
    warn "Preflight reports no Screen Recording access, but window titles are"
    warn "readable, so the grant probably belongs to the terminal rather than to"
    warn "osascript. Continuing."
  fi
  [ "$total" -gt 0 ] && info "$total windows on screen, $named titled"
  return 0
}

# Logging the pixel size makes a wrong display pick obvious immediately.
macos_report_size() {
  local d
  command -v sips >/dev/null 2>&1 || return 0
  d=$(sips -g pixelWidth -g pixelHeight "$1" 2>/dev/null \
      | awk '/pixelWidth/{w=$2} /pixelHeight/{h=$2} END{if (w != "" && h != "") print w "x" h}')
  [ -n "$d" ] && info "Capture is $d pixels"
  return 0
}

capture_macos() {
  local out="$1" idx dir best bestsize sz shots f
  command -v screencapture >/dev/null 2>&1 || { die "screencapture not found."; return 1; }
  macos_check_permission || return 1

  if [ -n "${SCREENSHOT_DISPLAY:-}" ]; then
    is_uint "${SCREENSHOT_DISPLAY:-}" || { die "SCREENSHOT_DISPLAY must be a display number on macOS."; return 1; }
    idx="$SCREENSHOT_DISPLAY"
  else
    idx=$(macos_pointer_display)
  fi

  if [ "$idx" -gt 0 ]; then
    info "Capturing display $idx (the one holding the pointer)"
    rm -f "$out"
    screencapture -x -D "$idx" "$out" >/dev/null 2>&1 || true
    if [ -s "$out" ]; then macos_report_size "$out"; return 0; fi
    warn "screencapture -D $idx produced nothing; capturing every display instead"
  else
    info "Could not identify the active display; capturing every display"
  fi

  # -m is deliberately not used. It restricts the capture to the display that
  # carries the menu bar, which on a multi-monitor Mac is routinely not the
  # display being worked on, and that is how a wallpaper-only shot gets uploaded.
  dir="$SCRATCH/displays"
  rm -rf "$dir"
  mkdir -p "$dir" || { die "Cannot create $dir"; return 1; }
  screencapture -x "$dir/d.png" >/dev/null 2>&1 || true

  best=""
  bestsize=0
  shots=0
  for f in "$dir"/*.png; do
    [ -f "$f" ] || continue
    shots=$((shots + 1))
    sz=$(file_size "$f")
    if [ "$sz" -gt "$bestsize" ]; then bestsize="$sz"; best="$f"; fi
  done
  [ -n "$best" ] || { die "screencapture produced no image."; return 1; }
  if [ "$shots" -gt 1 ]; then
    info "Captured $shots displays; uploading the one with the most content"
    warn "Set SCREENSHOT_DISPLAY=1..$shots to choose a specific display."
  fi

  rm -f "$out"
  mv -f "$best" "$out" || { die "Cannot move the capture to '$out'."; return 1; }
  macos_report_size "$out"
  return 0
}

# =============================================================================
# 4. Windows capture (Git Bash, MSYS2, Cygwin, WSL)
# =============================================================================
PSEXE=""

find_powershell() {
  local c
  [ -n "$PSEXE" ] && return 0
  for c in powershell.exe pwsh.exe; do
    if command -v "$c" >/dev/null 2>&1; then PSEXE="$c"; return 0; fi
  done
  for c in \
    /mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe \
    /c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe \
    /cygdrive/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe
  do
    if [ -x "$c" ]; then PSEXE="$c"; return 0; fi
  done
  return 1
}

ps_template() {
  cat <<'PSEOF'
$ErrorActionPreference = 'Stop'
try {
  Add-Type -AssemblyName System.Windows.Forms
  Add-Type -AssemblyName System.Drawing
} catch {
  [Console]::Error.WriteLine('Cannot load System.Windows.Forms / System.Drawing: ' + $_.Exception.Message)
  exit 3
}
try {
  Add-Type -Name Dpi -Namespace ShotUp -MemberDefinition '[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool SetProcessDPIAware();'
  [ShotUp.Dpi]::SetProcessDPIAware() | Out-Null
} catch { }
$target = '@@OUTPATH@@'
$sel = '@@DISPLAY@@'
$screens = [System.Windows.Forms.Screen]::AllScreens
if ($sel -ne '') {
  $idx = 0
  if (-not [int]::TryParse($sel, [ref]$idx)) {
    [Console]::Error.WriteLine('SCREENSHOT_DISPLAY must be a 1-based screen index.')
    exit 4
  }
  if ($idx -lt 1 -or $idx -gt $screens.Length) {
    [Console]::Error.WriteLine('SCREENSHOT_DISPLAY out of range; 1 to ' + $screens.Length + ' available.')
    exit 4
  }
  $screen = $screens[$idx - 1]
} else {
  $screen = [System.Windows.Forms.Screen]::PrimaryScreen
  if ($screen -eq $null) { $screen = $screens[0] }
}
$b = $screen.Bounds
$bmp = New-Object System.Drawing.Bitmap([int]$b.Width, [int]$b.Height, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$gfx = [System.Drawing.Graphics]::FromImage($bmp)
$gfx.CopyFromScreen($b.X, $b.Y, 0, 0, $b.Size, [System.Drawing.CopyPixelOperation]::SourceCopy)
$gfx.Dispose()
$bmp.Save($target, [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()
exit 0
PSEOF
}

ps_quote() { printf '%s' "$1" | sed "s/'/''/g"; }

# Git Bash ships neither cygpath nor wslpath, so the drive-letter mount
# convention (/c/Users <-> C:\Users) is handled directly as a last resort.
posix_to_win_manual() {
  local drive rest
  case "$1" in
    /[A-Za-z]/*) ;;
    *) return 1 ;;
  esac
  drive=$(printf '%s' "$1" | cut -c2 | tr '[:lower:]' '[:upper:]')
  rest=$(printf '%s' "$1" | cut -c3- | tr '/' '\\')
  printf '%s:%s' "$drive" "$rest"
}

win_to_posix_manual() {
  local drive rest
  case "$1" in
    [A-Za-z]:\\*|[A-Za-z]:/*) ;;
    *) return 1 ;;
  esac
  drive=$(printf '%s' "$1" | cut -c1 | tr '[:upper:]' '[:lower:]')
  rest=$(printf '%s' "$1" | cut -c3- | tr '\\' '/')
  printf '/%s%s' "$drive" "$rest"
}

# Resolve a POSIX path to the Windows form the .NET APIs expect.
to_win_path() {
  local r
  if command -v cygpath >/dev/null 2>&1; then
    r=$(cygpath -w "$1" 2>/dev/null) && [ -n "$r" ] && { printf '%s' "$r"; return 0; }
  fi
  if command -v wslpath >/dev/null 2>&1; then
    r=$(wslpath -w "$1" 2>/dev/null) && [ -n "$r" ] && { printf '%s' "$r"; return 0; }
  fi
  posix_to_win_manual "$1"
}

# WSL keeps its filesystem behind a UNC share, and Git Bash keeps /tmp outside
# any drive-letter mount, so in both cases the capture is staged in the Windows
# temp directory and moved back afterwards.
win_stage_dir() {
  local wtmp posix
  [ -n "$WIN_SCRATCH" ] && return 0
  wtmp=$("$PSEXE" -NoProfile -NonInteractive -Command \
          '[Console]::Out.Write([System.IO.Path]::GetTempPath())' 2>/dev/null | tr -d '\r\n')
  [ -n "$wtmp" ] || return 1
  if command -v wslpath >/dev/null 2>&1; then
    posix=$(wslpath -u "$wtmp" 2>/dev/null)
  elif command -v cygpath >/dev/null 2>&1; then
    posix=$(cygpath -u "$wtmp" 2>/dev/null)
  else
    posix=$(win_to_posix_manual "$wtmp") || return 1
  fi
  [ -n "$posix" ] && [ -d "$posix" ] || return 1
  WIN_SCRATCH="${posix%/}/shotup2.$$"
  mkdir -p "$WIN_SCRATCH" || { WIN_SCRATCH=""; return 1; }
  return 0
}

capture_windows() {
  local out="$1" work_posix work_win ps1_posix ps1_win tpl script rc esc_out esc_sel staged=0

  if ! find_powershell; then
    die "No powershell.exe or pwsh.exe on PATH."
    die "Run this from Git Bash, MSYS2, Cygwin, or WSL with Windows interop enabled."
    return 1
  fi
  info "Windows capture via $PSEXE"

  # WSL always stages Windows-side; MSYS2/Cygwin/Git Bash only when the scratch
  # directory has no Windows-visible name.
  if is_wsl; then
    win_stage_dir && staged=1
  elif ! to_win_path "$SCRATCH" >/dev/null 2>&1; then
    win_stage_dir && staged=1
  fi

  if [ "$staged" -eq 1 ]; then
    work_posix="$WIN_SCRATCH/wincap.png"
    ps1_posix="$WIN_SCRATCH/wincap.ps1"
  else
    work_posix="$SCRATCH/wincap.png"
    ps1_posix="$SCRATCH/wincap.ps1"
  fi

  work_win=$(to_win_path "$work_posix") || { die "Cannot convert '$work_posix' to a Windows path."; return 1; }
  ps1_win=$(to_win_path "$ps1_posix")   || { die "Cannot convert '$ps1_posix' to a Windows path."; return 1; }

  esc_out=$(ps_quote "$work_win")
  esc_sel=$(ps_quote "${SCREENSHOT_DISPLAY:-}")
  tpl=$(ps_template)
  script=${tpl//@@OUTPATH@@/$esc_out}
  script=${script//@@DISPLAY@@/$esc_sel}
  printf '%s\n' "$script" > "$ps1_posix" || { die "Cannot write $ps1_posix"; return 1; }

  rm -f "$work_posix"
  "$PSEXE" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$ps1_win" >/dev/null 2>&1
  rc=$?
  if [ "$rc" -ne 0 ]; then
    die "PowerShell capture failed (exit $rc)."
    [ "$rc" -eq 4 ] && die "Check SCREENSHOT_DISPLAY."
    return 1
  fi
  if [ ! -s "$work_posix" ]; then
    die "PowerShell produced no image. A locked, disconnected, or session-0"
    die "desktop cannot be captured."
    return 1
  fi
  if [ "$work_posix" != "$out" ]; then
    mv -f "$work_posix" "$out" || { die "Cannot move the capture to '$out'."; return 1; }
  fi
  return 0
}

# =============================================================================
# 5. Linux capture
# =============================================================================
session_is_wayland() {
  [ "$(lower "${XDG_SESSION_TYPE:-}")" = "wayland" ] || [ -n "${WAYLAND_DISPLAY:-}" ]
}

# Fill in only this user's own session variables. Other users' runtime
# directories and X authority files are deliberately left alone.
adopt_own_session_env() {
  local uid rt sock
  uid=$(id -u)
  rt="${XDG_RUNTIME_DIR:-/run/user/$uid}"
  if [ -d "$rt" ]; then
    [ -n "${XDG_RUNTIME_DIR:-}" ] || export XDG_RUNTIME_DIR="$rt"
    if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ] && [ -S "$rt/bus" ]; then
      export DBUS_SESSION_BUS_ADDRESS="unix:path=$rt/bus"
    fi
    if [ -z "${WAYLAND_DISPLAY:-}" ]; then
      for sock in "$rt"/wayland-[0-9]*; do
        case "$sock" in *.lock) continue ;; esac
        [ -S "$sock" ] || continue
        export WAYLAND_DISPLAY="${sock##*/}"
        info "WAYLAND_DISPLAY=$WAYLAND_DISPLAY"
        break
      done
    fi
  fi
}

desktop_id() {
  lower "${XDG_CURRENT_DESKTOP:-}:${XDG_SESSION_DESKTOP:-}:${DESKTOP_SESSION:-}"
}

gnome_dbus_available() {
  command -v gdbus >/dev/null 2>&1 || return 1
  gdbus introspect --session -d org.gnome.Shell.Screenshot \
        -o /org/gnome/Shell/Screenshot >/dev/null 2>&1
}

capture_gnome_dbus() {
  local out="$1" reply path
  reply=$(gdbus call --session -d org.gnome.Shell.Screenshot \
            -o /org/gnome/Shell/Screenshot \
            -m org.gnome.Shell.Screenshot.Screenshot false false "$out" 2>&1) \
    || { warn "org.gnome.Shell.Screenshot: $reply"; return 1; }
  case "$reply" in
    *true*) ;;
    *) warn "org.gnome.Shell.Screenshot declined: $reply"; return 1 ;;
  esac
  # Some releases write where they like and report the path back.
  path=$(printf '%s' "$reply" | sed -n "s/.*'\\(.*\\)'.*/\\1/p")
  if [ -n "$path" ] && [ "$path" != "$out" ] && [ -f "$path" ]; then
    mv -f "$path" "$out" || return 1
  fi
  [ -s "$out" ]
}

run_capture_tool() {
  local tool="$1" out="$2"
  rm -f "$out"
  case "$tool" in
    grim)
      if [ -n "${SCREENSHOT_DISPLAY:-}" ]; then
        grim -o "$SCREENSHOT_DISPLAY" "$out" >/dev/null 2>&1
      else
        grim "$out" >/dev/null 2>&1
      fi ;;
    spectacle)        spectacle -b -n -f -o "$out" >/dev/null 2>&1 ;;
    gnome-screenshot) gnome-screenshot -f "$out" >/dev/null 2>&1 ;;
    gnome-dbus)       capture_gnome_dbus "$out" ;;
    maim)             maim "$out" >/dev/null 2>&1 ;;
    scrot)            scrot "$out" >/dev/null 2>&1 ;;
    import)           import -window root "$out" >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac || return 1
  [ -s "$out" ]
}

try_tools() {
  # $1 = output path, remaining args = tool names in preference order
  local out="$1" tool
  shift
  for tool in "$@"; do
    case "$tool" in
      gnome-dbus) gnome_dbus_available || continue ;;
      *) command -v "$tool" >/dev/null 2>&1 || continue ;;
    esac
    info "Capturing with $tool"
    if run_capture_tool "$tool" "$out"; then return 0; fi
    warn "$tool did not produce an image; trying the next method"
  done
  return 1
}

capture_wayland() {
  local out="$1" desk pref want

  desk=$(desktop_id)
  case "$desk" in
    *gnome*|*ubuntu*|*pantheon*|*cinnamon*) pref="gnome"; want="gnome-screenshot" ;;
    *kde*|*plasma*)                          pref="kde";   want="spectacle" ;;
    *sway*|*hyprland*|*river*|*wayfire*|*labwc*|*niri*|*wlroots*|*cosmic*)
                                             pref="wlroots"; want="grim" ;;
    *) pref="unknown"; want="" ;;
  esac
  if [ "$pref" = "unknown" ]; then
    if [ -n "${SWAYSOCK:-}" ] || [ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]; then
      pref="wlroots"; want="grim"
    fi
  fi
  info "Wayland session (compositor family: $pref)"

  case "$pref" in
    gnome)   try_tools "$out" gnome-screenshot gnome-dbus && return 0 ;;
    kde)     try_tools "$out" spectacle && return 0 ;;
    wlroots) try_tools "$out" grim && return 0 ;;
    *)
      # Every candidate here captures the composited output; no X11 root grabs.
      try_tools "$out" grim spectacle gnome-screenshot gnome-dbus && return 0 ;;
  esac

  if [ -n "$want" ] && [ "$(uname -s)" = "Linux" ]; then
    if install_cmd "$want"; then
      try_tools "$out" "$want" && return 0
    fi
  fi

  die "No working Wayland capture method for this compositor."
  die "Install the native tool for your desktop: grim (wlroots/sway/Hyprland),"
  die "kde-spectacle (KDE Plasma), or gnome-screenshot (GNOME)."
  die "X11 root-window capture is refused here: on Wayland it returns the"
  die "wallpaper without any application windows."
  return 1
}

capture_x11() {
  local out="$1"

  if [ -z "${DISPLAY:-}" ]; then
    die "DISPLAY is not set, so there is no reachable X11 session."
    die "Run this script from inside the graphical session as the logged-in user."
    return 1
  fi
  info "X11 session (DISPLAY=$DISPLAY)"
  if [ -n "${SCREENSHOT_DISPLAY:-}" ]; then
    warn "SCREENSHOT_DISPLAY is ignored on X11; the whole root display is captured."
  fi

  try_tools "$out" maim scrot import gnome-screenshot spectacle && return 0

  if [ "$(uname -s)" = "Linux" ]; then
    local cand
    for cand in maim scrot import; do
      if install_cmd "$cand"; then
        try_tools "$out" "$cand" && return 0
        break
      fi
    done
  fi

  die "No usable X11 capture tool. Install one of: maim, scrot, imagemagick."
  return 1
}

capture_linux() {
  local out="$1"
  adopt_own_session_env
  if session_is_wayland; then
    capture_wayland "$out"
  else
    capture_x11 "$out"
  fi
}

take_screenshot() {
  local out="$1"
  case "$PLATFORM" in
    macos)   capture_macos   "$out" ;;
    windows) capture_windows "$out" ;;
    linux)   capture_linux   "$out" ;;
    *) die "Unknown platform."; return 1 ;;
  esac || return 1
  if [ ! -s "$out" ]; then
    die "Capture produced an empty file."
    return 1
  fi
  return 0
}

# =============================================================================
# 6. Downscaling (only ever applied to a temporary copy)
# =============================================================================
have_resizer() {
  command -v sips >/dev/null 2>&1 && return 0
  command -v magick >/dev/null 2>&1 && return 0
  command -v convert >/dev/null 2>&1 && return 0
  return 1
}

resize_to() {
  local f="$1" px="$2" tmp="$1.rs.png" rc=0
  if command -v sips >/dev/null 2>&1; then
    sips -Z "$px" "$f" >/dev/null 2>&1 || rc=1
  elif command -v magick >/dev/null 2>&1; then
    if magick "$f" -resize "${px}x${px}>" -strip "$tmp" >/dev/null 2>&1; then
      mv -f "$tmp" "$f" || rc=1
    else
      rc=1
    fi
  elif command -v convert >/dev/null 2>&1; then
    if convert "$f" -resize "${px}x${px}>" -strip "$tmp" >/dev/null 2>&1; then
      mv -f "$tmp" "$f" || rc=1
    else
      rc=1
    fi
  else
    rc=2
  fi
  rm -f "$tmp"
  return $rc
}

shrink_copy() {
  local f="$1" size px
  size=$(file_size "$f")
  [ "$size" -le "$MAX_BYTES" ] && return 0
  warn "Copy is $size bytes (limit $MAX_BYTES); downscaling it"
  for px in 2560 1920 1280; do
    resize_to "$f" "$px"
    case $? in
      0) ;;
      2) warn "No sips, magick, or convert available; uploading at full size"; return 0 ;;
      *) warn "Downscale to ${px}px failed; uploading at full size"; return 0 ;;
    esac
    size=$(file_size "$f")
    if [ "$size" -le "$MAX_BYTES" ]; then
      ok "Downscaled to $size bytes at ${px}px"
      return 0
    fi
  done
  warn "Still $size bytes after downscaling; early uploaders may reject it"
  return 0
}

# =============================================================================
# 7. Uploaders
# =============================================================================
http_post() {
  local out code body rc errf
  errf="$SCRATCH/curl.err"
  out=$(curl -sS --connect-timeout "$CURL_CONNECT" -m "$CURL_MAX" \
             -A "$UA" -w '\n%{http_code}' "$@" 2>"$errf")
  rc=$?
  if [ "$rc" -ne 0 ]; then
    warn "curl exit $rc: $(tr '\n' ' ' < "$errf" 2>/dev/null | cut -c1-200)"
    return 1
  fi
  code="${out##*$'\n'}"
  body="${out%$'\n'*}"
  case "$code" in
    2??) printf '%s' "$body"; return 0 ;;
    *)   warn "HTTP $code: $(printf '%s' "$body" | tr '\n' ' ' | cut -c1-200)"; return 1 ;;
  esac
}

# First "url": "..." value in a JSON body, without needing jq.
json_url() {
  printf '%s' "$1" \
    | tr '{},' '\n\n\n' \
    | sed -n 's/.*"url"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
    | sed 's|\\/|/|g' \
    | head -n 1
}

plain_url() { printf '%s' "$1" | tr -d '[:space:]'; }

valid_url() {
  case "${1:-}" in
    http://*|https://*) ;;
    *) return 1 ;;
  esac
  case "$1" in
    *[![:print:]]*|*' '*) return 1 ;;
  esac
  [ ${#1} -ge 12 ] || return 1
  return 0
}

upload_img402() {
  local r u
  r=$(http_post "https://img402.dev/api/free" -X POST -F "image=@\"$1\"") || return 1
  u=$(json_url "$r")
  valid_url "$u" || { warn "img402: no usable url in $(printf '%s' "$r" | cut -c1-200)"; return 1; }
  printf '%s' "$u"
}

upload_litterbox() {
  local r u
  r=$(http_post "https://litterbox.catbox.moe/resources/internals/api.php" \
        -F "reqtype=fileupload" -F "time=$LITTERBOX_TIME" -F "fileToUpload=@\"$1\"") || return 1
  u=$(plain_url "$r")
  valid_url "$u" || { warn "litterbox: $(printf '%s' "$r" | cut -c1-200)"; return 1; }
  printf '%s' "$u"
}

upload_catbox() {
  local r u
  r=$(http_post "https://catbox.moe/user/api.php" \
        -F "reqtype=fileupload" -F "fileToUpload=@\"$1\"") || return 1
  u=$(plain_url "$r")
  valid_url "$u" || { warn "catbox: $(printf '%s' "$r" | cut -c1-200)"; return 1; }
  printf '%s' "$u"
}

upload_uguu() {
  local r u ep
  for ep in "https://uguu.se/upload?output=json" "https://uguu.se/upload.php?output=json"; do
    r=$(http_post "$ep" -F "files[]=@\"$1\"") || continue
    u=$(json_url "$r")
    if valid_url "$u"; then printf '%s' "$u"; return 0; fi
    warn "uguu: no usable url in $(printf '%s' "$r" | cut -c1-200)"
  done
  return 1
}

upload_quax() {
  local r u
  r=$(http_post "https://qu.ax/upload.php" -F "files[]=@\"$1\"") || return 1
  u=$(json_url "$r")
  valid_url "$u" || { warn "qu.ax: no usable url in $(printf '%s' "$r" | cut -c1-200)"; return 1; }
  printf '%s' "$u"
}

upload_tempsh() {
  local r u
  r=$(http_post "https://temp.sh/upload" -F "file=@\"$1\"") || return 1
  u=$(plain_url "$r")
  valid_url "$u" || { warn "temp.sh: $(printf '%s' "$r" | cut -c1-200)"; return 1; }
  printf '%s' "$u"
}

UPLOAD_CHAIN="img402 litterbox catbox uguu quax tempsh"

run_uploader() {
  case "$1" in
    img402)    upload_img402    "$2" ;;
    litterbox) upload_litterbox "$2" ;;
    catbox)    upload_catbox    "$2" ;;
    uguu)      upload_uguu      "$2" ;;
    quax)      upload_quax      "$2" ;;
    tempsh)    upload_tempsh    "$2" ;;
    *) return 1 ;;
  esac
}

known_uploader() {
  local n
  for n in $UPLOAD_CHAIN; do
    [ "$1" = "$n" ] && return 0
  done
  return 1
}

upload_with_fallback() {
  local file="$1" chain name url
  if [ -n "${SCREENSHOT_UPLOADER:-}" ]; then
    if ! known_uploader "$SCREENSHOT_UPLOADER"; then
      die "Unknown SCREENSHOT_UPLOADER '$SCREENSHOT_UPLOADER'."
      die "Supported: $UPLOAD_CHAIN"
      return 1
    fi
    chain="$SCREENSHOT_UPLOADER"
  else
    chain="$UPLOAD_CHAIN"
  fi

  for name in $chain; do
    info "Uploading via $name"
    url=$(run_uploader "$name" "$file")
    if [ $? -eq 0 ] && valid_url "$url"; then
      ok "Uploaded via $name"
      emit_url "$url"
      return 0
    fi
    warn "$name failed"
  done
  die "All uploaders failed."
  return 1
}

# =============================================================================
# 8. Main
# =============================================================================
main() {
  local keep_file="" input_file="" positional_seen=0 no_more_opts=0
  local shot upload_src size copy

  while [ $# -gt 0 ]; do
    if [ "$no_more_opts" -eq 0 ]; then
      case "$1" in
        --) no_more_opts=1; shift; continue ;;
        -h|--help) usage; exit 0 ;;
        -v|--version) printf 'screenshot_upload_v2.sh %s\n' "$VERSION" >&2; exit 0 ;;
        -o|--output)
          [ $# -ge 2 ] || { die "$1 requires a path."; exit 2; }
          [ -z "$keep_file" ] || { die "-o given more than once."; exit 2; }
          keep_file="$2"; shift 2; continue ;;
        -o=*|--output=*)
          [ -z "$keep_file" ] || { die "-o given more than once."; exit 2; }
          keep_file="${1#*=}"
          [ -n "$keep_file" ] || { die "-o requires a path."; exit 2; }
          shift; continue ;;
        -*) die "Unknown option: $1"; usage; exit 2 ;;
      esac
    fi
    if [ "$positional_seen" -eq 1 ]; then
      die "Only one image path may be given."; exit 2
    fi
    input_file="$1"; positional_seen=1; shift
  done

  if [ -n "$input_file" ] && [ -n "$keep_file" ]; then
    die "-o cannot be combined with an existing image path: there is nothing to capture."
    exit 2
  fi

  case "$LITTERBOX_TIME" in
    1h|12h|24h|72h) ;;
    *) die "LITTERBOX_TIME must be one of: 1h, 12h, 24h, 72h."; exit 2 ;;
  esac
  if ! is_uint "$MAX_BYTES" || [ "$MAX_BYTES" -le 0 ]; then
    die "MAX_BYTES must be a positive integer."
    exit 2
  fi

  info "screenshot_upload_v2.sh $VERSION"
  detect_platform || exit 1
  make_scratch || { die "Cannot create a temporary directory."; exit 1; }
  ensure_curl || exit 1

  if [ -n "$input_file" ]; then
    [ -f "$input_file" ] || { die "File not found: $input_file"; exit 1; }
    [ -r "$input_file" ] || { die "File is not readable: $input_file"; exit 1; }
    [ -s "$input_file" ] || { die "File is empty: $input_file"; exit 1; }
    shot=$(abspath "$input_file")
    info "Uploading the existing file: $shot"
    looks_like_image "$shot" || warn "$shot has no known image signature; uploading it anyway"
  else
    if [ -n "$keep_file" ]; then
      shot=$(abspath "$keep_file")
      guard_capture_target "$shot" || exit 1
    else
      shot=$(scratch_png capture)
    fi
    take_screenshot "$shot" || exit 1
  fi

  size=$(file_size "$shot")
  ok "Image ready: $shot ($size bytes)"

  # The source file is never modified. When it is too large, a throwaway copy
  # is made and that copy is what gets downscaled and uploaded.
  upload_src="$shot"
  if [ "$size" -gt "$MAX_BYTES" ]; then
    if have_resizer; then
      copy=$(scratch_png upload)
      if cp "$shot" "$copy"; then
        shrink_copy "$copy"
        upload_src="$copy"
      else
        warn "Could not copy the image for downscaling; uploading the original"
      fi
    else
      warn "Image exceeds $MAX_BYTES bytes and no resizer is installed; uploading as is"
    fi
  fi

  upload_with_fallback "$upload_src" || exit 1
  exit 0
}

main "$@"
