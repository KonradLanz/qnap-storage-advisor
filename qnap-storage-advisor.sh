#!/bin/sh
# qnap-storage-advisor.sh
# Analysiert Storage-Konfiguration auf QNAP NAS
# und gibt Empfehlungen fuer HDD-Sleep, SSD-Caching, Container-Workloads
#
# Usage: sh qnap-storage-advisor.sh
#
# Kompatibel mit: busybox ash (QNAP QTS), dash, bash
#
# License: AGPLv3 - https://www.gnu.org/licenses/agpl-3.0.html
# Copyright (c) 2026 GrEEV.com KG

# Kein set -u — busybox ash reagiert bei leeren Variablen zu streng

EXIT_CODE=0
WARNINGS=0
RECOMMENDATIONS=""

# ── Farben (nur bei echtem TTY) ───────────────────────────────────────────────
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

say()  { printf "${C_BOLD}%s${C_RESET}\n" "$*"; }
ok()   { printf "${C_OK}[ OK ]${C_RESET} %s\n" "$*"; }
info() { printf "${C_INFO}[INFO]${C_RESET} %s\n" "$*"; }
warn() { printf "${C_WARN}[WARN]${C_RESET} %s\n" "$*"; WARNINGS=$((WARNINGS+1)); }
fail() { printf "${C_FAIL}[FAIL]${C_RESET} %s\n" "$*"; EXIT_CODE=1; }
rec()  {
  printf "${C_WARN}[REC ]${C_RESET} %s\n" "$*"
  RECOMMENDATIONS="${RECOMMENDATIONS}
  -> $*"
}
hr() { printf '%s\n' "--------------------------------------------------"; }

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

# ── 1. Disk-Typen erkennen ────────────────────────────────────────────────────
check_disk_types() {
  say "[1/7] Disk-Typen"
  hr

  HDD_COUNT=0
  SSD_COUNT=0
  NVME_COUNT=0

  # Glob separat auswerten — kein 2>/dev/null im for-Statement
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
          info "$DEVNAME : HDD (rot) ${SIZE_GB}GB  [$MODEL]"
        fi
        ;;
    esac
  done

  printf '\n'
  info "Zusammenfassung: ${HDD_COUNT}x HDD, ${SSD_COUNT}x SATA-SSD, ${NVME_COUNT}x NVMe"

  if [ "$SSD_COUNT" -eq 0 ] && [ "$NVME_COUNT" -eq 0 ]; then
    warn "Keine SSD/NVMe erkannt — nur HDDs vorhanden"
    rec "SSD/NVMe kaufen: 1x M.2 NVMe (250-500GB) fuer Docker-Volumes (db, redis) -> HDD kann dann schlafen"
  else
    ok "Mindestens eine SSD/NVMe vorhanden"
  fi
  printf '\n'
}

# ── 2. RAID / MDSTAT ─────────────────────────────────────────────────────────
check_raid() {
  say "[2/7] RAID-Konfiguration"
  hr

  if [ -f /proc/mdstat ]; then
    grep -v '^Personalities\|^unused\|^$' /proc/mdstat | while read -r line; do
      info "$line"
    done
    RAID_DEVICES=$(grep -c '^md' /proc/mdstat 2>/dev/null || echo 0)
    info "RAID-Arrays erkannt: $RAID_DEVICES"
  else
    info "/proc/mdstat nicht gefunden (ggf. QNAP Hardware-RAID)"
  fi
  printf '\n'
}

# ── 3. Mount-Punkte & Speicher ───────────────────────────────────────────────
check_mounts() {
  say "[3/7] Mount-Punkte & Speicher"
  hr

  df -h 2>/dev/null | grep -E 'Filesystem|/share|/dev/md|/dev/sd|/dev/nvme' | while read -r line; do
    info "$line"
  done

  CACHE_DEV=$(df /share/CACHEDEV1_DATA 2>/dev/null | tail -1 | awk '{print $1}')
  if [ -n "$CACHE_DEV" ]; then
    info "Container/Docker liegt auf: $CACHE_DEV"
    DEVBASE=$(echo "$CACHE_DEV" | sed 's|/dev/||;s|[0-9]*$||')
    if [ -f "/sys/block/$DEVBASE/queue/rotational" ]; then
      ROT=$(cat "/sys/block/$DEVBASE/queue/rotational")
      if [ "$ROT" = "1" ]; then
        warn "Docker-Root ($CACHE_DEV) liegt auf einer HDD!"
        rec "Docker db/ und redis/ Volumes auf SSD verschieben -> HDD kann schlafen"
      else
        ok "Docker-Root ($CACHE_DEV) liegt auf SSD/NVMe — gut fuer Container-Workloads"
      fi
    fi
  fi
  printf '\n'
}

