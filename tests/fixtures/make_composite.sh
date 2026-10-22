#!/usr/bin/env bash
# Builds composite_pt25.wav (~25 s dictation with realistic pauses, -50 dBFS noise floor),
# composite_pt25_tail.wav (same + 700 ms pause before "release"), a .txt reference of the expected
# CLEANED text and a .cuts.json with the pause windows (expect_cut=true: a chunker must cut inside it).
# Pauses: 150-300 ms inside sentences (never cut), 400 ms borderline (not cut), 600-900 ms between sentences (cut).
set -euo pipefail
cd "$(dirname "$0")"
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT

piece() { # file voice text : TTS, 16 kHz mono, leading/trailing silence trimmed so pauses are exact
  say -r 200 -v "$2" -o "$W/$1.aiff" "$3"
  ffmpeg -y -loglevel error -i "$W/$1.aiff" -ar 16000 -ac 1 \
    -af "silenceremove=start_periods=1:start_threshold=-50dB,areverse,silenceremove=start_periods=1:start_threshold=-50dB,areverse" "$W/$1.wav"
}
gap() { # file ms
  ffmpeg -y -loglevel error -f lavfi -i "anullsrc=r=16000:cl=mono" -t "$(awk "BEGIN{print $2/1000}")" -ar 16000 -ac 1 "$W/$1.wav"
}

# name voice text ; gaps: name ms kind expect_cut
piece a1 Joana "Ontem o servidor ficou crazy na migração"
piece a2 Joana "e tivemos de reiniciar tudo."
piece b1 Joana "Depois revi o workflow com a Marta"
piece b2 Joana "e acertámos os prazos."
piece c1 Samantha "Then I told the client the new version will be ready"
piece c2 Samantha "by the end of the month."
piece d1 Joana "Marca a reunião para terça, não, quarta às dez"
piece d2 Joana "na sala grande."
piece e1 Joana "Envia o orçamento ao cliente na sexta."
piece e2 Joana "Não, enviamos na segunda."
piece f1 Joana "O fato é que o contato do time"
piece f2 Joana "precisa de acesso ao registro."

# sequence: piece | gap:ms:kind:expect_cut
SEQ="a1 gap:250:inner:0 a2 gap:700:between:1 b1 gap:150:inner:0 b2 gap:850:between:1 c1 gap:300:inner:0 c2 gap:600:between:1 \
d1 gap:200:inner:0 d2 gap:900:between:1 e1 gap:650:between:1 e2 gap:750:between:1 f1 gap:400:borderline:0 f2"
: > "$W/list.txt"; : > "$W/seq.txt"; i=0
for s in $SEQ; do
  if [[ $s == gap:* ]]; then
    IFS=: read -r _ ms kind cut <<<"$s"; i=$((i+1)); gap "g$i" "$ms"
    echo "file '$W/g$i.wav'" >> "$W/list.txt"; echo "gap $ms $kind $cut g$i" >> "$W/seq.txt"
  else
    echo "file '$W/$s.wav'" >> "$W/list.txt"; echo "piece 0 - 0 $s" >> "$W/seq.txt"
  fi
done
ffmpeg -y -loglevel error -f concat -safe 0 -i "$W/list.txt" -ar 16000 -ac 1 "$W/speech.wav"
gap tail 700
echo "file '$W/speech.wav'" > "$W/list2.txt"; echo "file '$W/tail.wav'" >> "$W/list2.txt"
ffmpeg -y -loglevel error -f concat -safe 0 -i "$W/list2.txt" -ar 16000 -ac 1 "$W/speech_tail.wav"

# -50 dBFS (RMS) pink noise floor under everything
mix() { ffmpeg -y -loglevel error -i "$1" -f lavfi -i "anoisesrc=r=16000:c=pink:a=0.0095:seed=7" \
  -filter_complex "[0][1]amix=inputs=2:duration=first:normalize=0" -ar 16000 -ac 1 -c:a pcm_s16le "$2"; }
mix "$W/speech.wav" composite_pt25.wav
mix "$W/speech_tail.wav" composite_pt25_tail.wav

python3 - "$W" <<'PY'
import json, sys, wave
w = sys.argv[1]
t = 0.0; pauses = []
for line in open(f"{w}/seq.txt"):
    kind, ms, k, cut, name = line.split()
    with wave.open(f"{w}/{name}.wav") as f: d = f.getnframes() / f.getframerate()
    if kind == "gap":
        pauses.append({"start": round(t, 3), "end": round(t + d, 3), "ms": int(ms), "kind": k, "expect_cut": cut == "1"})
    t += d
json.dump({"duration_s": round(t, 3), "tail_pause_ms": 700, "pauses": pauses}, open("composite_pt25.cuts.json", "w"), indent=1)
print("speech+pauses", round(t, 2), "s")
PY
cat > composite_pt25.txt <<'TXT'
Ontem o servidor ficou crazy na migração e tivemos de reiniciar tudo. Depois revi o workflow com a Marta e acertámos os prazos. Then I told the client the new version will be ready by the end of the month. Marca a reunião para quarta às dez na sala grande. Envia o orçamento ao cliente na segunda. O facto é que o contacto da equipa precisa de acesso ao registo.
TXT
cp composite_pt25.txt composite_pt25_tail.txt
ffprobe -v error -show_entries format=duration -of csv=p=0 composite_pt25.wav
