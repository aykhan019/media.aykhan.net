#!/usr/bin/env bash
# =============================================================================
# grabshot.sh - capture a screenshot, install any missing capture tool when
# needed, then upload the image to a free host with automatic fallbacks.
#
# Only the final image URL is printed on stdout. Everything else is stderr.
#
# This is an independent implementation. screenshot_upload_v2.sh was consulted
# purely as a reference for the general shape of the problem.
#
# Usage:
#   grabshot.sh                 capture the screen, upload, print the URL
#   grabshot.sh -o shot.png     also keep the capture at shot.png
#   grabshot.sh image.png       skip capture, upload an existing image
#   grabshot.sh -h              help
#   grabshot.sh -v              version
#
# Environment:
#   UPLOADER          force one host: tempsh | x0 | fileditch | quax | gofile
#                     | tmpfiles | fileio
#   NO_INSTALL=1      never attempt any package installation
#   MAX_BYTES         downscale a temp copy above this size (default 10485760)
#   SCREENSHOT_OUTPUT wlroots output name for grim / display hint
#
# Portable across Linux (Wayland + X11) and macOS. Needs bash 3.2 or newer.
# =============================================================================
set -u

VERSION="1.0.0"
UA="grabshot/$VERSION"
CONNECT_TIMEOUT=15
MAX_TIME=180

MAX_BYTES="${MAX_BYTES:-10485760}"
UPLOADERS="tempsh x0 fileditch quax gofile tmpfiles fileio"

# ---- logging ----------------------------------------------------------------
# stdout carries the URL alone, so every message here is written to stderr.
if [ -t 2 ]; then
  CI=$'\033[36m'; CG=$'\033[32m'; CY=$'\033[33m'; CR=$'\033[31m'; C0=$'\033[0m'
else
  CI=""; CG=""; CY=""; CR=""; C0=""
fi
info() { printf '%s::%s %s\n' "$CI" "$C0" "$*" >&2; }
ok()   { printf '%s+ %s%s\n'  "$CG" "$*" "$C0" >&2; }
warn() { printf '%s! %s%s\n'  "$CY" "$*" "$C0" >&2; }
die()  { printf '%sx %s%s\n'  "$CR" "$*" "$C0" >&2; }

# ---- scratch space ----------------------------------------------------------
SCRATCH=""
cleanup() { [ -n "$SCRATCH" ] && [ -d "$SCRATCH" ] && rm -rf "$SCRATCH"; return 0; }
trap cleanup EXIT INT TERM

mkscratch() {
  [ -n "$SCRATCH" ] && return 0
  SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/grabshot.XXXXXX") || return 1
  return 0
}

# ---- small helpers ----------------------------------------------------------
have()     { command -v "$1" >/dev/null 2>&1; }
lc()       { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
filesize() { wc -c < "$1" | tr -d '[:space:]'; }
abspath()  { case "$1" in /*) printf '%s' "$1" ;; *) printf '%s/%s' "$PWD" "$1" ;; esac; }

is_uint()  { case "${1:-}" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

is_image() {
  local sig
  sig=$(od -An -tx1 -N4 "$1" 2>/dev/null | tr -d ' \n')
  case "$sig" in
    89504e47|47494638|ffd8ff??|52494646) return 0 ;;   # PNG, GIF, JPEG, WEBP/RIFF
    *) return 1 ;;
  esac
}

# Refuse the obvious ways an image write clobbers something important.
guard_target() {
  local f="$1"
  case "$f" in
    *.sh|*.bash|*.zsh) die "refusing to write image data to a script path: $f"; return 1 ;;
  esac
  if [ -f "$f" ] && [ "$(head -c 2 "$f" 2>/dev/null)" = '#!' ]; then
    die "refusing to overwrite '$f' (it starts with a shebang)"; return 1
  fi
  case "$f" in
    */*) [ -d "${f%/*}" ] || { die "directory does not exist: ${f%/*}"; return 1; } ;;
  esac
  return 0
}

