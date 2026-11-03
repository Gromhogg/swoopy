#!/bin/bash
# Turns a downloaded RVC v2 voice (a .pth file, or a .zip with one inside) into a Swoopy voice, in one line:
#
#   curl -fsSL https://raw.githubusercontent.com/Gromhogg/swoopy/main/tools/convert-voice.sh | bash -s -- MODEL.pth
#
# Options after the file: --name NAME (shown in Swoopy; default: the file's name) and
# --pitch high|medium|low|HZ (how high the voice is; asked if left out).
#
# The first time, it downloads uv (a small Python installer), Python 3.11 and the converter's packages (about 0.5 GB
# in all) into ~/Library/Application Support/Pitch Shift/Converter/. Nothing else on the Mac changes, and it never
# needs your password. Delete that folder to remove them. The new voice lands in
# ~/Library/Application Support/Pitch Shift/Voices/ and shows up in Swoopy's voice menu.
# Needs a Mac with Apple silicon (AI voices run only there).
set -euo pipefail

CONVERTER="${PITCH_SHIFT_CONVERTER_HOME:-$HOME/Library/Application Support/Pitch Shift/Converter}"
REF="${PITCH_SHIFT_REF:-main}"  # which version of the converter to download
RAW="https://raw.githubusercontent.com/Gromhogg/swoopy/$REF/tools/voice-converter"
UV_VERSION=0.12.18
UV_SHA256=cf40e0c6a202190ccd9e0406dcfdd5b2d6668a9a5c779b17948963df32aafe5b  # uv-aarch64-apple-darwin.tar.gz

fail() { printf "Can't convert: %s\n" "$*" >&2; exit 1; }

[ "$(uname -s)" = Darwin ] || fail "this converter is for Macs."
[ "$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)" = 1 ] \
  || fail "AI voices need a Mac with Apple silicon (M1 or newer), so there is nothing to convert for on this Mac."

model=""
pitch=""
pass=()
while [ $# -gt 0 ]; do
  case "$1" in
    --pitch) [ $# -ge 2 ] || fail "--pitch needs high, medium, low or a number of Hz"; pitch="$2"; shift 2 ;;
    --name|--voices-dir|--app) [ $# -ge 2 ] || fail "$1 needs a value"; pass+=("$1" "$2"); shift 2 ;;
    -h|--help) sed -n '2,13p' "${BASH_SOURCE[0]:-/dev/null}" 2>/dev/null || true
               echo "usage: convert-voice.sh MODEL.pth [--name NAME] [--pitch high|medium|low|HZ]"; exit 0 ;;
    -*) fail "unknown option $1 (use --name NAME and --pitch high|medium|low|HZ)" ;;
    *) [ -z "$model" ] || fail "give one voice file at a time"; model="$1"; shift ;;
  esac
done
[ -n "$model" ] || fail "give the voice's .pth file after the line, like: ... | bash -s -- ~/Downloads/MyVoice.pth
(Tip: type a space after \"--\", then drag the file onto this Terminal window.)"
[ -f "$model" ] || fail "can't find \"$model\"."

# How high is the voice? (Swoopy moves your voice to this pitch.) Asked on the Terminal when not given.
if [ -z "$pitch" ]; then
  answer=""
  if { exec 3</dev/tty; } 2>/dev/null; then
    printf "How high is this voice?  1 = High (most women's voices)  2 = Medium  3 = Low (most men's voices)  [2]: "
    read -r answer <&3 || true
    exec 3<&-
  fi
  case "$answer" in
    1|h|high|High) pitch=high ;;
    3|l|low|Low) pitch=low ;;
    *) pitch=medium ;;
  esac
fi

mkdir -p "$CONVERTER/bin" "$CONVERTER/app"
export UV_CACHE_DIR="$CONVERTER/cache" UV_PYTHON_INSTALL_DIR="$CONVERTER/python" UV_PYTHON_PREFERENCE=only-managed \
       UV_NO_CONFIG=1 UV_NO_PROGRESS=1 TQDM_DISABLE=1
UV="$CONVERTER/bin/uv"

# 1. uv (checked against its published SHA-256).
if [ ! -x "$UV" ] || [ "$("$UV" --version 2>/dev/null | awk '{print $2}')" != "$UV_VERSION" ]; then
  echo "Getting uv $UV_VERSION (a Python installer)..."
  tmp="$(mktemp -d)"
  curl -fsSL --retry 3 -o "$tmp/uv.tar.gz" \
    "https://github.com/astral-sh/uv/releases/download/$UV_VERSION/uv-aarch64-apple-darwin.tar.gz" || fail "couldn't download uv."
  echo "$UV_SHA256  $tmp/uv.tar.gz" | shasum -a 256 -c --status || { rm -rf "$tmp"; fail "the uv download doesn't match its checksum."; }
  tar -xzf "$tmp/uv.tar.gz" -C "$tmp"
  mv "$tmp/uv-aarch64-apple-darwin/uv" "$UV"
  chmod +x "$UV"
  rm -rf "$tmp"
fi

# 2. The converter itself: next to this script (a copy of the repo), or downloaded.
here=""
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; fi
if [ -n "$here" ] && [ -f "$here/voice-converter/convert_voice.py" ]; then
  cp "$here/voice-converter/convert_voice.py" "$here/voice-converter/requirements.txt" "$CONVERTER/app/"
else
  for f in convert_voice.py requirements.txt; do
    curl -fsSL --retry 3 -o "$CONVERTER/app/$f.part" "$RAW/$f" || fail "couldn't download the converter ($f)."
    mv "$CONVERTER/app/$f.part" "$CONVERTER/app/$f"
  done
fi

# 3. Python 3.11 and the packages, once (again only when requirements.txt changes).
if [ ! -x "$CONVERTER/venv/bin/python" ]; then
  echo "Getting Python 3.11 (once)..."
  "$UV" venv --quiet --python 3.11 "$CONVERTER/venv" || fail "couldn't set up Python."
fi
stamp="$(shasum -a 256 "$CONVERTER/app/requirements.txt" | awk '{print $1}')"
if [ "$(cat "$CONVERTER/venv/.pitch-shift-packages" 2>/dev/null || true)" != "$stamp" ]; then
  echo "Getting the converter's packages (once, about 0.5 GB; a few minutes)..."
  "$UV" pip install --quiet --python "$CONVERTER/venv/bin/python" --require-hashes -r "$CONVERTER/app/requirements.txt" \
    || fail "couldn't install the converter's packages."
  echo "$stamp" > "$CONVERTER/venv/.pitch-shift-packages"
  "$UV" cache clean --quiet >/dev/null 2>&1 || true
fi

# 4. Convert.
"$CONVERTER/venv/bin/python" -I -W ignore "$CONVERTER/app/convert_voice.py" "$model" --pitch "$pitch" ${pass[@]+"${pass[@]}"}
