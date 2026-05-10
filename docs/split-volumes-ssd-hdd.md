# Volume-Aufteilung: SSD + HDD für Paperless-ngx auf QNAP

## Das Problem

Postgres und Redis erzeugen konstanten kleinen I/O (WAL-Writes, Snapshots, Heartbeats).
Dieser I/O verhindert dass HDDs in den Sleep-Modus gehen — auch wenn gerade kein
Dokument verarbeitet wird.

## Lösung: Tiered Storage

```
/share/SSD_DATA/paperless/
  ├── db/       ← Postgres Datenbankdateien
  ├── redis/    ← Redis Snapshots + AOF
  └── data/     ← Paperless-Metadaten, Suchindex

/share/CACHEDEV1_DATA/paperless/
  ├── media/    ← Gescannte Dokumente, PDFs (groß, selten)
  ├── consume/  ← Eingangs-Ordner (nur bei neuem Scan aktiv)
  └── export/   ← Backup-Exports (manuell/geplant)
```

## docker-compose.yml Anpassung

```yaml
services:
  db:
    volumes:
      - /share/SSD_DATA/paperless/db:/var/lib/postgresql/data

  broker:
    volumes:
      - /share/SSD_DATA/paperless/redis:/data

  webserver:
    volumes:
      - /share/SSD_DATA/paperless/data:/usr/src/paperless/data
      - /share/CACHEDEV1_DATA/paperless/media:/usr/src/paperless/media
      - /share/CACHEDEV1_DATA/paperless/consume:/usr/src/paperless/consume
      - /share/CACHEDEV1_DATA/paperless/export:/usr/src/paperless/export
```

## Empfohlene SSD-Größe

| Nutzungsfall | Empfohlene Größe |
|---|---|
| Heimanwender (<10.000 Dokumente) | 120–250 GB M.2 NVMe |
| Kleines Büro (<50.000 Dokumente) | 250–500 GB M.2 NVMe |
| Größere Ablage + andere Docker-Apps | 500 GB – 1 TB |

Der eigentliche Speicherbedarf für db/ und redis/ ist gering (<5 GB typisch),
aber die SSD verbessert die Performance massiv und ermöglicht HDD-Sleep.

## QNAP TVS-x73e spezifisch

Das TVS-x73e hat M.2-Slots für NVMe SSDs die von QTS als:
- **SSD-Cache** (transparent, automatisch) oder
- **Storage Pool** (dediziertes Volume, empfohlen für Docker)

verwendet werden können. Für maximale Kontrolle: dedizierten Storage Pool empfohlen.

## HDD-Sleep Ergebnis

Mit dieser Aufteilung schläft die HDD >90% der Zeit:

| Zeitraum | HDD-Status |
|---|---|
| Idle (kein Scan) | 💤 Schlafend |
| Paperless-Suche | 💤 Schlafend (Daten auf SSD) |
| Neues Dokument scannen | 🔄 Kurz wach (consume + media) |
| Postgres-WAL-Write | 💤 Schlafend (auf SSD) |
