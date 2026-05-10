#!/bin/sh
# hdd-io-daemon.sh
# HDD I/O Activity Daemon fuer QNAP NAS
#
# Zwei-Tier Logging:
#   TIER-1 (tmpfs/RAM): /tmp/hdd-io-daemon.log       -- kein HDD-Schreibzugriff
#   TIER-2 (SSD):       /share/CACHEDEV2_DATA/log/hdd-io-daemon-critical.log
#                       nur WARN/CRIT-Eintraege, taeglich rotiert um 05:30
#
# Usage:
#   sh hdd-io-daemon.sh start     -- Daemon starten
#   sh hdd-io-daemon.sh stop      -- Daemon stoppen
#   sh hdd-io-daemon.sh status    -- Status anzeigen
#   sh hdd-io-daemon.sh rotate    -- Logrotate manuell ausloesen (SIGHUP-Aequivalent)
#   sh hdd-io-daemon.sh logcheck  -- Analysiert bestehendes Logrotate-Setup
#   sh hdd-io-daemon.sh install   -- Autostart + Cron einrichten
#
# License: AGPLv3 - https://www.gnu.org/licenses/agpl-3.0.html
# Copyright (c) 2026 GrEEV.com KG

# ── Konfiguration ──────────────────────────────────────────────────────────────
INTERVAL="${INTERVAL:-10}"                          # Sekunden zwischen Snapshots
LOG_RAM="/tmp/hdd-io-daemon.log"                    # Tier-1: tmpfs, kein HDD-Touch
LOG_SSD="/share/CACHEDEV2_DATA/log/hdd-io-daemon-critical.log"  # Tier-2: nur WARN/CRIT
LOG_SSD_PREV="${LOG_SSD}.prev"                      # Rotiertes Archiv
LOG_RAM_MAX_KB="${LOG_RAM_MAX_KB:-4096}"            # RAM-Log Limit (4MB default)
PIDFILE="/tmp/hdd-io-daemon.pid"
HDD_MOUNTS="/share/CACHEDEV1_DATA /share/CACHEDEV3_DATA /share/CE_CACHEDEV4_DATA /share/CACHEDEV5_DATA /share/CACHEDEV6_DATA /share/CACHEDEV7_DATA /share/CACHEDEV8_DATA"
CMD="${1:-}"

# ── Hilfsfunktionen ──────────────────────────────────────────────────────────────
ts()    { date '+%Y-%m-%d %H:%M:%S'; }

# Schreibt in RAM-Log (immer) und bei WARN/CRIT zusaetzlich auf SSD
log() {
  LEVEL="$1"; shift; MSG="$*"
  LINE="$(ts) [$LEVEL] $MSG"
  printf '%s\n' "$LINE" >> "$LOG_RAM"

  # Tier-2: WARN und CRIT auch auf SSD
  case "$LEVEL" in
    WARN|CRIT)
      mkdir -p "$(dirname $LOG_SSD)" 2>/dev/null
      printf '%s\n' "$LINE" >> "$LOG_SSD"
      ;;
  esac

  # RAM-Log Groesse begrenzen (aelteste Haelfte verwerfen)
  LOG_KB=$(du -k "$LOG_RAM" 2>/dev/null | awk '{print $1}')
  if [ "${LOG_KB:-0}" -gt "$LOG_RAM_MAX_KB" ]; then
    LINES=$(wc -l < "$LOG_RAM")
    HALF=$((LINES / 2))
    TMP="${LOG_RAM}.tmp"
    tail -n "$HALF" "$LOG_RAM" > "$TMP" && mv "$TMP" "$LOG_RAM"
    log INFO "RAM-Log auf ${HALF} Zeilen gekuerzt (war ${LINES})"
  fi
}

# HDDs aus /sys/block ermitteln
get_hdd_devs() {
  for dev in /sys/block/sd*; do
    [ -e "$dev" ] || continue
    ROT=1
    [ -f "$dev/queue/rotational" ] && ROT=$(cat "$dev/queue/rotational")
    SIZE=0
    [ -f "$dev/size" ] && SIZE=$(cat "$dev/size")
    if [ "$ROT" = "1" ] && [ "$SIZE" -gt 0 ]; then
      basename "$dev"
    fi
  done
}

