#!/bin/sh
# qnap-storage-advisor.sh
# Analysiert Storage-Konfiguration auf QNAP NAS
# und gibt Empfehlungen für HDD-Sleep, SSD-Caching, Container-Workloads
#
# Usage: sh qnap-storage-advisor.sh [--json]
#
# License: AGPLv3 — https://www.gnu.org/licenses/agpl-3.0.html
# Copyright (c) 2026 GrEEV.com KG

set -u

JSON_MODE=0
[ "${1:-}" = "--json" ] && JSON_MODE=1

# ── Farben (werden deaktiviert wenn kein TTY) ──────────────────────────────────
if [ -t 1 ]; then
  C_RESET='\033[0m'
  C_OK='\033[0;32m'
  C_WARN='\033[0;33m'
  C_FAIL='\033[0;31m'
  C_INFO='\033[0;36m'
  C_BOLD='\033[1m'
else
  C_RESET=''; C_OK=''; C_WARN=''; C_FAIL=''; C_INFO=''; C_BOLD=''
fi

EXIT_CODE=0
WARNINGS=0
RECOMMENDATIONS=''

say()  { printf '%b%s%b\n' "$C_BOLD" "$*" "$C_RESET"; }
ok()   { printf '%b[ OK ]%b %s\n' "$C_OK" "$C_RESET" "$*"; }
info() { printf '%b[INFO]%b %s\n' "$C_INFO" "$C_RESET" "$*"; }
warn() { printf '%b[WARN]%b %s\n' "$C_WARN" "$C_RESET" "$*"; WARNINGS=$((WARNINGS+1)); }
fail() { printf '%b[FAIL]%b %s\n' "$C_FAIL" "$C_RESET" "$*"; EXIT_CODE=1; }
rec()  {
  printf '%b[REC ]%b %s\n' "$C_WARN" "$C_RESET" "$*"
  RECOMMENDATIONS="${RECOMMENDATIONS}\n  → $*"
}

hr()   { printf '%s\n' "──────────────────────────────────────────────────"; }

# ── Header ────────────────────────────────────────────────────────────────────
print_header() {
  hr
  say " QNAP Storage Advisor"
  say " https://github.com/KonradLanz/qnap-storage-advisor"
  hr
  info "Datum    : $(date '+%Y-%m-%d %H:%M:%S')"
  info "Hostname : $(hostname)"
  info "QTS      : $(cat /etc/version 2>/dev/null | head -1 || echo 'unbekannt')"
  say
}

# ── 1. Disk-Typen erkennen ────────────────────────────────────────────────────
check_disk_types() {
  say "[1/7] Disk-Typen"
  hr

  HDD_COUNT=0
  SSD_COUNT=0
  NVME_COUNT=0

  for dev in /sys/block/sd* /sys/block/nvme* 2>/dev/null; do
    [ -e "$dev" ] || continue
    DEVNAME=$(basename "$dev")
    ROT_FILE="$dev/queue/rotational"
    ROT=1
    [ -f "$ROT_FILE" ] && ROT=$(cat "$ROT_FILE")

    # Größe in GB
    SIZE_SECTORS=0
    [ -f "$dev/size" ] && SIZE_SECTORS=$(cat "$dev/size")
    SIZE_GB=$(( SIZE_SECTORS / 2 / 1024 / 1024 ))

    # Modell
    MODEL="unbekannt"
    [ -f "$dev/device/model" ] && MODEL=$(cat "$dev/device/model" | tr -d '\n')
    [ -f "$dev/../device/model" ] && MODEL=$(cat "$dev/../device/model" | tr -d '\n' 2>/dev/null || echo "$MODEL")

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
          info "$DEVNAME : HDD (rot) ${SIZE_GB}GB  [$MODEL]"
        fi
        ;;
    esac
  done

  say
  info "Zusammenfassung: ${HDD_COUNT}× HDD, ${SSD_COUNT}× SATA-SSD, ${NVME_COUNT}× NVMe"

  if [ "$SSD_COUNT" -eq 0 ] && [ "$NVME_COUNT" -eq 0 ]; then
    warn "Keine SSD/NVMe erkannt — nur HDDs vorhanden"
    rec "SSD/NVMe kaufen: 1× M.2 NVMe (250–500GB) für Docker-Volumes (db, redis) → HDD kann dann schlafen"
  else
    ok "Mindestens eine SSD/NVMe vorhanden"
  fi
  say
}

