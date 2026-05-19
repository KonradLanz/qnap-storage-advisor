#!/bin/sh
# qnap-storage-advisor.sh
# Analysiert Storage-Konfiguration auf QNAP NAS
# und gibt Empfehlungen fuer HDD-Sleep, SSD-Caching, Container-Workloads
#
# Usage:
#   sh qnap-storage-advisor.sh                      # einmaliger Check (auto-detect)
#   sh qnap-storage-advisor.sh --config nas.conf    # mit NAS-spezifischer Config
#   sh qnap-storage-advisor.sh --detect             # Config-Vorlage generieren
#   sh qnap-storage-advisor.sh --watch              # HDD-I/O-Daemon
#   sh qnap-storage-advisor.sh --watch --config nas.conf
#
# Kompatibel mit: busybox ash (QNAP QTS), dash, bash
#
# License: AGPLv3 - https://www.gnu.org/licenses/agpl-3.0.html
# Copyright (c) 2026 GrEEV.com KG

# ---------------------------------------------------------------------------
# Argumente parsen
# ---------------------------------------------------------------------------
MODE=""
CONFIG_FILE=""

for arg in "$@"; do
  case "$arg" in
    --watch)  MODE="watch" ;;
    --detect) MODE="detect" ;;
    --config) ;; # naechstes Argument ist der Pfad
    *)
      if [ -n "$_EXPECT_CONFIG" ]; then
        CONFIG_FILE="$arg"
        _EXPECT_CONFIG=""
      fi
      ;;
  esac
  [ "$arg" = "--config" ] && _EXPECT_CONFIG=1
done

# ---------------------------------------------------------------------------
# Defaults (werden ggf. durch nas.conf ueberschrieben)
# ---------------------------------------------------------------------------
NAS_LABEL="QNAP NAS"
PAPERLESS_BASE="/share/Container/paperless-ngx"
SSD_MOUNTS=""     # leer = automatisch via /sys/block
HDD_MOUNTS=""     # leer = automatisch via /sys/block
EXTRA_SLEEP_KILLERS=""

# ---------------------------------------------------------------------------
# Config-Datei laden (falls angegeben)
# ---------------------------------------------------------------------------
if [ -n "$CONFIG_FILE" ]; then
  if [ -f "$CONFIG_FILE" ]; then
    # shellcheck source=/dev/null
    . "$CONFIG_FILE"
  else
    printf 'FEHLER: Config-Datei nicht gefunden: %s\n' "$CONFIG_FILE" >&2
    exit 1
  fi
fi

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
  REALDEV=$(df "$TARGET" 2>/dev/null | tail -1 | awk '{print $1}')
  case "$REALDEV" in
    /dev/*) ;;
    *) echo "unknown"; return ;;
  esac

  DEVNAME=$(basename "$REALDEV")

  if [ -f "/sys/block/$DEVNAME/queue/rotational" ]; then
    cat "/sys/block/$DEVNAME/queue/rotational"
    return
  fi

  # md-RAID: alle Member pruefen -> wenn eines rotational -> HDD
  MDBASE=$(echo "$DEVNAME" | sed 's/p[0-9]*$//' | grep '^md')
  if [ -n "$MDBASE" ] && [ -d "/sys/block/$MDBASE/slaves" ]; then
    for slave in /sys/block/$MDBASE/slaves/*; do
      [ -e "$slave" ] || continue
      SLAVE_BASE=$(basename "$slave" | sed 's/[0-9]*$//')
      if [ -f "/sys/block/$SLAVE_BASE/queue/rotational" ]; then
        ROT=$(cat "/sys/block/$SLAVE_BASE/queue/rotational")
        if [ "$ROT" = "1" ]; then
          echo "1"; return
        fi
      fi
    done
    echo "0"
    return
  fi

  echo "unknown"
}

# ── Dynamische Mount-Erkennung ────────────────────────────────────────────────
# Befuellt SSD_MOUNTS und HDD_MOUNTS falls nicht via Config gesetzt
build_mount_lists() {
  if [ -n "$SSD_MOUNTS" ] || [ -n "$HDD_MOUNTS" ]; then
    return  # Config-Werte haben Vorrang
  fi

  for mnt in /share/CACHEDEV*_DATA /share/CE_CACHEDEV*_DATA; do
    [ -d "$mnt" ] || continue
    ROT=$(path_is_rotational "$mnt")
    case "$ROT" in
      0) SSD_MOUNTS="$SSD_MOUNTS $mnt" ;;
      1) HDD_MOUNTS="$HDD_MOUNTS $mnt" ;;
    esac
  done

  SSD_MOUNTS=$(echo "$SSD_MOUNTS" | sed 's/^ *//')
  HDD_MOUNTS=$(echo "$HDD_MOUNTS" | sed 's/^ *//')
}