# diskstats-Snapshot fuer alle HDDs
snap() {
  for d in $(get_hdd_devs); do
    grep " $d " /proc/diskstats 2>/dev/null | awk '{print $3, $6, $10}'
  done
}

# Prozesse mit offenen Files auf HDD-Mounts
hdd_procs() {
  for mnt in $HDD_MOUNTS; do
    [ -d "$mnt" ] || continue
    PROCS=$(fuser "$mnt" 2>/dev/null | tr ' ' '\n' | while read -r pid; do
      [ -n "$pid" ] || continue
      PNAME=$(cat "/proc/$pid/comm" 2>/dev/null || echo "pid$pid")
      printf "%s(%s) " "$PNAME" "$pid"
    done)
    if [ -n "$PROCS" ]; then
      printf "%s: %s" "$(basename $mnt)" "$PROCS"
    fi
  done
}

# ── Logrotate ──────────────────────────────────────────────────────────────────
do_rotate() {
  # SSD-Log rotieren: .log -> .log.prev (ueberschreiben), neue leere Datei
  if [ -f "$LOG_SSD" ]; then
    mv "$LOG_SSD" "$LOG_SSD_PREV"
    touch "$LOG_SSD"
    log INFO "SSD-Log rotiert -> $(basename $LOG_SSD_PREV)"
    printf 'Rotate: %s -> %s\n' "$LOG_SSD" "$LOG_SSD_PREV"
  else
    printf 'Kein SSD-Log vorhanden zum Rotieren.\n'
  fi
  # RAM-Log: einfach leeren (tmpfs, kein Platzbedarf)
  > "$LOG_RAM" 2>/dev/null
  printf 'RAM-Log geleert.\n'
}

