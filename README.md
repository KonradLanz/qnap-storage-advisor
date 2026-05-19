# qnap-storage-advisor

Analysiert die Festplatten- und Storage-Konfiguration auf QNAP NAS und gibt konkrete Empfehlungen fuer:

- **HDD-Sleep** — welche Workloads HDD-Spin-down verhindern und wie man das behebt
- **SSD-Caching** — ob ein SSD-Cache sinnvoll waere und welche Groesse
- **Tiered Storage** — ob ein dediziertes SSD-Volume fuer Docker/Container sinnvoll ist
- **Container-Workloads** — DB-Volumes (Postgres, Redis) auf SSD, Media auf HDD

## Schnellstart

```sh
# Direkt ausfuehren (auto-detect)
sh qnap-storage-advisor.sh

# Empfohlen: erst NAS-Config generieren, dann verwenden
sh qnap-storage-advisor.sh --detect > nas.conf
sh qnap-storage-advisor.sh --config nas.conf

# Live-Monitoring (zeigt welche Prozesse HDDs wach halten)
sh qnap-storage-advisor.sh --watch --config nas.conf
```

## NAS-Konfiguration (`nas.conf`)

Das Skript funktioniert ohne Config via Auto-Detect. Fuer wiederkehrende Nutzung
empfiehlt sich eine `nas.conf` die NAS-spezifische Pfade und Einstellungen festhaelt.

```sh
# Einmalig auf dem NAS ausfuehren:
sh qnap-storage-advisor.sh --detect > nas.conf
cat nas.conf   # pruefen, ggf. anpassen
```

Die `nas.conf` wird **nicht** ins Repo eingecheckt (`.gitignore`) --
sie ist NAS-spezifisch und bleibt lokal auf dem Geraet.
Siehe [`nas.conf.example`](./nas.conf.example) als dokumentierte Vorlage.

## Modi

| Befehl | Beschreibung |
|---|---|
| `sh qnap-storage-advisor.sh` | Einmaliger Check, alle Volumes auto-erkannt |
| `sh qnap-storage-advisor.sh --config nas.conf` | Check mit NAS-spezifischer Config |
| `sh qnap-storage-advisor.sh --detect` | `nas.conf` automatisch generieren |
| `sh qnap-storage-advisor.sh --watch` | Live HDD-I/O Monitoring |
| `sh qnap-storage-advisor.sh --watch --config nas.conf` | Live Monitoring mit Config |

## Was wird analysiert?

| Check | Quelle | Zweck |
|---|---|---|
| Disk-Typen | `/sys/block/*/queue/rotational` | SSD vs. HDD erkennen |
| RAID-Konfiguration | `/proc/mdstat` | RAID-Level und Mitglieder |
| Mount-Punkte | `df -h` + rotational | Alle CACHEDEVs klassifizieren |
| Docker-Root | `docker info` | Auf SSD oder HDD? |
| HDD-Sleep-Killer | `pgrep`, `fuser` | Prozesse die HDD wach halten |
| Paperless-Volumes | Pfad-Analyse | Optimale SSD/HDD-Aufteilung |
| Setup-Empfehlung | Kombination aller Checks | Konkrete Tiered-Storage-Empfehlung |
| I/O-Aktivitaet | `/proc/diskstats` | Wer schreibt auf welche HDD |

## Getestete Modelle

| Modell | QTS | Anmerkung |
|---|---|---|
| TVS-x73e | 5.2.x | Vollstaendig verifiziert |

PR willkommen fuer weitere Modelle -- bitte `--detect`-Output als Issue beifuegen.

## Fuer Entwickler / andere NAS-Modelle

Das Skript vermeidet NAS-spezifische Hardcodierungen:
- Alle CACHEDEV-Volumes werden **dynamisch** per `/sys/block` klassifiziert
- `path_is_rotational()` folgt md-RAID-Slaves automatisch
- NAS-spezifische Pfade kommen ausschliesslich aus `nas.conf`

Um das Skript auf einem neuen QNAP-Modell zu testen:
```sh
git clone https://github.com/KonradLanz/qnap-storage-advisor.git
cd qnap-storage-advisor
sh qnap-storage-advisor.sh --detect   # zeigt was erkannt wird
```

## Lizenz

AGPLv3 -- https://www.gnu.org/licenses/agpl-3.0.html  
Copyright (c) 2026 GrEEV.com KG