# ── 4. Docker-Root prüfen ────────────────────────────────────────────────────
check_docker_root() {
  say "[4/7] Docker-Root"
  hr

  if command -v docker >/dev/null 2>&1; then
    DOCKER_ROOT=$(docker info 2>/dev/null | grep 'Docker Root Dir' | awk '{print $NF}')
    STORAGE_DRIVER=$(docker info 2>/dev/null | grep 'Storage Driver' | awk '{print $NF}')
    info "Docker Root Dir : ${DOCKER_ROOT:-unbekannt}"
    info "Storage Driver  : ${STORAGE_DRIVER:-unbekannt}"

    if [ -n "$DOCKER_ROOT" ]; then
      DEVBASE=$(df "$DOCKER_ROOT" 2>/dev/null | tail -1 | awk '{print $1}' | sed 's|/dev/||;s|[0-9]*$||')
      if [ -f "/sys/block/$DEVBASE/queue/rotational" ]; then
        ROT=$(cat "/sys/block/$DEVBASE/queue/rotational")
        if [ "$ROT" = "1" ]; then
          warn "Docker Root liegt auf HDD -> Container-I/O verhindert HDD-Sleep"
          rec "Docker Root auf SSD verschieben: Container Station -> Einstellungen -> Speicherpfad"
        else
          ok "Docker Root liegt auf SSD/NVMe"
        fi
      fi
    fi
  else
    info "Docker nicht gefunden — ueberspringe Docker-Root-Check"
  fi
  printf '\n'
}

# ── 5. HDD-Sleep-Killer erkennen ─────────────────────────────────────────────
check_hdd_sleep_killers() {
  say "[5/7] HDD-Sleep-Killer"
  hr

  if command -v docker >/dev/null 2>&1; then
    RUNNING=$(docker ps --format '{{.Names}}' 2>/dev/null)
    if [ -n "$RUNNING" ]; then
      warn "Laufende Container: $(echo "$RUNNING" | tr '\n' ' ')"
      warn "Container mit restart:unless-stopped halten HDD durch periodischen I/O wach"
      rec "Paperless-Volumes aufteilen: db/ + redis/ -> SSD, media/ + consume/ + export/ -> HDD"
    else
      ok "Keine laufenden Container — HDD kann schlafen"
    fi
  fi

  if [ -f /var/log/messages ]; then
    SYSLOG_SIZE=$(ls -la /var/log/messages | awk '{print $5}')
    info "/var/log/messages: ${SYSLOG_SIZE} Bytes"
    info "Tipp: Syslog auf tmpfs/RAM-Disk -> reduziert HDD-Schreibzugriffe"
  fi

  for svc in mediasrv photostation qmultimedia; do
    if pgrep -x "$svc" >/dev/null 2>&1; then
      warn "Dienst '$svc' laeuft — kann HDD wach halten"
      rec "'$svc' deaktivieren falls nicht benoetigt: App Center -> Multimedia-Station"
    fi
  done

  printf '\n'
}

# ── 6. Paperless-Volume-Empfehlung ───────────────────────────────────────────
check_paperless_volumes() {
  say "[6/7] Paperless-Volume-Empfehlung"
  hr

  PBASE="${BASE_DIR:-/share/Container/paperless-ngx}"
  info "Geplanter BASE_DIR: $PBASE"

  PARENT=$(dirname "$PBASE")
  DEVBASE=$(df "$PARENT" 2>/dev/null | tail -1 | awk '{print $1}' | sed 's|/dev/||;s|[0-9]*$||')

  if [ -f "/sys/block/$DEVBASE/queue/rotational" ]; then
    ROT=$(cat "/sys/block/$DEVBASE/queue/rotational")
    if [ "$ROT" = "1" ]; then
      warn "Paperless BASE_DIR wird auf HDD liegen"
      printf '\n'
      info "Empfohlene Volume-Aufteilung:"
      info "  SSD -> db/      (Postgres: haeufige kleine Schreibzugriffe)"
      info "  SSD -> redis/   (Redis: WAL, Snapshots)"
      info "  SSD -> data/    (Paperless-Metadaten, Suchindex)"
      info "  HDD -> media/   (PDFs — seltener Zugriff)"
      info "  HDD -> consume/ (Eingangs-Ordner — nur beim Scannen aktiv)"
      info "  HDD -> export/  (Backup-Export — manuell/geplant)"
      rec "Kauf-Empfehlung: 1x M.2 NVMe SSD (250GB) fuer db/, redis/, data/"
      rec "Damit schlaeft die HDD >90% der Zeit — nur beim Scannen aktiv"
    else
      ok "Paperless BASE_DIR liegt auf SSD/NVMe — optimale Konfiguration"
    fi
  else
    info "Kann Storage-Typ nicht bestimmen (Device: $DEVBASE) — manuell pruefen"
  fi
  printf '\n'
}

# ── 7. Zusammenfassung ────────────────────────────────────────────────────────
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
  info "Doku: https://github.com/KonradLanz/qnap-storage-advisor"
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
