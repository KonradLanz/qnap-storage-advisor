# qnap-storage-advisor

Analysiert die Festplatten- und Storage-Konfiguration auf QNAP NAS und gibt konkrete Empfehlungen für:

- **HDD-Sleep** — welche Workloads HDD-Spin-down verhindern und wie man das behebt
- **SSD-Caching** — ob ein SSD-Cache sinnvoll wäre und welche Größe
- **Tiered Storage** — ob ein dediziertes SSD-Volume für Docker/Container sinnvoll ist
- **Container-Workloads** — DB-Volumes (Postgres, Redis) auf SSD, Media auf HDD

## Verwendung

```sh
# Direkt ausführen
curl -fsSL https://raw.githubusercontent.com/KonradLanz/qnap-storage-advisor/main/qnap-storage-advisor.sh | sh

# Oder klonen
git clone https://github.com/KonradLanz/qnap-storage-advisor.git
cd qnap-storage-advisor
sh qnap-storage-advisor.sh
```

## Integration mit paperless-ngx-qnap-bootstrap

Das Skript wird automatisch von `paperless-qnap-prepare.sh --check-storage` aufgerufen.
Siehe: [paperless-ngx-qnap-bootstrap](https://github.com/KonradLanz/paperless-ngx-qnap-bootstrap)

## Was wird analysiert?

| Check | Befehl | Zweck |
|---|---|---|
| Disk-Typen | `hdparm`, `/sys/block/*/queue/rotational` | SSD vs. HDD erkennen |
| RAID-Konfiguration | `/proc/mdstat` | RAID-Level und Mitglieder |
| Mount-Punkte | `df -h`, `mount` | Wo liegt was |
| Docker-Root | `docker info` | Auf SSD oder HDD? |
| HDD-Sleep-Killer | `lsof`, `fuser` | Prozesse die HDD wach halten |
| I/O-Last | `iostat` (falls verfügbar) | Wer schreibt wie viel |
| Speicherauslastung | `df` | Freier Platz pro Volume |

## Empfehlungslogik

```
Docker-Root auf HDD?
  → Empfehle SSD-Cache ODER separates SSD-Volume für Container

Postgres/Redis-Volumes auf HDD?
  → WARN: Datenbank-I/O verhindert HDD-Sleep, Performance-Einbußen

HDD-Sleep aktiviert aber Container laufen?
  → INFO: Container mit restart:unless-stopped halten HDD wach
     Lösung: SSD-Tier für db/ und redis/, HDD für media/ und consume/

Nur HDDs vorhanden, kein SSD?
  → Empfehle: 1× M.2 NVMe SSD als dedizierten Cache oder Docker-Volume
```

## Getestete Modelle

| Modell | QTS | Anmerkung |
|---|---|---|
| TVS-x73e | 5.2.9 | Vollständig verifiziert |

PR willkommen für weitere Modelle.

## Lizenz

AGPLv3 — https://www.gnu.org/licenses/agpl-3.0.html  
Copyright (c) 2026 GrEEV.com KG
