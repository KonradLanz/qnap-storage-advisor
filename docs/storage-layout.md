# QNAP Storage Layout

> Advisory document — describes the actual volume topology of this NAS
> and recommended placement for git repos, scripts, and runtime data.

## Volume Map

| Mount point | Device | Size | Used | Notes |
|---|---|---|---|---|
| `/` (root flash) | none/tmpfs | 400 MB | ~400 MB | **Internal flash — nearly full. No repos here.** |
| `/share/CACHEDEV1_DATA` | HDD pool | 2.8 TB | 1.3 TB | Main pool, containers, multimedia |
| `/share/CACHEDEV2_DATA` | HDD | 958 GB | 135 MB | **Almost empty — best for large data** |
| `/share/CACHEDEV3_DATA` | HDD | 655 GB | 429 GB | homes volume (66% used) |
| `/share/CE_CACHEDEV4_DATA` | HDD | 467 GB | 149 GB | 32% used |
| `/share/CACHEDEV5_DATA` | HDD | 497 GB | 184 GB | 37% used |
| `/share/CACHEDEV6_DATA` | HDD | 467 GB | 363 GB | 78% used — getting full |
| `/share/CACHEDEV7_DATA` | HDD | 495 GB | 71 GB | 14% used |
| `/share/CACHEDEV8_DATA` | HDD | 2.4 TB | 1.3 TB | 55% used |
| `/share/NFSv=4/homes` | → CACHEDEV3 | 467 GB | — | NFS export of homes |
| `/share/NFSv=4/backup` | → CACHEDEV8 | 2.4 TB | — | NFS export |
| `/share/NFSv=4/Download` | → CACHEDEV7 | 495 GB | — | NFS export |

## /root/ Flash Limit

`/root` lives on a **400 MB tmpfs/flash partition** shared with the entire
QTS root filesystem. It fills up fast:

- Do NOT clone large repos under `/root/` directly
- Do NOT store logs, databases, or caches under `/root/`
- `/root/git/` must be a **symlink** to the actual storage location

## Recommended git root

```
/share/homes/DOMAIN=AD/koni/git/    ← actual storage (CACHEDEV3)
/root/git                           ← symlink → above
```

Setup:
```bash
mkdir -p /share/homes/DOMAIN=AD/koni/git
mv /root/git/* /share/homes/DOMAIN=AD/koni/git/ 2>/dev/null || true
rm -rf /root/git
ln -s /share/homes/DOMAIN=AD/koni/git /root/git
```

## Script / tool placement

| Type | Location |
|---|---|
| git repos | `/share/homes/DOMAIN=AD/koni/git/` (via `/root/git` symlink) |
| scripts | `/share/homes/DOMAIN=AD/koni/scripts/` |
| logs | `/var/log/` (tmpfs, survives reboot via QNAP log rotation) |
| crontab | `/etc/config/crontab` (persists across reboots on QNAP) |
| gh config | `/root/.config/gh/` (small, OK on flash) |

## Symlink loop cross-reference

Circular Samba symlinks found in `homes` (2026-06-17):
```
KG/Steuer/Rechnungen/Rechnungen -> /share/NFSv=4/homes/.../KG/Steuer/Rechnungen
KG/Steuer/Rechnungen/Steuer     -> /share/NFSv=4/homes/.../KG/Steuer
```
Resolved by: `dotfiles-macos/qnap/fix-symlink-loops.sh`
See: [dotfiles-macos/qnap/](https://github.com/KonradLanz/dotfiles-macos/tree/main/qnap)
