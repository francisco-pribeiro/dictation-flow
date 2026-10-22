#!/usr/bin/env bash
# Generates 16 kHz mono WAV fixtures with matching .txt references.
set -euo pipefail
cd "$(dirname "$0")"

gen() { # name voice text
  say -v "$2" -o "$1.aiff" "$3"
  ffmpeg -y -loglevel error -i "$1.aiff" -ar 16000 -ac 1 "$1.wav"
  rm "$1.aiff"
  printf '%s\n' "$3" > "$1.txt"
}

gen pt_facto Joana "O facto é que a equipa precisa do contacto antes de sexta-feira."
gen pt_correcao Joana "Marca a reunião para terça, não, quarta às dez da manhã."
gen en_lunch Samantha "Can we move lunch to Thursday at one?"
ffmpeg -y -loglevel error -f lavfi -i anullsrc=r=16000:cl=mono -t 2 -ar 16000 -ac 1 silence.wav
printf '\n' > silence.txt
