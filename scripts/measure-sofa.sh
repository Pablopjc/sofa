#!/bin/bash
# Mide cuánta CPU, memoria y energía gasta Sofa mientras la usas.
#
# Funciona con CUALQUIER versión de Sofa (no hace falta compilar nada) y NO
# pide contraseña. Al terminar deja un informe en el Escritorio.
#
#   ./measure-sofa.sh            # mide 20 minutos
#   ./measure-sofa.sh 45         # mide 45 minutos
#   ./measure-sofa.sh 0          # mide hasta que pulses Control-C
#
# Por qué está hecho así:
#   - El muestreo usa `ps`, que cuesta ~0,03 s. `top` cuesta ~0,7 s de CPU por
#     llamada — usarlo en el bucle falsearía la medida — así que solo se llama
#     dos veces, al principio y al final, para los "idle wakeups".
#   - La CPU se calcula por DIFERENCIA del tiempo de CPU acumulado, no con el
#     %CPU de `ps`: ese porcentaje es la media desde que arrancó el proceso,
#     no el consumo del intervalo, y engaña en sesiones largas.
set -uo pipefail

MINUTES="${1:-20}"
INTERVAL=${SOFA_MEASURE_INTERVAL:-10}   # segundos entre muestras

find_pid() { pgrep -x Sofa | head -1; }

PID=$(find_pid)
if [ -z "$PID" ]; then
  echo "✗ Sofa no está abierta. Ábrela y vuelve a ejecutar esto."
  exit 1
fi

INSTANCES=$(pgrep -x Sofa | wc -l | tr -d ' ')
DESKTOP="$HOME/Desktop"
STAMP=$(date "+%Y-%m-%d %H.%M.%S")
CSV="$DESKTOP/Sofa Performance $STAMP.csv"
REPORT="$DESKTOP/Sofa Performance $STAMP.txt"

# Tiempo de CPU acumulado del proceso, en segundos. `ps` lo da como
# [[dd-]hh:]mm:ss.cc, así que hay que convertirlo.
cpu_seconds() {
  local raw
  raw=$(ps -o cputime= -p "$1" 2>/dev/null | tr -d ' ')
  [ -z "$raw" ] && return 1
  echo "$raw" | awk -F'[:-]' '{
    if (NF == 4)      print $1*86400 + $2*3600 + $3*60 + $4
    else if (NF == 3) print $1*3600 + $2*60 + $3
    else if (NF == 2) print $1*60 + $2
    else              print $1
  }'
}

rss_mb() { ps -o rss= -p "$1" 2>/dev/null | awk '{printf "%.1f", $1/1024}'; }

idle_wakeups() {
  top -l 1 -pid "$1" -stats idlew 2>/dev/null | tail -1 | tr -dc '0-9'
}

threads() { ps -M -p "$1" 2>/dev/null | tail -n +2 | wc -l | tr -d ' '; }

