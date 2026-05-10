# Logging-Strategie: Zwei-Tier ohne HDD-Wakeup

## Das Problem

Jeder Log-Schreibzugriff auf `/share/CACHEDEV1_DATA` (HDD-RAID6) weckt die
Festplatten auf. Ein naiver Daemon der jede Minute auf HDD loggt, ist selbst
der groesste HDD-Sleep-Killer.

## Loesung: Zwei-Tier Logging

```
Tier-1: /tmp/hdd-io-daemon.log          (tmpfs = RAM)
  - Alle Ereignisse: INFO, WARN, CRIT
  - Kein einziger HDD-Schreibzugriff
  - Limit: 4MB (aelteste Haelfte wird verworfen)
  - Ueberlebt keinen Neustart -- das ist gewollt

Tier-2: /share/CACHEDEV2_DATA/log/...  (SATA SSD = sda)
  - Nur WARN und CRIT
  - Taeglich rotiert um 05:30
  - Persistent, ueberlebt Neustart
  - Kein HDD-Touch
```

## Kontrollierter HDD-Wakeup um 05:30

Statt die HDDs zufaellig aufzuwecken, gibt es einen dedizierten
Cron-Job der die HDDs jeden Tag um 05:30 kontrolliert aufweckt:

```cron
# Kontrollierter Wakeup: ls weckt RAID auf, danach schlaeft es weiter
30 5 * * * ls /share/CACHEDEV1_DATA/ > /dev/null 2>&1

# Logrotate gleichzeitig: SSD-Log rotieren, RAM-Log leeren
30 5 * * * sh /root/qnap-storage-advisor/hdd-io-daemon.sh rotate

# Daemon-Autostart nach Reboot
@reboot sleep 60 && sh /root/qnap-storage-advisor/hdd-io-daemon.sh start
```

### Warum 05:30?

- HDD ist dann beim ersten Zugriff des Tages bereits wach
- Kein zufaelliges Aufwachen durch Cron-Jobs, Syslog, Thumbnail-Dienste
- Logrotate laeuft waehrend die HDD ohnehin aktiv ist
- Danach: HDD schlaeft wieder bis zum naechsten echten Zugriff

## Prozess-Fluss

```
Boot
  -> sleep 60 (warten bis Mounts verfuegbar)
  -> hdd-io-daemon.sh start
  -> Daemon laeuft im Hintergrund
  -> schreibt alle 10s in /tmp/hdd-io-daemon.log (RAM)
  -> schreibt WARN/CRIT in /share/CACHEDEV2_DATA/log/ (SSD)
  -> HDDs schlafen wenn kein I/O

05:30 Cron
  -> ls /share/CACHEDEV1_DATA/   (HDD wacht kontrolliert auf)
  -> hdd-io-daemon.sh rotate     (SSD-Log rotieren, RAM-Log leeren)
  -> HDD schlaeft wieder
```

## Live-Monitoring

```sh
# Daemon-Status + Log-Vorschau
sh hdd-io-daemon.sh status

# Live-Tail (beobachtet RAM-Log = kein HDD-Touch)
tail -f /tmp/hdd-io-daemon.log

# Nur WARN/CRIT (persistent auf SSD)
tail -f /share/CACHEDEV2_DATA/log/hdd-io-daemon-critical.log
```

## QNAP-spezifische Logs auf HDD (vermeiden)

| Dienst | Standard-Pfad | Problem |
|---|---|---|
| MediaSignPlayer | /share/CACHEDEV1_DATA/.qpkg/... | HDD-Logs |
| Container Station | /share/CACHEDEV1_DATA/.qpkg/container-station | HDD-Logs |
| QTS Log Center | /share/CACHEDEV1_DATA/.qpkg/qulog | HDD-Logs |
| /mnt/ext | System-Partition (416MB, 92% voll!) | Engpass |

Diese Pfade werden von `hdd-io-daemon.sh logcheck` analysiert.
