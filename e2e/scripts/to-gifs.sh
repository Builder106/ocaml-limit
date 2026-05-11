#!/usr/bin/env bash
# Convert recorded demo mp4s to GIFs for README embedding.
#
# Per the project's E2E convention: keep fps low (8–12), width ≤ 960px
# so each file stays under GitHub's 10 MB inline-image limit.
#
# Outputs land in ../assets/demos/<feature>-<scenario>.gif so they
# match the paths the README's <details> sections expect.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$SCRIPT_DIR/../demo-output"
DST_DIR="$SCRIPT_DIR/../../assets/demos"

if [[ ! -d "$SRC_DIR" ]]; then
  echo "no recordings found at $SRC_DIR — run \`npm run demo\` first" >&2
  exit 1
fi

mkdir -p "$DST_DIR"

shopt -s nullglob
count=0
for mp4 in "$SRC_DIR"/*.mp4; do
  base="$(basename "$mp4" .mp4)"
  out="$DST_DIR/$base.gif"
  echo "→ $base.gif"
  # Two-pass palette generation gives much better color than a
  # single-pass conversion (the default 256-color quantization on
  # the green/red dashboard is rough otherwise).
  #
  # Note: avoid `mktemp -t demo-palette.XXXXXX.png` — on macOS the
  # random suffix lands AFTER the .png extension, leaving ffmpeg
  # unable to infer the output format. A deterministic name keyed
  # by PID + filename is fine since this script is single-threaded.
  palette="/tmp/demo-palette-$$-$count.png"
  trap 'rm -f "$palette"' EXIT
  # `-update 1` is required by ffmpeg >= 7 when writing a single
  # PNG (palette). Without it, ffmpeg complains the filename has no
  # `%03d`-style image-sequence pattern and bails with exit code != 0
  # — which, combined with the script's set -e, used to kill the
  # whole conversion silently after the first file.
  ffmpeg -y -i "$mp4" \
    -vf "fps=10,scale=960:-1:flags=lanczos,palettegen" \
    -update 1 -frames:v 1 \
    "$palette" >/dev/null 2>&1
  ffmpeg -y -i "$mp4" -i "$palette" \
    -lavfi "fps=10,scale=960:-1:flags=lanczos[x];[x][1:v]paletteuse" \
    "$out" >/dev/null 2>&1
  rm -f "$palette"
  trap - EXIT
  # `((count++))` returns exit code 1 when the pre-increment value is
  # 0, which `set -e` then treats as a fatal error and kills the
  # script after the first file. Use the arithmetic substitution form
  # instead — it always returns 0.
  count=$((count + 1))
done

if (( count == 0 )); then
  echo "no mp4s found in $SRC_DIR" >&2
  exit 1
fi

echo ""
echo "wrote $count gif(s) to $DST_DIR"
