#!/usr/bin/env bash
set -Eeuo pipefail

# Captures the current user's visible desktop after explicit confirmation,
# uploads it to a public image/file host, and prints the first working URL.
# Status messages go to stderr; only the final URL goes to stdout.

require() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'Error: required command not found: %s\n' "$1" >&2
    exit 1
  }
}

require curl

printf '%s\n' 'WARNING: This will capture all visible screens and upload the image publicly.' >&2
printf 'Continue? [y/N] ' >&2
IFS= read -r answer
case "$answer" in
  y|Y|yes|YES|Yes) ;;
  *) printf '%s\n' 'Cancelled.' >&2; exit 1 ;;
esac

tmp_base="$(mktemp "${TMPDIR:-/tmp}/screenshot-upload.XXXXXX")"
rm -f -- "$tmp_base"
shot="${tmp_base}.png"
cleanup() { rm -f -- "$shot" "${tmp_base}.jpg"; }
trap cleanup EXIT INT TERM HUP

capture_windows() {
  local windows_path="$1"
  powershell.exe -NoLogo -NoProfile -NonInteractive -Command \
    '& {
      param([string]$Path)
      Add-Type -AssemblyName System.Windows.Forms
      Add-Type -AssemblyName System.Drawing
      $bounds = [System.Windows.Forms.SystemInformation]::VirtualScreen
      $bitmap = New-Object System.Drawing.Bitmap $bounds.Width, $bounds.Height
      $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
      try {
        $graphics.CopyFromScreen($bounds.Left, $bounds.Top, 0, 0, $bitmap.Size)
        $bitmap.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
      }
      finally {
        $graphics.Dispose()
        $bitmap.Dispose()
      }
    }' "$windows_path"
}

capture_screenshot() {
  local os
  os="$(uname -s)"

  case "$os" in
    Darwin)
      command -v screencapture >/dev/null 2>&1 || {
        printf '%s\n' 'Error: macOS screencapture was not found.' >&2
        return 1
      }
      screencapture -x "$shot"
      ;;

    Linux)
      # WSL: capture the Windows desktop through PowerShell.
      if grep -qi microsoft /proc/version 2>/dev/null && command -v powershell.exe >/dev/null 2>&1; then
        command -v wslpath >/dev/null 2>&1 || {
          printf '%s\n' 'Error: wslpath is required under WSL.' >&2
          return 1
        }
        capture_windows "$(wslpath -w "$shot")"
      elif [[ -n "${WAYLAND_DISPLAY:-}" ]] && command -v grim >/dev/null 2>&1; then
        grim "$shot"
      elif command -v gnome-screenshot >/dev/null 2>&1; then
        gnome-screenshot -f "$shot"
      elif command -v spectacle >/dev/null 2>&1; then
        spectacle -b -n -o "$shot"
      elif command -v maim >/dev/null 2>&1; then
        maim "$shot"
      elif command -v scrot >/dev/null 2>&1; then
        scrot "$shot"
      elif command -v import >/dev/null 2>&1; then
        import -window root "$shot"
      else
        cat >&2 <<'MSG'
Error: no supported screenshot tool was found.
Install one of: grim, gnome-screenshot, spectacle, maim, scrot, or ImageMagick.
MSG
        return 1
      fi
      ;;

    MINGW*|MSYS*|CYGWIN*)
      command -v powershell.exe >/dev/null 2>&1 || {
        printf '%s\n' 'Error: powershell.exe was not found.' >&2
        return 1
      }
      if command -v cygpath >/dev/null 2>&1; then
        capture_windows "$(cygpath -w "$shot")"
      else
        capture_windows "$shot"
      fi
      ;;

    *)
      printf 'Error: unsupported operating system: %s\n' "$os" >&2
      return 1
      ;;
  esac

  [[ -s "$shot" ]] || {
    printf '%s\n' 'Error: screenshot command did not create an image.' >&2
    return 1
  }
}

# Convert unusually large PNGs to JPEG when a local converter is available.
# This improves the chance of fitting img402.dev's 10 MB free-upload limit.
reduce_if_large() {
  local bytes jpg
  bytes="$(wc -c < "$shot" | tr -d '[:space:]')"
  (( bytes <= 9000000 )) && return 0

  jpg="${tmp_base}.jpg"
  if command -v magick >/dev/null 2>&1; then
    magick "$shot" -quality 85 "$jpg"
  elif command -v convert >/dev/null 2>&1; then
    convert "$shot" -quality 85 "$jpg"
  elif [[ "$(uname -s)" == Darwin ]] && command -v sips >/dev/null 2>&1; then
    sips -s format jpeg -s formatOptions 85 "$shot" --out "$jpg" >/dev/null
  else
    return 0
  fi

  if [[ -s "$jpg" ]]; then
    rm -f -- "$shot"
    shot="$jpg"
  fi
}

extract_first_url() {
  # Every supported endpoint either returns a plain URL or JSON containing one.
  # Extract the first HTTPS URL without requiring jq or another JSON parser.
  grep -Eo 'https://[^"[:space:]<>\\]+' | head -n 1
}

curl_common=(
  --fail
  --silent
  --show-error
  --location
  --connect-timeout 8
  --max-time 90
)

upload_img402() {
  curl "${curl_common[@]}" -F "image=@${shot}" https://img402.dev/api/free
}

upload_catbox() {
  curl "${curl_common[@]}" \
    -F 'reqtype=fileupload' \
    -F "fileToUpload=@${shot}" \
    https://catbox.moe/user/api.php
}

upload_litterbox() {
  curl "${curl_common[@]}" \
    -F 'reqtype=fileupload' \
    -F 'time=72h' \
    -F "fileToUpload=@${shot}" \
    https://litterbox.catbox.moe/resources/internals/api.php
}

upload_x0() {
  curl "${curl_common[@]}" -F "file=@${shot}" https://x0.at/
}

upload_temp_sh() {
  curl "${curl_common[@]}" -F "file=@${shot}" https://temp.sh/upload
}

upload_file_io() {
  curl "${curl_common[@]}" \
    -F "file=@${shot}" \
    -F 'expires=1d' \
    -F 'maxDownloads=100' \
    -F 'autoDelete=false' \
    https://file.io/
}

capture_screenshot
reduce_if_large

services=(img402 catbox litterbox x0 temp_sh file_io)
for service in "${services[@]}"; do
  printf 'Trying %s...\n' "$service" >&2

  response=""
  if response="$("upload_${service}" 2>/dev/null)"; then
    url="$(printf '%s' "$response" | extract_first_url || true)"
    if [[ "$url" == https://* ]]; then
      printf '%s\n' "$url"
      exit 0
    fi
  fi

done

printf '%s\n' 'Error: every upload service failed or returned an invalid response.' >&2
exit 1