# ── Header ────────────────────────────────────────────────────────────────────
print_header() {
  hr
  say " QNAP Storage Advisor"
  say " https://github.com/KonradLanz/qnap-storage-advisor"
  hr
  info "Datum    : $(date '+%Y-%m-%d %H:%M:%S')"
  info "Hostname : $(hostname)"
  info "NAS      : $NAS_LABEL"
  QTS_VER=$(head -1 /etc/version 2>/dev/null)
  info "QTS      : ${QTS_VER:-unbekannt}"
  if [ -n "$CONFIG_FILE" ]; then
    info "Config   : $CONFIG_FILE"
  else
    info "Config   : (auto-detect)"
  fi
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
  info "Volume-Typen (dynamisch erkannt):"
  for mnt in /share/CACHEDEV*_DATA /share/CE_CACHEDEV*_DATA; do
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

  DEFAULT_KILLERS="mediasrv photostation qmultimedia Qsirch"
  for svc in $DEFAULT_KILLERS $EXTRA_SLEEP_KILLERS; do
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
  info "Geplanter BASE_DIR: $PAPERLESS_BASE"

  PARENT=$(dirname "$PAPERLESS_BASE")
  ROT=$(path_is_rotational "$PARENT")
  case "$ROT" in
    0)
      ok "BASE_DIR liegt auf SSD/NVMe -- optimale Konfiguration"
      ;;
    1)
      warn "Paperless BASE_DIR wird auf HDD liegen"
      printf '\n'
      info "Empfohlene Volume-Aufteilung:"
      # SSD-Mount fuer DB-Volumes ermitteln
      BEST_SSD=$(echo "$SSD_MOUNTS" | awk '{print $1}')
      BEST_HDD=$(echo "$HDD_MOUNTS" | awk '{print $1}')
      SSD_BASE="${BEST_SSD:-/share/CACHEDEV2_DATA}"
      HDD_BASE="${BEST_HDD:-/share/CACHEDEV1_DATA}"
      PNAME=$(basename "$PAPERLESS_BASE")
      info "  SSD -> ${SSD_BASE}/${PNAME}/db/      (Postgres)"
      info "  SSD -> ${SSD_BASE}/${PNAME}/redis/   (Redis)"
      info "  SSD -> ${SSD_BASE}/${PNAME}/data/    (Suchindex)"
      info "  HDD -> ${HDD_BASE}/${PNAME}/media/   (PDFs)"
      info "  HDD -> ${HDD_BASE}/${PNAME}/consume/ (Eingang)"
      info "  HDD -> ${HDD_BASE}/${PNAME}/export/  (Backup)"
      rec "Paperless db/ + redis/ + data/ nach ${SSD_BASE}/${PNAME}/ verschieben"
      ;;
    *)
      info "Kann Storage-Typ nicht bestimmen -- manuell pruefen"
      ;;
  esac
  printf '\n'
}

# ── 7. Setup-Empfehlung ───────────────────────────────────────────────────────
check_setup_recommendation() {
  say "[7/8] Setup-Empfehlung"
  hr

  if [ -z "$SSD_MOUNTS" ] && [ -z "$HDD_MOUNTS" ]; then
    info "Keine Volumes klassifiziert -- pruefen ob /share/CACHEDEV*_DATA existiert"
    printf '\n'
    return
  fi

  PNAME=$(basename "$PAPERLESS_BASE")

  info "NAS: $NAS_LABEL"
  printf '\n'

  if [ -n "$SSD_MOUNTS" ]; then
    info "SSD-Volumes:  $SSD_MOUNTS"
    BEST_SSD=$(echo "$SSD_MOUNTS" | awk '{print $1}')
    info "  -> DB-Tier: ${BEST_SSD}/${PNAME}/{db,redis,data}"
  fi

  if [ -n "$HDD_MOUNTS" ]; then
    info "HDD-Volumes:  $HDD_MOUNTS"
    BEST_HDD=$(echo "$HDD_MOUNTS" | awk '{print $1}')
    info "  -> Daten-Tier: ${BEST_HDD}/${PNAME}/{media,consume,export}"
  fi

  printf '\n'
  if [ -n "$SSD_MOUNTS" ]; then
    ok "SSD vorhanden -- HDD-RAID kann schlafen sobald db/redis auf SSD liegen"
    ok "Kein SSD-Kauf noetig"
  fi
  printf '\n'
}