# ── 2. RAID / MDSTAT ─────────────────────────────────────────────────────────
check_raid() {
  say "[2/7] RAID-Konfiguration"
  hr

  if [ -f /proc/mdstat ]; then
    cat /proc/mdstat | grep -v '^Personalities\|^unused\|^$' | while read -r line; do
      info "$line"
    done
    RAID_DEVICES=$(grep -c '^md' /proc/mdstat 2>/dev/null || echo 0)
    info "RAID-Arrays erkannt: $RAID_DEVICES"
  else
    info "/proc/mdstat nicht gefunden (ggf. QNAP Hardware-RAID)"
  fi
  say
}

# ── 3. Mount-Punkte & Speicher ───────────────────────────────────────────────
check_mounts() {
  say "[3/7] Mount-Punkte & Speicher"
  hr

  df -h 2>/dev/null | grep -E 'Filesystem|/share|/dev/md|/dev/sd|/dev/nvme' | while read -r line; do
    info "$line"
  done

  # CACHEDEV1_DATA prüfen
  CACHE_DEV=$(df /share/CACHEDEV1_DATA 2>/dev/null | tail -1 | awk '{print $1}')
  if [ -n "$CACHE_DEV" ]; then
    info "Container/Docker liegt auf: $CACHE_DEV"
    # Rotational check für das Device
    DEVBASE=$(echo "$CACHE_DEV" | sed 's|/dev/||;s|[0-9]*$||')
    if [ -f "/sys/block/$DEVBASE/queue/rotational" ]; then
      ROT=$(cat "/sys/block/$DEVBASE/queue/rotational")
      if [ "$ROT" = "1" ]; then
        warn "Docker-Root ($CACHE_DEV) liegt auf einer HDD!"
        rec "Docker db/ und redis/ Volumes auf SSD verschieben → verhindert dass HDD wegen DB-I/O nie schlafen kann"
      else
        ok "Docker-Root ($CACHE_DEV) liegt auf SSD/NVMe — gut für Container-Workloads"
      fi
    fi
  fi
  say
}

# ── 4. Docker-Root prüfen ────────────────────────────────────────────────────
check_docker_root() {
  say "[4/7] Docker-Root"
  hr

  if command -v docker >/dev/null 2>&1; then
    DOCKER_ROOT=$(docker info 2>/dev/null | grep 'Docker Root Dir' | awk '{print $NF}')
    STORAGE_DRIVER=$(docker info 2>/dev/null | grep 'Storage Driver' | awk '{print $NF}')
    info "Docker Root Dir   : ${DOCKER_ROOT:-unbekannt}"
    info "Storage Driver    : ${STORAGE_DRIVER:-unbekannt}"

    if [ -n "$DOCKER_ROOT" ]; then
      DEVBASE=$(df "$DOCKER_ROOT" 2>/dev/null | tail -1 | awk '{print $1}' | sed 's|/dev/||;s|[0-9]*$||')
      if [ -f "/sys/block/$DEVBASE/queue/rotational" ]; then
        ROT=$(cat "/sys/block/$DEVBASE/queue/rotational")
        if [ "$ROT" = "1" ]; then
          warn "Docker Root liegt auf HDD → Container-I/O verhindert HDD-Sleep"
          rec "Docker Root auf SSD verschieben: Container Station → Einstellungen → Speicherpfad"
        else
          ok "Docker Root liegt auf SSD/NVMe"
        fi
      fi
    fi
  else
    info "Docker nicht gefunden — überspringe Docker-Root-Check"
  fi
  say
}