# =============================================================================
# Package installation (Linux only; opt out with NO_INSTALL=1)
# =============================================================================
PM=""
detect_pm() {
  [ -n "$PM" ] && return 0
  local p
  for p in apt-get dnf yum pacman zypper apk; do
    if have "$p"; then PM="$p"; return 0; fi
  done
  return 1
}

SUDO=""
SUDO_SET=0
sudo_prefix() {
  [ "$SUDO_SET" = 1 ] && return 0
  SUDO_SET=1
  if [ "$(id -u)" = 0 ]; then SUDO=""; return 0; fi
  if have sudo; then
    if sudo -n true >/dev/null 2>&1; then SUDO="sudo -n"; return 0; fi
    if [ -t 0 ] || [ -r /dev/tty ]; then SUDO="sudo"; return 0; fi
  fi
  return 1
}

# pkgname <command> <package-manager> -> package name on stdout
pkgname() {
  case "$1" in
    curl)             printf 'curl' ;;
    grim)             printf 'grim' ;;
    maim)             printf 'maim' ;;
    scrot)            printf 'scrot' ;;
    gnome-screenshot) printf 'gnome-screenshot' ;;
    spectacle)        case "$2" in apt-get) printf 'kde-spectacle' ;; *) printf 'spectacle' ;; esac ;;
    import)           case "$2" in dnf|yum|zypper) printf 'ImageMagick' ;; *) printf 'imagemagick' ;; esac ;;
    *) return 1 ;;
  esac
  return 0
}

APT_UPDATED=0
# install_pkg <command> : install the package providing <command>; returns 0
# only if the command is runnable afterwards.
install_pkg() {
  local cmd="$1" pkg
  have "$cmd" && return 0
  if [ "${NO_INSTALL:-0}" = 1 ]; then
    warn "'$cmd' is missing and NO_INSTALL=1 is set"; return 1
  fi
  if ! detect_pm; then
    warn "'$cmd' is missing and no supported package manager was found"; return 1
  fi
  pkg=$(pkgname "$cmd" "$PM") || { warn "no package mapping for '$cmd'"; return 1; }
  if ! sudo_prefix; then
    warn "'$cmd' is missing; installing '$pkg' needs root or sudo"; return 1
  fi
  info "installing '$pkg' with $PM"
  case "$PM" in
    apt-get)
      if [ "$APT_UPDATED" = 0 ]; then $SUDO apt-get update -qq >/dev/null 2>&1; APT_UPDATED=1; fi
      $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$pkg" >/dev/null 2>&1 ;;
    dnf)    $SUDO dnf install -y -q "$pkg"               >/dev/null 2>&1 ;;
    yum)    $SUDO yum install -y -q "$pkg"               >/dev/null 2>&1 ;;
    pacman) $SUDO pacman -Sy --noconfirm --needed "$pkg" >/dev/null 2>&1 ;;
    zypper) $SUDO zypper --non-interactive install "$pkg">/dev/null 2>&1 ;;
    apk)    $SUDO apk add --no-progress "$pkg"           >/dev/null 2>&1 ;;
  esac
  if have "$cmd"; then ok "installed $pkg"; return 0; fi
  warn "could not install '$pkg'"; return 1
}

ensure_curl() {
  have curl && return 0
  case "$(uname -s)" in
    Linux) install_pkg curl && return 0 ;;
  esac
  die "curl is required but was not found"; return 1
}

# =============================================================================
# Platform + capture
# =============================================================================
OS=""
detect_os() {
  case "$(uname -s)" in
    Darwin) OS="macos" ;;
    Linux)  OS="linux" ;;
    *) die "unsupported operating system: $(uname -s)"; return 1 ;;
  esac
  return 0
}

