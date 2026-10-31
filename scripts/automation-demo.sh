#!/bin/bash
# Gera a cena da automação em docs/media/automation (ver App/Sources/AutomationDemo.swift).
# Uso: [FORMAT=9x16] automation-demo.sh [--check]. Com --check, só confere o que já foi gerado.
set -eu
cd "$(dirname "$0")/.."
DD=.build/xcode-debug
MEDIA=docs/media/automation
# 1,7 s: as ondas no meio do colapso.
POSTER=0051

check() {
    bad=0
    for f in "$MEDIA"/*.mp4 "$MEDIA"/*.webm; do
        info=$(ffprobe -v error -count_frames -select_streams v -show_entries stream=width,height,r_frame_rate,nb_read_frames -of csv=p=0 "$f")
        audio=$(ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 "$f")
        d=$(mktemp -d)
        ffmpeg -loglevel error -i "$f" -vf "select='eq(n,0)+eq(n,1)+eq(n,209)'" -fps_mode passthrough "$d/%d.png"
        ssim() { ffmpeg -hide_banner -i "$1" -i "$2" -lavfi ssim -f null - 2>&1 | sed -nE 's/.*All:([0-9.]+).*/\1/p'; }
        start=$(ssim "$d/1.png" "$d/2.png"); seam=$(ssim "$d/3.png" "$d/1.png")
        rm -rf "$d"
        printf '%s %s KB %s audio=[%s] 0→1=%s 209→0=%s\n' "$(basename "$f")" "$(($(stat -f%z "$f") / 1024))" "$info" "$audio" "$start" "$seam"
        # Com movimento desde o início, e a emenda parecida com um passo comum. A margem cobre o quadro-chave do início.
        case "$info" in *,30/1,210) ;; *) echo "  quadros ou fps errados: $f"; bad=1 ;; esac
        python3 -c "import sys; s,e=float('$start'),float('$seam'); sys.exit(0 if s<1 and e>=s-0.005 else 1)" || { echo "  salto ou quadro parado: $f"; bad=1; }
    done
    return $bad
}

if [ "${1:-}" = --check ]; then check; exit; fi

OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT
xcodegen generate --quiet
xcodebuild -project Quietbar.xcodeproj -scheme Quietbar -configuration Debug -derivedDataPath "$DD" build -quiet
mkdir -p "$MEDIA"
for lang in en pt; do
    locale=$lang; [ "$lang" = pt ] && locale=pt-BR
    "$DD/Build/Products/Debug/Quietbar.app/Contents/MacOS/Quietbar" --automation-demo "$OUT/$lang" ${FORMAT:+--demo-format "$FORMAT"} -AppleAccentColor 4 -AppleLanguages "($locale)" > /dev/null
    for dir in "$OUT/$lang"/*; do
        name="automation-$(basename "$dir")-$lang"
        color=(-vf "scale=out_color_matrix=bt709:out_range=tv,format=yuv420p" -colorspace bt709 -color_primaries bt709 -color_trc bt709)
        ffmpeg -y -loglevel error -framerate 30 -i "$dir/%04d.png" -an "${color[@]}" \
            -c:v libx264 -preset veryslow -crf "${CRF:-21}" -movflags +faststart "$MEDIA/$name.mp4"
        ffmpeg -y -loglevel error -framerate 30 -i "$dir/%04d.png" -an "${color[@]}" \
            -c:v libvpx-vp9 -crf "${VP9_CRF:-31}" -b:v 0 -row-mt 1 -deadline good -cpu-used 2 "$MEDIA/$name.webm"
        cp "$dir/$POSTER.png" "$MEDIA/$name.png"
        # O GitHub não toca <video> de um arquivo do repositório: o README usa este GIF.
        case "$name" in *16x10*)
            ffmpeg -y -loglevel error -framerate 30 -i "$dir/%04d.png" \
                -vf "fps=15,scale=720:-1:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff:max_colors=200[p];[b][p]paletteuse=dither=bayer:bayer_scale=3:diff_mode=rectangle" \
                "$MEDIA/$name.gif" ;;
        esac
        rm -rf "$dir" # cada variante tem cerca de 400 MB de quadros
        echo "$name"
    done
done
check
du -sh "$MEDIA"
