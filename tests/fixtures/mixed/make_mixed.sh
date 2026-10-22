#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"  # writes mixed PT/EN wavs next to this script (gitignored)
seg() { # out voice text
  say -v "$2" -o "$1.aiff" "$3"; ffmpeg -y -loglevel error -i "$1.aiff" -ar 16000 -ac 1 "$1.s.wav"; rm "$1.aiff"; }
mk() { # name gapms voiceEN  then parts: text...  ; use "PT|text" / "EN|text"
  local name=$1 gap=$2 venv=$3; shift 3
  local list=() i=0 ref=""
  ffmpeg -y -loglevel error -f lavfi -i anullsrc=r=16000:cl=mono -t "$(python3 -c "print($gap/1000)")" gap.wav
  rm -f list.txt
  for p in "$@"; do
    kind=${p%%|*}; txt=${p#*|}; i=$((i+1))
    v=Joana; [ "$kind" = EN ] && v=$venv
    seg "p$i" "$v" "$txt"
    [ "$i" -gt 1 ] && [ "$gap" -gt 0 ] && [ "$kind" != "PT0" ] && echo "file 'gap.wav'" >> list.txt
    echo "file 'p$i.s.wav'" >> list.txt
    ref="$ref $txt"
  done
  ffmpeg -y -loglevel error -f concat -safe 0 -i list.txt -ar 16000 -ac 1 "$name.wav"
  printf '%s\n' "${ref# }" > "$name.txt"; rm -f p*.s.wav list.txt gap.wav
}
S=Samantha; J=Joana
# short, English word at start/middle/end
mk m01_crazy_mid_s 250 $S "PT|Isto está" "EN|crazy" "PT|de verdade."
mk m02_workflow_mid_s 0 $S "PT|Preciso de melhorar o" "EN|workflow" "PT|da equipa."
mk m03_deadline_end_s 250 $S "PT|A entrega é sexta-feira e o" "EN|deadline"
mk m04_feedback_start_s 250 $S "EN|Feedback" "PT|do cliente chegou esta manhã."
mk m05_pipeline_mid_s 0 $S "PT|O pipeline" "PT|está parado desde ontem."
mk m06_meeting_end_s 250 $S "PT|Vou marcar a" "EN|meeting"
mk m07_crazy_no_s 0 $S "PT|Não" "EN|crazy" "PT|no sentido bom."
mk m08_feedback_a_s 250 $S "PT|Dá-me" "EN|feedback" "PT|a sério."
# long (20-30 s), PT-heavy
LONGA="PT|Então ontem estive a falar com o cliente sobre o projeto novo e ele disse que a equipa dele precisa de uma solução rápida para o problema das encomendas, porque neste momento perdem muito tempo a copiar dados de um sítio para o outro."
LONGB="PT|Eu expliquei que podemos ligar o sistema deles ao nosso painel sem mudar nada do que já usam, e que na primeira semana conseguimos mostrar resultados concretos, com menos horas gastas em tarefas repetitivas."
mk m09_crazy_long_mid 250 $S "$LONGA" "PT|Ele achou isto" "EN|crazy" "$LONGB"
mk m10_workflow_long_early 0 $S "PT|Quero rever o" "EN|workflow" "$LONGA" "$LONGB"
mk m11_deadline_long_end 250 $S "$LONGA" "$LONGB" "PT|Mas o prazo é apertado e o" "EN|deadline"
mk m12_meeting_long_mid 0 $S "$LONGA" "PT|Marcámos uma" "EN|meeting" "PT|para segunda-feira de manhã." "$LONGB"
mk m13_feedback_mid_med 250 $S "PT|Falei com o João ontem à tarde e ele deu-me bom" "EN|feedback" "PT|sobre a proposta, só falta acertar o preço e o calendário."
mk m14_pipeline_start_med 0 $S "EN|Pipeline" "PT|de vendas, atualizar até quinta, por favor, e enviar ao Pedro."
# Joana says the English word herself (no voice change)
mk j01_crazy_s 0 $J "PT|Isto está" "EN|crazy" "PT|de verdade, não achas?"
mk j02_workflow_med 0 $J "PT|Precisamos de ajustar o" "EN|workflow" "PT|antes da reunião de sexta com o cliente."
mk j03_deadline_s 0 $J "PT|O" "EN|deadline" "PT|é amanhã."
mk j04_feedback_long 0 $J "$LONGA" "PT|Pedi" "EN|feedback" "$LONGB"
# controls
mk c_pt_s 0 $S "PT|Marca a reunião para quarta às dez da manhã, por favor."
mk c_pt_med 0 $S "PT|O cliente pediu uma proposta nova até ao fim da semana e eu ainda preciso de falar com a equipa."
mk c_pt_long 0 $S "$LONGA" "$LONGB"
mk c_en_s 0 $S "EN|Can we move the meeting to Thursday at ten?"
mk c_en_med 0 $S "EN|The client asked for a new proposal by the end of the week and I still need to talk to the team."
mk c_en_long 0 $S "EN|Yesterday I spoke with the client about the new project and he said his team needs a quick solution for the orders problem, because right now they lose a lot of time copying data from one place to another." "EN|I explained that we can connect their system to our dashboard without changing anything they already use, and that in the first week we can show concrete results, with fewer hours spent on repetitive tasks."
