#!/bin/bash
# Watch ImmiBridge SSH while it backs up. If its memory passes the limit, record
# which files it has open and what it is doing, then quit it before macOS freezes.
#   usage: memory-watchdog.sh [limit-MB] [hours]
# Written 2026-11-17 after a run grew to 38 GB and froze the Mac.
LIMIT_MB="${1:-6144}"; HOURS="${2:-8}"
OUT="$HOME/Library/Logs/immibridge-watchdog"; mkdir -p "$OUT"
LOG="$OUT/watchdog.log"
end=$(( $(date +%s) + HOURS*3600 ))
echo "$(date '+%F %T') watching, limit ${LIMIT_MB} MB, for ${HOURS} h" >> "$LOG"
last=0
while [ "$(date +%s)" -lt "$end" ]; do
  pid=$(pgrep -x "ImmiBridge SSH" | head -1)
  if [ -n "$pid" ]; then
    mb=$(footprint -p "$pid" 2>/dev/null | sed -n 's/.*Footprint: \([0-9.]*\) \([KMG]B\).*/\1 \2/p' | awk '{v=$1; if($2=="GB")v*=1024; if($2=="KB")v/=1024; printf "%d", v}')
    mb=${mb:-0}
    # a line every time it grows by 500 MB, so the climb is visible afterwards
    if [ $(( mb - last )) -ge 500 ] || [ $(( last - mb )) -ge 500 ]; then
      echo "$(date '+%F %T') pid $pid ${mb} MB" >> "$LOG"; last=$mb
    fi
    if [ "$mb" -ge "$LIMIT_MB" ]; then
      ts=$(date +%Y%m%d-%H%M%S)
      echo "$(date '+%F %T') OVER LIMIT at ${mb} MB, capturing and quitting" >> "$LOG"
      lsof -p "$pid" > "$OUT/open-files-$ts.txt" 2>&1
      sample "$pid" 3 -file "$OUT/sample-$ts.txt" >/dev/null 2>&1
      footprint -p "$pid" > "$OUT/footprint-$ts.txt" 2>&1
      kill "$pid"; sleep 10; kill -9 "$pid" 2>/dev/null
      echo "$(date '+%F %T') ImmiBridge quit. Details in $OUT/*-$ts.txt" >> "$LOG"
      osascript -e 'display notification "Stopped it at '"$mb"' MB before the Mac froze." with title "ImmiBridge watchdog"' 2>/dev/null
      exit 0
    fi
  fi
  sleep 5
done
echo "$(date '+%F %T') time up, ImmiBridge stayed under the limit" >> "$LOG"