# grab_with <outfile> <tool...> : first tool that yields a non-empty file wins.
grab_with() {
  local out="$1" tool
  shift
  for tool in "$@"; do
    have "$tool" || continue
    info "capturing with $tool"
    rm -f "$out"
    case "$tool" in
      grim)
        if [ -n "${SCREENSHOT_OUTPUT:-}" ]; then grim -o "$SCREENSHOT_OUTPUT" "$out" >/dev/null 2>&1
        else grim "$out" >/dev/null 2>&1; fi ;;
      maim)             maim "$out"                     >/dev/null 2>&1 ;;
      scrot)            scrot "$out"                    >/dev/null 2>&1 ;;
      import)           import -window root "$out"      >/dev/null 2>&1 ;;
      gnome-screenshot) gnome-screenshot -f "$out"      >/dev/null 2>&1 ;;
      spectacle)        spectacle -b -n -o "$out"       >/dev/null 2>&1 ;;
      screencapture)    screencapture -x "$out"         >/dev/null 2>&1 ;;
      *) continue ;;
    esac
    if [ -s "$out" ]; then return 0; fi
    warn "$tool produced no image; trying the next method"
  done
  return 1
}

capture_linux() {
  local out="$1" c
  if [ "$(lc "${XDG_SESSION_TYPE:-}")" = wayland ] || [ -n "${WAYLAND_DISPLAY:-}" ]; then
    info "Wayland session"
    grab_with "$out" grim gnome-screenshot spectacle && return 0
    if install_pkg grim; then grab_with "$out" grim && return 0; fi
    die "no working Wayland capture tool (install grim, gnome-screenshot, or spectacle)"
    return 1
  fi
  if [ -z "${DISPLAY:-}" ]; then
    die "DISPLAY is unset and this is not a Wayland session; run inside a graphical session"
    return 1
  fi
  info "X11 session (DISPLAY=$DISPLAY)"
  grab_with "$out" maim scrot import gnome-screenshot spectacle && return 0
  for c in maim scrot import; do
    if install_pkg "$c"; then grab_with "$out" "$c" && return 0; fi
  done
  die "no working X11 capture tool (install maim, scrot, or imagemagick)"
  return 1
}

capture() {
  local out="$1"
  case "$OS" in
    macos)
      have screencapture || { die "screencapture not found"; return 1; }
      grab_with "$out" screencapture && return 0
      die "screencapture failed (is Screen Recording permission granted?)"
      return 1 ;;
    linux) capture_linux "$out" ;;
    *) die "unknown platform"; return 1 ;;
  esac
}

# =============================================================================
# Downscaling (only ever applied to a throwaway copy)
# =============================================================================
resizer() {
  if have magick;  then printf 'magick';  return 0; fi
  if have convert; then printf 'convert'; return 0; fi
  if have sips;    then printf 'sips';    return 0; fi
  return 1
}

shrink() {
  local f="$1" tool px sz
  sz=$(filesize "$f")
  [ "$sz" -le "$MAX_BYTES" ] && return 0
  tool=$(resizer) || { warn "no resizer available; uploading full size ($sz bytes)"; return 0; }
  warn "image is $sz bytes (> $MAX_BYTES); downscaling"
  for px in 2560 1920 1280; do
    case "$tool" in
      magick)  magick  "$f" -resize "${px}x${px}>" -strip "$f.tmp" >/dev/null 2>&1 && mv -f "$f.tmp" "$f" ;;
      convert) convert "$f" -resize "${px}x${px}>" -strip "$f.tmp" >/dev/null 2>&1 && mv -f "$f.tmp" "$f" ;;
      sips)    sips -Z "$px" "$f" >/dev/null 2>&1 ;;
    esac
    rm -f "$f.tmp"
    sz=$(filesize "$f")
    if [ "$sz" -le "$MAX_BYTES" ]; then ok "downscaled to $sz bytes (max ${px}px)"; return 0; fi
  done
  warn "still $sz bytes after downscaling; uploading anyway"
  return 0
}

# =============================================================================
# Uploaders
# =============================================================================
post() { curl -sS --connect-timeout "$CONNECT_TIMEOUT" -m "$MAX_TIME" -A "$UA" "$@" 2>/dev/null; }

