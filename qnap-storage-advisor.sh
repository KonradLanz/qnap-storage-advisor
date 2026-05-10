#!/bin/sh
# qnap-storage-advisor.sh
# Analysiert Storage-Konfiguration auf QNAP NAS
# und gibt Empfehlungen fuer HDD-Sleep, SSD-Caching, Container-Workloads
#
# Usage:
#   sh qnap-storage-advisor.sh           # einmaliger Check
#   sh qnap-storage-advisor.sh --watch   # HDD-I/O-Daemon (Strg+C zum Beenden)
#
# Kompatibel mit: busybox ash (QNAP QTS), dash, bash
#
# License: AGPLv3 - https://www.gnu.org/licenses/agpl-3.0.html
# Copyright (c) 2026 GrEEV.com KG

MODE="${1:-}"
EXIT_CODE=0
WARNINGS=0
RECOMMENDATIONS=""

# ── Farben (nur bei echtem TTY) ───────────────────────────────────────────────
if [ -t 1 ]; then
  R='\033[0m'
  COK='\033[0;32m'
  CWN='\033[0;33m'
  CFI='\033[0;31m'
  CIN='\033[0;36m'
  CBL='\033[1m'
else
  R=''; COK=''; CWN=''; CFI=''; CIN=''; CBL=''
fi

say()  { printf "${CBL}%s${R}\n" "$*"; }
ok()   { printf "${COK}[ OK ]${R} %s\n" "$*"; }
info() { printf "${CIN}[INFO]${R} %s\n" "$*"; }
warn() { printf "${CWN}[WARN]${R} %s\n" "$*"; WARNINGS=$((WARNINGS+1)); }
fail() { printf "${CFI}[FAIL]${R} %s\n" "$*"; EXIT_CODE=1; }
rec()  {
  printf "${CWN}[REC ]${R} %s\n" "$*"
  RECOMMENDATIONS="${RECOMMENDATIONS}
  -> $*"
}
hr() { printf '%s\n' "--------------------------------------------------"; }