# ── 8. HDD I/O Activity ──────────────────────────────────────────────────────
check_hdd_io() {
  say "[8/8] HDD I/O Aktivitaet"
  hr

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

  if [ "$MODE" = "watch" ]; then
    say "  Druecke Strg+C zum Beenden -- Intervall: 5 Sekunden"
    hr

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
        # Prozesse auf HDD-Mounts (dynamisch aus HDD_MOUNTS)
        for mnt in $HDD_MOUNTS; do
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
  fi
  printf '\n'
}

# ── --detect: Config-Vorlage generieren ──────────────────────────────────────
cmd_detect() {
  HOSTNAME=$(hostname 2>/dev/null || echo "qnap")
  QTS_VER=$(head -1 /etc/version 2>/dev/null || echo "unbekannt")
  DATE=$(date '+%Y-%m-%d %H:%M:%S')

  # Volumes dynamisch klassifizieren
  build_mount_lists

  # Paperless-Basispfad: erstes SSD-Volume nehmen falls vorhanden
  BEST_SSD=$(echo "$SSD_MOUNTS" | awk '{print $1}')
  DETECTED_PAPERLESS="${BEST_SSD:-/share/CACHEDEV1_DATA}/Container/paperless-ngx"

  # Ausgabe als gueltiges sh-Sourceable Config-File
  cat << EOF
# =============================================================================
# nas.conf -- NAS-spezifische Konfiguration fuer qnap-storage-advisor
# =============================================================================
#
# Generiert von: sh qnap-storage-advisor.sh --detect
# Datum        : $DATE
# Hostname     : $HOSTNAME
# QTS          : $QTS_VER
#
# WICHTIG: Diese Datei enthaelt NAS-spezifische Pfade und Einstellungen.
# Sie wird NICHT ins Git-Repo eingecheckt (steht in .gitignore).
# Fuer andere Entwickler: siehe nas.conf.example als Vorlage.
#
# Zum Verwenden:
#   sh qnap-storage-advisor.sh --config nas.conf
#   sh qnap-storage-advisor.sh --watch  --config nas.conf
# =============================================================================

# NAS-Bezeichnung (erscheint in Reports und Logs)
NAS_LABEL="$HOSTNAME"

# ---------------------------------------------------------------------------
# Paperless-ngx Basispfad
# ---------------------------------------------------------------------------
# Automatisch ermittelt: erstes SSD-Volume wird fuer db/redis/data bevorzugt.
# Anpassen falls ein anderer Pfad gewuenscht ist.
PAPERLESS_BASE="$DETECTED_PAPERLESS"

# ---------------------------------------------------------------------------
# Volume-Klassifikation
# ---------------------------------------------------------------------------
# Automatisch via /sys/block/*/queue/rotational ermittelt.
# Kann manuell ueberschrieben werden falls die Erkennung falsch liegt
# (z.B. bei SSD-Drives die sich als rotational melden).
#
# Format: space-separated Pfade
SSD_MOUNTS="$SSD_MOUNTS"
HDD_MOUNTS="$HDD_MOUNTS"

# ---------------------------------------------------------------------------
# Zusaetzliche Sleep-Killer-Dienste (QNAP-spezifisch)
# ---------------------------------------------------------------------------
# Dienste die zusaetzlich zu den Defaults (mediasrv, photostation,
# qmultimedia, Qsirch) auf HDD-I/O ueberwacht werden sollen.
# Format: space-separated Prozessnamen (exakt wie in 'ps')
EXTRA_SLEEP_KILLERS=""
EOF
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
  info "Config : sh qnap-storage-advisor.sh --detect > nas.conf"
  hr
}

# ── main ─────────────────────────────────────────────────────────────────────
main() {
  case "$MODE" in
    detect)
      cmd_detect
      ;;
    watch)
      build_mount_lists
      print_header
      check_hdd_io
      ;;
    *)
      build_mount_lists
      print_header
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
      ;;
  esac
}

main