# first "url":"..." value in a JSON body, without needing jq
json_url() {
  printf '%s' "$1" | tr '{},' '\n\n\n' \
    | sed -n 's/.*"url"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
    | sed 's|\\/|/|g' | head -n 1
}
# json_val <body> <key> : first "<key>":"..." string value, without needing jq
json_val() {
  printf '%s' "$1" | tr '{},' '\n\n\n' \
    | sed -n 's/.*"'"$2"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
    | sed 's|\\/|/|g' | head -n 1
}
trim() { printf '%s' "$1" | tr -d '[:space:]'; }

valid_url() {
  case "${1:-}" in http://*|https://*) ;; *) return 1 ;; esac
  case "$1" in *[[:space:]]*|*'<'*|*'>'*) return 1 ;; esac
  [ "${#1}" -ge 12 ]
}

up_tempsh() {
  local r; r=$(post -F "file=@$1" https://temp.sh/upload) || return 1
  r=$(trim "$r"); valid_url "$r" && printf '%s' "$r"
}

# ---- extra fallbacks (hosts re-verified alive August 2026) ------------------
# x0.at     : 0x0-style, plain-text URL reply, ~1 GiB, kept 3-100 days by size
# fileditch : direct link in JSON "url", up to 150 GB, kept while accessed
# quax      : pomf-style JSON, 256 MB max
# gofile    : anonymous API; returns a download page URL, not a direct image
# tmpfiles  : temporary host; expire=172800 asks for the 48 h maximum
# fileio    : true last resort; the link dies after the first download
up_x0() {
  local r; r=$(post -F "file=@$1" https://x0.at) || return 1
  r=$(trim "$r"); valid_url "$r" && printf '%s' "$r"
}
up_fileditch() {
  local r u; r=$(post -F "file=@$1" https://new.fileditch.com/upload.php) || return 1
  u=$(json_url "$r"); valid_url "$u" && printf '%s' "$u"
}
up_quax() {
  local r u; r=$(post -F "files[]=@$1" https://qu.ax/upload.php) || return 1
  u=$(json_url "$r"); valid_url "$u" && printf '%s' "$u"
}
up_gofile() {
  local r u; r=$(post -F "file=@$1" https://upload.gofile.io/uploadfile) || return 1
  u=$(json_val "$r" downloadPage); valid_url "$u" && printf '%s' "$u"
}
up_tmpfiles() {
  local r u; r=$(post -F "file=@$1" -F "expire=172800" https://tmpfiles.org/api/v1/upload) || return 1
  # the API returns a viewer URL; the /dl/ form is the direct download
  u=$(json_url "$r" | sed 's|tmpfiles\.org/|tmpfiles.org/dl/|')
  valid_url "$u" && printf '%s' "$u"
}
up_fileio() {
  local r u; r=$(post -F "file=@$1" https://file.io) || return 1
  u=$(json_val "$r" link); valid_url "$u" && printf '%s' "$u"
}

run_uploader() {
  case "$1" in
    tempsh)    up_tempsh    "$2" ;;
    x0)        up_x0        "$2" ;;
    fileditch) up_fileditch "$2" ;;
    quax)      up_quax      "$2" ;;
    gofile)    up_gofile    "$2" ;;
    tmpfiles)  up_tmpfiles  "$2" ;;
    fileio)    up_fileio    "$2" ;;
    *) return 1 ;;
  esac
}

known_uploader() {
  local n; for n in $UPLOADERS; do [ "$1" = "$n" ] && return 0; done; return 1
}

upload() {
  local file="$1" chain name url
  if [ -n "${UPLOADER:-}" ]; then
    known_uploader "$UPLOADER" || { die "unknown UPLOADER '$UPLOADER'; choose from: $UPLOADERS"; return 1; }
    chain="$UPLOADER"
  else
    chain="$UPLOADERS"
  fi
  for name in $chain; do
    info "uploading via $name"
    url=$(run_uploader "$name" "$file")
    if [ -n "$url" ] && valid_url "$url"; then
      ok "uploaded via $name"
      printf '%s\n' "$url"      # the only line written to stdout
      return 0
    fi
    warn "$name failed"
  done
  die "all uploaders failed"; return 1
}