# ── 5. HDD-Sleep-Killer erkennen ─────────────────────────────────────────────
check_hdd_sleep_killers() {
  say "[5/7] HDD-Sleep-Killer (Prozesse die HDD wach halten)"
  hr

  # laufende Container
  if command -v docker >/dev/null 2>&1; then
    RUNNING=$(docker ps --format '{{.Names}}' 2>/dev/null)
    if [ -n "$RUNNING" ]; then
      warn "Laufende Container: $(echo $RUNNING | tr '\n' ' ')"
      warn "Container mit 'restart: unless-stopped' halten durch periodischen I/O die HDD wach"
      rec "Paperless-Volumes aufteilen: db/ + redis/ → SSD, media/ + consume/ + export/ → HDD"
      rec "Damit kann die HDD schlafen wenn keine Dokumente verarbeitet werden"
    else
      ok "Keine laufenden Container — HDD kann schlafen"
    fi
  fi

  # Syslog / rsyslog Schreibaktivität
  if [ -f /var/log/messages ]; then
    SYSLOG_WRITES=$(ls -la /var/log/messages | awk '{print $5}')
    info "/var/log/messages Größe: ${SYSLOG_WRITES} Bytes"
    info "Tipp: Syslog auf tmpfs/RAM-Disk → reduziert HDD-Schreibzugriffe"
  fi

  # Thumbnail-/Preview-Dienste
  for svc in mediasrv photostation qmultimedia; do
    if pgrep -x "$svc" >/dev/null 2>&1; then
      warn "Dienst '$svc' läuft — kann HDD durch Thumbnail-Generierung wach halten"
      rec "'$svc' deaktivieren falls nicht benötigt: App Center → Multimedia-Station"
    fi
  done

  say
}

# ── 6. Paperless-Volume-Analyse ──────────────────────────────────────────────
check_paperless_volumes() {
  say "[6/7] Paperless-Volume-Empfehlung"
  hr

  BASE_DIR="${BASE_DIR:-/share/Container/paperless-ngx}"
  info "Geplanter BASE_DIR: $BASE_DIR"

  # Prüfe ob BASE_DIR auf SSD oder HDD liegt
  DEVBASE=$(df "$(dirname $BASE_DIR)" 2>/dev/null | tail -1 | awk '{print $1}' | sed 's|/dev/||;s|[0-9]*$||')
  if [ -f "/sys/block/$DEVBASE/queue/rotational" ]; then
    ROT=$(cat "/sys/block/$DEVBASE/queue/rotational")
    if [ "$ROT" = "1" ]; then
      warn "Paperless BASE_DIR wird auf HDD liegen"
      say
      info "Empfohlene Volume-Aufteilung (SSD + HDD):"
      info "  SSD → db/     (Postgres: häufige kleine Schreibzugriffe)"
      info "  SSD → redis/  (Redis: Write-Ahead-Log, Snapshots)"
      info "  SSD → data/   (Paperless-Metadaten, SQLite-Fallback)"
      info "  HDD → media/  (Gescannte Dokumente, PDFs — seltener Zugriff)"
      info "  HDD → consume/(Eingangs-Ordner — nur bei neuem Scan aktiv)"
      info "  HDD → export/ (Backup-Export — manuell/geplant)"
      rec "Kauf-Empfehlung: 1× M.2 NVMe SSD (250GB reicht) für db/, redis/, data/"
      rec "Damit schläft die HDD >90% der Zeit — nur beim Scannen aktiv"
    else
      ok "Paperless BASE_DIR liegt auf SSD/NVMe — optimale Konfiguration"
      info "Alle Volumes können auf dem SSD-Volume bleiben"
    fi
  else
    info "Kann Storage-Typ für '$BASE_DIR' nicht bestimmen (Device: $DEVBASE)"
  fi
  say
}

# ── 7. Zusammenfassung & Empfehlungen ────────────────────────────────────────
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
    say
    say " EMPFEHLUNGEN:"
    printf '%b\n' "$RECOMMENDATIONS"
  fi

  say
  info "Vollständige Doku: https://github.com/KonradLanz/qnap-storage-advisor"
  hr
}

main() {
  print_header
  check_disk_types
  check_raid
  check_mounts
  check_docker_root
  check_hdd_sleep_killers
  check_paperless_volumes
  print_summary
  exit "$EXIT_CODE"
}

main