# ── Logcheck: analysiert bestehendes Logrotate-Setup ───────────────────────
do_logcheck() {
  printf '\n'
  printf '%s\n' "==================================================="
  printf '%s\n' " Logrotate-Analyse"
  printf '%s\n' "==================================================="

  # 1. Ist logrotate installiert?
  printf '\n[1] logrotate\n'
  if command -v logrotate >/dev/null 2>&1; then
    printf '[ OK ] logrotate verfuegbar: %s\n' "$(logrotate --version 2>&1 | head -1)"
  else
    printf '[WARN] logrotate nicht gefunden\n'
    printf '[INFO] QNAP nutzt eigenes Log-Management (QTS Log Center)\n'
  fi

  # 2. Wo liegen System-Logs?
  printf '\n[2] System-Log-Pfade und ihre Storage-Tier\n'
  for logpath in /var/log /tmp /run /share/CACHEDEV1_DATA /share/CACHEDEV2_DATA; do
    [ -d "$logpath" ] || continue
    # tmpfs-Check
    FSTYPE=$(df -T "$logpath" 2>/dev/null | tail -1 | awk '{print $2}')
    case "$FSTYPE" in
      tmpfs|ramfs) TIER="RAM (kein HDD-Touch)" ;;
      *)
        # RAID-Check via slaves
        DEV=$(df "$logpath" 2>/dev/null | tail -1 | awk '{print $1}')
        DEVN=$(basename "$DEV")
        MDBASE=$(echo "$DEVN" | sed 's/p[0-9]*$//' | grep '^md')
        TIER="unbekannt"
        if [ -n "$MDBASE" ] && [ -d "/sys/block/$MDBASE/slaves" ]; then
          for slave in /sys/block/$MDBASE/slaves/*; do
            [ -e "$slave" ] || continue
            SLB=$(basename "$slave" | sed 's/[0-9]*$//')
            [ -f "/sys/block/$SLB/queue/rotational" ] || continue
            ROT=$(cat "/sys/block/$SLB/queue/rotational")
            [ "$ROT" = "1" ] && TIER="HDD (RAID) -- STAY-AWAKE!" && break
            TIER="SSD"
          done
        fi
        ;;
    esac
    printf '  %-40s %s\n' "$logpath" "$TIER"
  done

  # 3. QNAP-eigene Logs auf HDD?
  printf '\n[3] QNAP-Dienste die auf HDD loggen\n'
  for f in \
    /share/CACHEDEV1_DATA/.qpkg/MediaSignPlayer/CodexPackExt/var/log \
    /var/log/qulog \
    /share/CACHEDEV1_DATA/.qpkg/container-station \
    /mnt/ext
  do
    [ -e "$f" ] || continue
    printf '[WARN] HDD-Log-Pfad aktiv: %s\n' "$f"
  done

  # 4. /mnt/ext fast voll?
  printf '\n[4] /mnt/ext (QTS System-Partition)\n'
  EXT_USE=$(df /mnt/ext 2>/dev/null | tail -1 | awk '{print $5}' | tr -d '%')
  if [ -n "$EXT_USE" ]; then
    if [ "$EXT_USE" -gt 85 ]; then
      printf '[WARN] /mnt/ext zu %s%% voll -- Logrotate dringend empfohlen\n' "$EXT_USE"
    else
      printf '[ OK ] /mnt/ext zu %s%% genutzt\n' "$EXT_USE"
    fi
  fi

  # 5. Unser eigenes Log
  printf '\n[5] Daemon-Logs\n'
  if [ -f "$LOG_RAM" ]; then
    SIZE=$(du -k "$LOG_RAM" | awk '{print $1}')
    printf '[ OK ] RAM-Log: %s (%s KB)\n' "$LOG_RAM" "$SIZE"
  else
    printf '[INFO] RAM-Log noch nicht vorhanden (Daemon noch nicht gestartet)\n'
  fi
  if [ -f "$LOG_SSD" ]; then
    SIZE=$(du -k "$LOG_SSD" | awk '{print $1}')
    printf '[ OK ] SSD-Log: %s (%s KB)\n' "$LOG_SSD" "$SIZE"
  else
    printf '[INFO] SSD-Log noch nicht vorhanden\n'
  fi

  # 6. Empfehlung
  printf '\n[6] Empfehlung fuer dieses NAS\n'
  printf '[REC] RAM-Log (/tmp):              alle Ereignisse, max 4MB, kein HDD-Touch\n'
  printf '[REC] SSD-Log (CACHEDEV2_DATA):    nur WARN/CRIT, taeglich rotiert\n'
  printf '[REC] HDD-Logs (CACHEDEV1_DATA):   vermeiden -- verhindern Sleep\n'
  printf '[REC] Cron-Wakeup 05:30:           kontrolliert HDD aufwecken statt zufaellig\n'
  printf '%s\n' "==================================================="
  printf '\n'
}

# ── Install: Autostart + Cron ────────────────────────────────────────────────────
do_install() {
  SCRIPT=$(readlink -f "$0")
  printf '\n'
  printf '%s\n' "==================================================="
  printf '%s\n' " Install: Autostart + Cron"
  printf '%s\n' "==================================================="

  # 1. Cron: Daemon-Start beim Booten (nach 60s warten bis Mounts da sind)
  CRON_START="@reboot sleep 60 && sh $SCRIPT start"
  # 2. Cron: Logrotate taeglich 05:30
  CRON_ROTATE="30 5 * * * sh $SCRIPT rotate"
  # 3. Cron: Kontrollierter HDD-Wakeup 05:30 (touch auf HDD-Mount weckt RAID auf)
  CRON_WAKEUP="30 5 * * * ls /share/CACHEDEV1_DATA/ > /dev/null 2>&1"

  # Bestehende Crontab laden, Eintraege hinzufuegen falls nicht vorhanden
  TMPCRN="/tmp/crontab_tmp_$$"
  crontab -l 2>/dev/null > "$TMPCRN"

  CHANGED=0
  for entry in "$CRON_START" "$CRON_ROTATE" "$CRON_WAKEUP"; do
    KEY=$(printf '%s' "$entry" | awk '{print $NF}')
    if ! grep -qF "$KEY" "$TMPCRN" 2>/dev/null; then
      printf '%s\n' "$entry" >> "$TMPCRN"
      printf '[ OK ] Cron hinzugefuegt: %s\n' "$entry"
      CHANGED=1
    else
      printf '[SKIP] Bereits vorhanden: %s\n' "$entry"
    fi
  done

  if [ "$CHANGED" -eq 1 ]; then
    crontab "$TMPCRN"
    printf '[ OK ] Crontab aktualisiert.\n'
  fi
  rm -f "$TMPCRN"

  # QNAP autorun.sh (wird nach jedem QTS-Start ausgefuehrt)
  AUTORUN="/etc/config/autorun.sh"
  if [ -f "$AUTORUN" ]; then
    if ! grep -qF "hdd-io-daemon" "$AUTORUN"; then
      printf '\nsleep 60 && sh %s start\n' "$SCRIPT" >> "$AUTORUN"
      printf '[ OK ] autorun.sh ergaenzt: %s\n' "$AUTORUN"
    else
      printf '[SKIP] autorun.sh bereits konfiguriert.\n'
    fi
  else
    printf '#!/bin/sh\nsleep 60 && sh %s start\n' "$SCRIPT" > "$AUTORUN"
    chmod +x "$AUTORUN"
    printf '[ OK ] autorun.sh erstellt: %s\n' "$AUTORUN"
  fi

  printf '\n'
  printf '[INFO] Cron 05:30 Ablauf:\n'
  printf '       1. ls CACHEDEV1_DATA  -> HDD-RAID wacht kontrolliert auf\n'
  printf '       2. rotate             -> RAM-Log leeren, SSD-Log rotieren\n'
  printf '       HDD ist dann schon wach fuer den Tag -- kein zufaelliges Aufwachen\n'
  printf '%s\n' "==================================================="
  printf '\n'
}

# ── Daemon-Loop ─────────────────────────────────────────────────────────────────
run_daemon() {
  log INFO "Daemon gestartet (PID $$, Intervall ${INTERVAL}s)"
  log INFO "Tier-1 RAM-Log : $LOG_RAM (max ${LOG_RAM_MAX_KB}KB)"
  log INFO "Tier-2 SSD-Log : $LOG_SSD (nur WARN/CRIT)"
  log INFO "HDD-Mounts     : $HDD_MOUNTS"

  PREV=$(snap)
  IDLE_STREAK=0

  while true; do
    sleep "$INTERVAL"
    CURR=$(snap)
    ACTIVE=""

    for d in $(get_hdd_devs); do
      PREV_RW=$(printf '%s' "$PREV" | grep "^$d " | awk '{print $2+$3}')
      CURR_RW=$(printf '%s' "$CURR" | grep "^$d " | awk '{print $2+$3}')
      PREV_RW=${PREV_RW:-0}; CURR_RW=${CURR_RW:-0}
      DELTA=$(( CURR_RW - PREV_RW ))
      [ "$DELTA" -gt 0 ] && ACTIVE="$ACTIVE $d(+${DELTA}ops)"
    done

    if [ -n "$ACTIVE" ]; then
      IDLE_STREAK=0
      PROCS=$(hdd_procs)
      if [ -n "$PROCS" ]; then
        log WARN "HDD aktiv:$ACTIVE | Prozesse: $PROCS"
      else
        log INFO "HDD aktiv:$ACTIVE"
      fi
    else
      IDLE_STREAK=$((IDLE_STREAK+1))
      # Nur jede 6. Idle-Runde loggen (= ca. 1 Minute bei 10s Intervall)
      if [ $((IDLE_STREAK % 6)) -eq 0 ]; then
        log INFO "HDDs idle (${IDLE_STREAK}x / $((IDLE_STREAK * INTERVAL))s)"
      fi
    fi

    PREV="$CURR"
  done
}

# ── Start / Stop / Status ────────────────────────────────────────────────────────
do_start() {
  if [ -f "$PIDFILE" ]; then
    PID=$(cat "$PIDFILE")
    if kill -0 "$PID" 2>/dev/null; then
      printf '[SKIP] Daemon laeuft bereits (PID %s)\n' "$PID"
      exit 0
    fi
    rm -f "$PIDFILE"
  fi
  # Im Hintergrund starten
  sh "$0" _run &
  BGPID=$!
  printf '%s' "$BGPID" > "$PIDFILE"
  printf '[ OK ] Daemon gestartet (PID %s)\n' "$BGPID"
  printf '       RAM-Log : %s\n' "$LOG_RAM"
  printf '       SSD-Log : %s\n' "$LOG_SSD"
  printf '       tail -f %s   fuer Live-Output\n' "$LOG_RAM"
}

do_stop() {
  if [ -f "$PIDFILE" ]; then
    PID=$(cat "$PIDFILE")
    if kill "$PID" 2>/dev/null; then
      rm -f "$PIDFILE"
      printf '[ OK ] Daemon gestoppt (PID %s)\n' "$PID"
    else
      printf '[WARN] PID %s nicht gefunden -- bereits gestoppt?\n' "$PID"
      rm -f "$PIDFILE"
    fi
  else
    printf '[INFO] Kein PID-File -- Daemon laeuft nicht.\n'
  fi
}

do_status() {
  printf '\n'
  if [ -f "$PIDFILE" ]; then
    PID=$(cat "$PIDFILE")
    if kill -0 "$PID" 2>/dev/null; then
      printf '[ OK ] Daemon laeuft (PID %s)\n' "$PID"
    else
      printf '[WARN] PID-File vorhanden aber Prozess tot (PID %s)\n' "$PID"
    fi
  else
    printf '[INFO] Daemon gestoppt\n'
  fi
  printf '\n'
  printf 'RAM-Log (%s):\n' "$LOG_RAM"
  if [ -f "$LOG_RAM" ]; then
    SIZE=$(du -k "$LOG_RAM" | awk '{print $1}')
    printf '  Groesse: %s KB | Letzte 5 Zeilen:\n' "$SIZE"
    tail -5 "$LOG_RAM" | while read -r l; do printf '  %s\n' "$l"; done
  else
    printf '  (noch nicht vorhanden)\n'
  fi
  printf '\n'
  printf 'SSD-Log (%s):\n' "$LOG_SSD"
  if [ -f "$LOG_SSD" ]; then
    SIZE=$(du -k "$LOG_SSD" | awk '{print $1}')
    LINES=$(wc -l < "$LOG_SSD")
    printf '  Groesse: %s KB | %s Zeilen | Letzte 5:\n' "$SIZE" "$LINES"
    tail -5 "$LOG_SSD" | while read -r l; do printf '  %s\n' "$l"; done
  else
    printf '  (noch nicht vorhanden -- kein WARN/CRIT seit Start)\n'
  fi
  printf '\n'
}

# ── Main ────────────────────────────────────────────────────────────────────────
case "$CMD" in
  start)    do_start ;;
  stop)     do_stop ;;
  status)   do_status ;;
  rotate)   do_rotate ;;
  logcheck) do_logcheck ;;
  install)  do_install ;;
  _run)     run_daemon ;;   # interner Aufruf aus do_start
  *)
    printf 'Usage: %s {start|stop|status|rotate|logcheck|install}\n' "$0"
    printf '\n'
    printf '  start     Daemon im Hintergrund starten\n'
    printf '  stop      Daemon stoppen\n'
    printf '  status    Status + Log-Vorschau\n'
    printf '  rotate    Logs jetzt rotieren (auch per Cron 05:30)\n'
    printf '  logcheck  Analysiert bestehendes Logrotate-Setup\n'
    printf '  install   Autostart (autorun.sh) + Cron einrichten\n'
    exit 1
    ;;
esac