# ── Hilfsfunktion: md-RAID-bewusste Rotational-Erkennung ─────────────────────
# Gibt 0 (SSD) oder 1 (HDD) zurueck fuer einen beliebigen Pfad
# Funktioniert mit /dev/sdX, /dev/mdX und Symlinks
path_is_rotational() {
  TARGET="$1"
  # echtes Device holen (folgt Symlinks)
  REALDEV=$(df "$TARGET" 2>/dev/null | tail -1 | awk '{print $1}')
  # nur /dev/... Eintraege sind auswertbar
  case "$REALDEV" in
    /dev/*) ;;
    *) echo "unknown"; return ;;
  esac

  DEVNAME=$(basename "$REALDEV")

  # Direkt /sys/block verfuegbar? (sdX, nvmeX)
  if [ -f "/sys/block/$DEVNAME/queue/rotational" ]; then
    cat "/sys/block/$DEVNAME/queue/rotational"
    return
  fi

  # md-RAID: alle Mitglieder pruefen -> wenn eines rotational ist -> HDD
  # Partition-Suffix abschneiden: md1p1 -> md1, md322 -> md322
  MDBASE=$(echo "$DEVNAME" | sed 's/p[0-9]*$//' | grep '^md')
  if [ -n "$MDBASE" ] && [ -d "/sys/block/$MDBASE/slaves" ]; then
    for slave in /sys/block/$MDBASE/slaves/*; do
      [ -e "$slave" ] || continue
      SLAVE_DEV=$(basename "$slave")
      # Slave kann sdbN sein -> strip Ziffer am Ende fuer /sys/block
      SLAVE_BASE=$(echo "$SLAVE_DEV" | sed 's/[0-9]*$//')
      if [ -f "/sys/block/$SLAVE_BASE/queue/rotational" ]; then
        ROT=$(cat "/sys/block/$SLAVE_BASE/queue/rotational")
        if [ "$ROT" = "1" ]; then
          echo "1"; return  # mindestens ein HDD-Mitglied -> HDD-Array
        fi
      fi
    done
    echo "0"  # alle Mitglieder SSD
    return
  fi

  echo "unknown"
}

# ── Header ────────────────────────────────────────────────────────────────────
print_header() {
  hr
  say " QNAP Storage Advisor"
  say " https://github.com/KonradLanz/qnap-storage-advisor"
  hr
  info "Datum    : $(date '+%Y-%m-%d %H:%M:%S')"
  info "Hostname : $(hostname)"
  QTS_VER=$(cat /etc/version 2>/dev/null | head -1)
  info "QTS      : ${QTS_VER:-unbekannt}"
  printf '\n'
}

# ── 1. Disk-Typen ────────────────────────────────────────────────────────────
check_disk_types() {
  say "[1/8] Disk-Typen"
  hr
  HDD_COUNT=0; SSD_COUNT=0; NVME_COUNT=0

  for dev in /sys/block/sd* /sys/block/nvme*; do
    [ -e "$dev" ] || continue
    DEVNAME=$(basename "$dev")
    ROT=1
    [ -f "$dev/queue/rotational" ] && ROT=$(cat "$dev/queue/rotational")
    SIZE_SECTORS=0
    [ -f "$dev/size" ] && SIZE_SECTORS=$(cat "$dev/size")
    SIZE_GB=$(( SIZE_SECTORS / 2 / 1024 / 1024 ))
    MODEL="unbekannt"
    [ -f "$dev/device/model" ] && MODEL=$(tr -d '\n' < "$dev/device/model")

    case "$DEVNAME" in
      nvme*)
        NVME_COUNT=$((NVME_COUNT+1))
        info "$DEVNAME : NVMe SSD  ${SIZE_GB}GB  [$MODEL]"
        ;;
      *)
        if [ "$ROT" = "0" ]; then
          SSD_COUNT=$((SSD_COUNT+1))
          info "$DEVNAME : SATA SSD  ${SIZE_GB}GB  [$MODEL]"
        else
          HDD_COUNT=$((HDD_COUNT+1))
          info "$DEVNAME : HDD       ${SIZE_GB}GB  [$MODEL]"
        fi
        ;;
    esac
  done

  printf '\n'
  info "Zusammenfassung: ${HDD_COUNT}x HDD, ${SSD_COUNT}x SATA-SSD, ${NVME_COUNT}x NVMe"
  if [ "$SSD_COUNT" -eq 0 ] && [ "$NVME_COUNT" -eq 0 ]; then
    warn "Keine SSD/NVMe -- nur HDDs vorhanden"
    rec "1x M.2 NVMe (250-500GB) fuer Docker db/ + redis/ -> HDD kann schlafen"
  else
    ok "SSD/NVMe vorhanden"
  fi
  printf '\n'
}

# ── 2. RAID ───────────────────────────────────────────────────────────────────
check_raid() {
  say "[2/8] RAID-Konfiguration"
  hr
  if [ -f /proc/mdstat ]; then
    grep -v '^Personalities\|^unused\|^$' /proc/mdstat | while read -r line; do
      info "$line"
    done
    RAID_DEVICES=$(grep -c '^md' /proc/mdstat 2>/dev/null || echo 0)
    info "RAID-Arrays erkannt: $RAID_DEVICES"
  else
    info "/proc/mdstat nicht gefunden"
  fi
  printf '\n'
}

# ── 3. Mount-Punkte & Speicher ───────────────────────────────────────────────
check_mounts() {
  say "[3/8] Mount-Punkte & Speicher"
  hr
  df -h 2>/dev/null | grep -E 'Filesystem|/share/CACHE|/share/CE_CACHE|/dev/md|/dev/sd' | while read -r line; do
    info "$line"
  done

  printf '\n'
  # Jedes CACHEDEV pruefen
  for mnt in /share/CACHEDEV1_DATA /share/CACHEDEV2_DATA /share/CE_CACHEDEV4_DATA; do
    [ -d "$mnt" ] || continue
    ROT=$(path_is_rotational "$mnt")
    LABEL=$(basename "$mnt")
    case "$ROT" in
      0) ok  "$LABEL -> SSD/NVMe" ;;
      1) info "$LABEL -> HDD (RAID)" ;;
      *) info "$LABEL -> Typ unbekannt" ;;
    esac
  done
  printf '\n'
}

# ── 4. Docker-Root ────────────────────────────────────────────────────────────
check_docker_root() {
  say "[4/8] Docker-Root"
  hr
  if command -v docker >/dev/null 2>&1; then
    DOCKER_ROOT=$(docker info 2>/dev/null | grep 'Docker Root Dir' | awk '{print $NF}')
    STORAGE_DRIVER=$(docker info 2>/dev/null | grep 'Storage Driver' | awk '{print $NF}')
    info "Docker Root Dir : ${DOCKER_ROOT:-unbekannt}"
    info "Storage Driver  : ${STORAGE_DRIVER:-unbekannt}"

    if [ -n "$DOCKER_ROOT" ]; then
      ROT=$(path_is_rotational "$DOCKER_ROOT")
      case "$ROT" in
        0) ok  "Docker Root liegt auf SSD/NVMe" ;;
        1) warn "Docker Root liegt auf HDD -> Container-I/O verhindert HDD-Sleep"
           rec "Docker Root auf SSD: Container Station -> Einstellungen -> Speicherpfad" ;;
        *) info "Kann Storage-Typ fuer Docker Root nicht bestimmen" ;;
      esac
    fi
  else
    info "Docker nicht gefunden"
  fi
  printf '\n'
}

# ── 5. HDD-Sleep-Killer ───────────────────────────────────────────────────────
check_hdd_sleep_killers() {
  say "[5/8] HDD-Sleep-Killer"
  hr
  if command -v docker >/dev/null 2>&1; then
    RUNNING=$(docker ps --format '{{.Names}}' 2>/dev/null)
    if [ -n "$RUNNING" ]; then
      warn "Laufende Container: $(echo "$RUNNING" | tr '\n' ' ')"
      rec "db/ + redis/ -> SSD, media/ + consume/ + export/ -> HDD"
    else
      ok "Keine laufenden Container"
    fi
  fi
  for svc in mediasrv photostation qmultimedia Qsirch; do
    if pgrep -x "$svc" >/dev/null 2>&1; then
      warn "Dienst '$svc' laeuft -- kann HDD wach halten"
      rec "'$svc' nachts deaktivieren oder auf SSD-Volume verweisen"
    fi
  done
  printf '\n'
}

# ── 6. Paperless-Volume-Empfehlung ───────────────────────────────────────────
check_paperless_volumes() {
  say "[6/8] Paperless-Volume-Empfehlung"
  hr
  PBASE="${BASE_DIR:-/share/Container/paperless-ngx}"
  info "Geplanter BASE_DIR: $PBASE"

  PARENT=$(dirname "$PBASE")
  ROT=$(path_is_rotational "$PARENT")
  case "$ROT" in
    0)
      ok "BASE_DIR liegt auf SSD/NVMe -- optimale Konfiguration"
      ;;
    1)
      warn "Paperless BASE_DIR wird auf HDD liegen"
      printf '\n'
      info "Empfohlene Volume-Aufteilung:"
      info "  SSD -> db/      (Postgres: haeufige kleine Schreibzugriffe)"
      info "  SSD -> redis/   (Redis: WAL, Snapshots)"
      info "  SSD -> data/    (Paperless-Metadaten, Suchindex)"
      info "  HDD -> media/   (PDFs -- seltener Zugriff)"
      info "  HDD -> consume/ (Eingangs-Ordner -- nur beim Scannen)"
      info "  HDD -> export/  (Backup-Export -- manuell/geplant)"
      rec "Paperless db/ + redis/ + data/ nach /share/CACHEDEV2_DATA/paperless/ verschieben"
      ;;
    *)
      info "Kann Storage-Typ nicht bestimmen -- manuell pruefen"
      ;;
  esac
  printf '\n'
}

# ── 7. Spezifische Empfehlung fuer dein Setup ────────────────────────────────
check_setup_recommendation() {
  say "[7/8] Setup-Empfehlung (dein NAS)"
  hr
  # Wir wissen: sda=SSD->md2->CACHEDEV2, sdb-sdg=HDD->md1->CACHEDEV1
  if [ -d /sys/block/sda ] && [ -d /sys/block/sdb ]; then
    SDA_ROT=$(cat /sys/block/sda/queue/rotational 2>/dev/null || echo "1")
    SDB_ROT=$(cat /sys/block/sdb/queue/rotational 2>/dev/null || echo "1")
    if [ "$SDA_ROT" = "0" ] && [ "$SDB_ROT" = "1" ]; then
      info "Erkannt: sda=SSD-Pool, sdb-sdg=HDD-RAID6-Pool"
      printf '\n'
      info "Optimale Paperless-Konfiguration fuer dieses NAS:"
      info "  /share/CACHEDEV2_DATA/paperless/db/      <- Postgres"
      info "  /share/CACHEDEV2_DATA/paperless/redis/   <- Redis"
      info "  /share/CACHEDEV2_DATA/paperless/data/    <- Suchindex"
      info "  /share/CACHEDEV1_DATA/paperless/media/   <- Dokumente (HDD)"
      info "  /share/CACHEDEV1_DATA/paperless/consume/ <- Eingang (HDD)"
      info "  /share/CACHEDEV1_DATA/paperless/export/  <- Export (HDD)"
      printf '\n'
      ok "Kein SSD-Kauf noetig -- CACHEDEV2_DATA (sda, 465GB) reicht fuer DB-Volumes"
      ok "HDD-RAID kann schlafen sobald db/redis auf SSD liegen"
    fi
  fi
  printf '\n'
}

# ── 8. HDD I/O Activity Daemon ───────────────────────────────────────────────
# Liest /proc/diskstats und zeigt welche Prozesse auf HDDs schreiben
# Mit --watch: Dauerschleife bis Strg+C
check_hdd_io() {
  say "[8/8] HDD I/O Aktivitaet"
  hr

  # HDDs aus /sys/block ermitteln
  HDD_DEVS=""
  for dev in /sys/block/sd*; do
    [ -e "$dev" ] || continue
    ROT=1
    [ -f "$dev/queue/rotational" ] && ROT=$(cat "$dev/queue/rotational")
    if [ "$ROT" = "1" ]; then
      DEVNAME=$(basename "$dev")
      HDD_DEVS="$HDD_DEVS $DEVNAME"
    fi
  done

  if [ -z "$HDD_DEVS" ]; then
    ok "Keine HDDs gefunden"
    return
  fi

  info "Ueberwachte HDDs:$HDD_DEVS"
  printf '\n'

  if [ "$MODE" = "--watch" ]; then
    say "  Druecke Strg+C zum Beenden -- Intervall: 5 Sekunden"
    say "  Zeigt Prozesse mit I/O auf HDD-Devices"
    hr

    # Snapshot 1
    snap_diskstats() {
      for d in $HDD_DEVS; do
        grep " $d " /proc/diskstats 2>/dev/null | awk '{print $3, $6, $10}'
      done
    }

    PREV=$(snap_diskstats)
    while true; do
      sleep 5
      CURR=$(snap_diskstats)
      ACTIVE_DEVS=""

      # Vergleiche reads+writes zwischen Snapshots
      for d in $HDD_DEVS; do
        PREV_RW=$(echo "$PREV" | grep "^$d " | awk '{print $2+$3}')
        CURR_RW=$(echo "$CURR" | grep "^$d " | awk '{print $2+$3}')
        PREV_RW=${PREV_RW:-0}
        CURR_RW=${CURR_RW:-0}
        DELTA=$(( CURR_RW - PREV_RW ))
        if [ "$DELTA" -gt 0 ]; then
          ACTIVE_DEVS="$ACTIVE_DEVS $d(+${DELTA}ops)"
        fi
      done

      TIMESTAMP=$(date '+%H:%M:%S')
      if [ -n "$ACTIVE_DEVS" ]; then
        printf "${CWN}%s  HDD aktiv:${R} %s\n" "$TIMESTAMP" "$ACTIVE_DEVS"
        # Prozesse mit offenen Dateien auf HDD-Mounts
        for mnt in /share/CACHEDEV1_DATA /share/CACHEDEV8_DATA; do
          [ -d "$mnt" ] || continue
          PROCS=$(fuser "$mnt" 2>/dev/null | tr ' ' '\n' | while read -r pid; do
            [ -n "$pid" ] || continue
            PNAME=$(cat /proc/$pid/comm 2>/dev/null || echo "pid$pid")
            printf "%s(%s) " "$PNAME" "$pid"
          done)
          if [ -n "$PROCS" ]; then
            printf "  ${CIN}%s:${R} %s\n" "$mnt" "$PROCS"
          fi
        done
      else
        printf "${COK}%s  HDDs idle${R}\n" "$TIMESTAMP"
      fi

      PREV="$CURR"
    done
  else
    # Einmaliger Snapshot: aktuelle I/O-Rates aus /proc/diskstats
    info "Aktueller I/O-Status (Sektoren seit Boot):"
    for d in $HDD_DEVS; do
      LINE=$(grep " $d " /proc/diskstats 2>/dev/null)
      if [ -n "$LINE" ]; then
        READ_SEC=$(echo "$LINE" | awk '{print $6}')
        WRITE_SEC=$(echo "$LINE" | awk '{print $10}')
        READ_GB=$(( READ_SEC / 2 / 1024 / 1024 ))
        WRITE_GB=$(( WRITE_SEC / 2 / 1024 / 1024 ))
        info "  $d : gelesen ${READ_GB}GB / geschrieben ${WRITE_GB}GB (seit Boot)"
      fi
    done
    printf '\n'
    info "Tipp: sh qnap-storage-advisor.sh --watch   fuer Live-Monitoring"
    info "      Zeigt dann welche Prozesse die HDDs wach halten"
    info "      Ideal: nachts laufen lassen um Sleep-Killer zu identifizieren"
  fi
  printf '\n'
}

# ── Zusammenfassung ───────────────────────────────────────────────────────────
print_summary() {
  hr
  say " ZUSAMMENFASSUNG"
  hr
  if [ "$WARNINGS" -eq 0 ] && [ "$EXIT_CODE" -eq 0 ]; then
    ok "Keine kritischen Probleme gefunden"
  else
    warn "$WARNINGS Warnung(en) gefunden"
  fi
  if [ -n "$RECOMMENDATIONS" ]; then
    printf '\n'
    say " EMPFEHLUNGEN:"
    printf '%s\n' "$RECOMMENDATIONS"
  fi
  printf '\n'
  info "Doku   : https://github.com/KonradLanz/qnap-storage-advisor"
  info "Watch  : sh qnap-storage-advisor.sh --watch"
  hr
}

main() {
  print_header
  if [ "$MODE" = "--watch" ]; then
    # Im Watch-Modus nur den I/O-Daemon starten
    check_hdd_io
  else
    check_disk_types
    check_raid
    check_mounts
    check_docker_root
    check_hdd_sleep_killers
    check_paperless_volumes
    check_setup_recommendation
    check_hdd_io
    print_summary
    exit "$EXIT_CODE"
  fi
}

main