APP_PATH=$(ps -o comm= -p "$PID" 2>/dev/null | sed 's|/Contents/MacOS/Sofa$||')
VERSION=$(defaults read "$APP_PATH/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "?")

echo "▸ Midiendo Sofa $VERSION (pid $PID)"
[ "$INSTANCES" -gt 1 ] && echo "  ⚠ Hay $INSTANCES copias de Sofa abiertas; se mide solo la primera."
if [ "$MINUTES" = "0" ]; then
  echo "▸ Sin límite de tiempo. Usa la app con normalidad y pulsa Control-C al acabar."
else
  echo "▸ Durante $MINUTES minutos. Usa la app con normalidad (puedes dejarlo de fondo)."
fi
echo "▸ Muestra cada ${INTERVAL}s. Al terminar habrá un informe en el Escritorio."
echo

START_EPOCH=$(date +%s)
START_CPU=$(cpu_seconds "$PID")
START_WAKEUPS=$(idle_wakeups "$PID")
START_RSS=$(rss_mb "$PID")
PREV_CPU="$START_CPU"
PREV_EPOCH="$START_EPOCH"

echo "timestamp,elapsed_s,cpu_percent_interval,cpu_total_s,rss_mb,threads" > "$CSV"

PEAK_CPU=0
PEAK_RSS="$START_RSS"
SAMPLES=0
RESTARTS=0

finish() {
  local END_EPOCH END_CPU END_WAKEUPS END_RSS ELAPSED CPU_USED AVG_CPU WAKE_DELTA WAKE_RATE RSS_GROWTH
  END_EPOCH=$(date +%s)
  END_CPU=$(cpu_seconds "$PID" || echo "$PREV_CPU")
  END_RSS=$(rss_mb "$PID")
  [ -z "$END_RSS" ] && END_RSS="$PEAK_RSS"
  END_WAKEUPS=$(idle_wakeups "$PID")
  ELAPSED=$((END_EPOCH - START_EPOCH))
  [ "$ELAPSED" -lt 1 ] && ELAPSED=1

  CPU_USED=$(awk -v a="$END_CPU" -v b="$START_CPU" 'BEGIN{printf "%.1f", a-b}')
  AVG_CPU=$(awk -v c="$CPU_USED" -v e="$ELAPSED" 'BEGIN{printf "%.2f", 100*c/e}')
  RSS_GROWTH=$(awk -v a="$END_RSS" -v b="$START_RSS" 'BEGIN{printf "%+.1f", a-b}')
  if [ -n "$START_WAKEUPS" ] && [ -n "$END_WAKEUPS" ]; then
    WAKE_DELTA=$((END_WAKEUPS - START_WAKEUPS))
    WAKE_RATE=$(awk -v w="$WAKE_DELTA" -v e="$ELAPSED" 'BEGIN{printf "%.1f", w/e}')
  else
    WAKE_DELTA="?"; WAKE_RATE="?"
  fi

  {
    echo "Sofa — informe de consumo"
    echo "Generado: $(date '+%Y-%m-%d %H:%M:%S %Z')"
    echo "Sofa $VERSION  ($APP_PATH)"
    echo "macOS $(sw_vers -productVersion)  ·  $(sysctl -n hw.model)"
    echo
    echo "Duración medida: $((ELAPSED / 60)) min $((ELAPSED % 60)) s  ·  $SAMPLES muestras"
    [ "$INSTANCES" -gt 1 ] && echo "AVISO: había $INSTANCES copias de Sofa abiertas al empezar."
    [ "$RESTARTS" -gt 0 ] && echo "AVISO: Sofa se cerró/reinició $RESTARTS veces durante la medición."
    echo
    echo "CPU"
    echo "  Consumida en total : ${CPU_USED}s de CPU en ${ELAPSED}s reales"
    echo "  Media              : ${AVG_CPU}% de un núcleo"
    echo "  Pico (intervalo)   : ${PEAK_CPU}%"
    echo
    echo "Memoria (RSS)"
    echo "  Nota: el informe de la app da un numero MENOR (\"footprint\", el de"
    echo "  Monitor de Actividad). No se contradicen: miden cosas distintas."
    echo "  Al empezar         : ${START_RSS} MB"
    echo "  Al terminar        : ${END_RSS} MB  (${RSS_GROWTH} MB)"
    echo "  Pico               : ${PEAK_RSS} MB"
    echo
    echo "Energía"
    echo "  Idle wakeups       : ${WAKE_DELTA} en total  ·  ${WAKE_RATE}/s"
    echo "  (macOS marca una app como consumidora de energía a partir de ~150/s;"
    echo "   por debajo de ~20/s es un consumo tranquilo para una app de barra.)"
    echo
    echo "Cómo leerlo"
    echo "  - Una app de barra de menús en reposo debería estar bien por debajo"
    echo "    del 1% de media. Durante una fiesta sube, porque Sofa consulta al"
    echo "    reproductor varias veces por segundo: eso es lo esperado."
    echo "  - Si la memoria sube y NO vuelve a bajar a lo largo de la sesión,"
    echo "    puede haber una fuga; es el dato más útil de una medición larga."
    echo "  - El detalle muestra a muestra está en el .csv de al lado."
    echo
    echo "Manda ESTE archivo y el .csv a Pablo."
  } > "$REPORT"

  echo
  echo "───────────────────────────────────────────"
  cat "$REPORT" | sed -n '7,25p'
  echo "───────────────────────────────────────────"
  echo "✓ Informe : $REPORT"
  echo "✓ Detalle : $CSV"
  open -R "$REPORT" 2>/dev/null
  exit 0
}
trap finish INT TERM

while true; do
  sleep "$INTERVAL"

  NOW_EPOCH=$(date +%s)
  ELAPSED=$((NOW_EPOCH - START_EPOCH))

  if ! kill -0 "$PID" 2>/dev/null; then
    NEW_PID=$(find_pid)
    if [ -n "$NEW_PID" ]; then
      # Sofa se reinició: seguimos con el proceso nuevo, pero el contador de
      # CPU del anterior no es comparable, así que rebasamos la línea base.
      RESTARTS=$((RESTARTS + 1))
      PID="$NEW_PID"
      START_CPU=$(cpu_seconds "$PID")
      PREV_CPU="$START_CPU"
      START_EPOCH=$NOW_EPOCH
      echo "  ⚠ Sofa se reinició; se reinicia también la línea base."
      continue
    fi
    echo "  ⚠ Sofa se ha cerrado. Cierro la medición."
    finish
  fi

  NOW_CPU=$(cpu_seconds "$PID") || continue
  NOW_RSS=$(rss_mb "$PID")
  NOW_TH=$(threads "$PID")
  DT=$((NOW_EPOCH - PREV_EPOCH))
  [ "$DT" -lt 1 ] && DT=1
  PCT=$(awk -v a="$NOW_CPU" -v b="$PREV_CPU" -v d="$DT" 'BEGIN{printf "%.2f", 100*(a-b)/d}')

  echo "$(date '+%H:%M:%S'),$ELAPSED,$PCT,$NOW_CPU,$NOW_RSS,$NOW_TH" >> "$CSV"
  SAMPLES=$((SAMPLES + 1))
  PEAK_CPU=$(awk -v a="$PCT" -v b="$PEAK_CPU" 'BEGIN{print (a>b)?a:b}')
  PEAK_RSS=$(awk -v a="$NOW_RSS" -v b="$PEAK_RSS" 'BEGIN{print (a>b)?a:b}')

  printf "\r  %s  CPU %5s%%   RAM %6s MB   hilos %2s   (%dm%02ds)   " \
    "$(date '+%H:%M:%S')" "$PCT" "$NOW_RSS" "$NOW_TH" $((ELAPSED / 60)) $((ELAPSED % 60))

  PREV_CPU="$NOW_CPU"
  PREV_EPOCH="$NOW_EPOCH"

  if [ "$MINUTES" != "0" ] && [ "$ELAPSED" -ge $((MINUTES * 60)) ]; then
    finish
  fi
done