# =============================================================================
# CLI + main
# =============================================================================
usage() {
  cat >&2 <<EOF
grabshot.sh $VERSION - capture a screenshot and upload it to a free host.
Only the resulting URL is printed on stdout; everything else is stderr.

Usage:
  grabshot.sh                 capture, upload, print the URL
  grabshot.sh -o shot.png     also save the capture to shot.png
  grabshot.sh image.png       upload an existing image, no capture
  grabshot.sh -h              show this help
  grabshot.sh -v              show the version

Environment:
  UPLOADER          force one host: $UPLOADERS
  NO_INSTALL=1      never install packages
  MAX_BYTES         downscale a temp copy past this (default $MAX_BYTES)
  SCREENSHOT_OUTPUT wlroots output name for grim / display hint
EOF
}

main() {
  local keep="" existing="" seen=0 endopts=0 shot src size

  while [ $# -gt 0 ]; do
    if [ "$endopts" = 0 ]; then
      case "$1" in
        --) endopts=1; shift; continue ;;
        -h|--help)    usage; exit 0 ;;
        -v|--version) printf 'grabshot.sh %s\n' "$VERSION" >&2; exit 0 ;;
        -o|--output)
          [ $# -ge 2 ] || { die "$1 requires a path"; exit 2; }
          [ -z "$keep" ] || { die "-o given more than once"; exit 2; }
          keep="$2"; shift 2; continue ;;
        -o=*|--output=*)
          [ -z "$keep" ] || { die "-o given more than once"; exit 2; }
          keep="${1#*=}"; [ -n "$keep" ] || { die "-o requires a path"; exit 2; }
          shift; continue ;;
        -*) die "unknown option: $1"; usage; exit 2 ;;
      esac
    fi
    [ "$seen" = 0 ] || { die "only one image path may be given"; exit 2; }
    existing="$1"; seen=1; shift
  done

  if [ -n "$existing" ] && [ -n "$keep" ]; then
    die "-o cannot be combined with an existing image path"; exit 2
  fi
  if ! is_uint "$MAX_BYTES" || [ "$MAX_BYTES" -le 0 ]; then
    die "MAX_BYTES must be a positive integer"; exit 2
  fi

  info "grabshot.sh $VERSION"
  detect_os || exit 1
  mkscratch || { die "cannot create a temporary directory"; exit 1; }
  ensure_curl || exit 1

  if [ -n "$existing" ]; then
    [ -f "$existing" ] && [ -r "$existing" ] || { die "cannot read file: $existing"; exit 1; }
    [ -s "$existing" ] || { die "file is empty: $existing"; exit 1; }
    shot=$(abspath "$existing")
    is_image "$shot" || warn "$existing has no known image signature; uploading anyway"
    info "using existing image: $shot"
  else
    if [ -n "$keep" ]; then
      shot=$(abspath "$keep")
      guard_target "$shot" || exit 1
    else
      shot="$SCRATCH/capture.png"
    fi
    capture "$shot" || exit 1
  fi

  size=$(filesize "$shot")
  is_uint "$size" && [ "$size" -gt 0 ] || { die "the image is empty"; exit 1; }
  ok "image ready: $shot ($size bytes)"

  # Never modify the source. If it is too large, copy it and shrink the copy.
  src="$shot"
  if [ "$size" -gt "$MAX_BYTES" ]; then
    if cp "$shot" "$SCRATCH/upload.png"; then src="$SCRATCH/upload.png"; shrink "$src"
    else warn "could not copy for downscaling; uploading the original"; fi
  fi

  upload "$src" || exit 1
  exit 0
}

main "$@"
