# Incident: /root/ Flash Overflow

**Date:** 2026-06-17  
**Severity:** High (blocked all git clone operations)  
**Status:** Resolved

## What happened

Attempt to clone all repos under `/root/git/` via `gh repo list | gh repo clone`
failed with `No space left on device` errors.

```
error: unable to write file utils/zsh/patches/...
fatal: unable to checkout working tree
error: copy-fd: write returned: No space left on device
```

`/root` is a 400 MB tmpfs/flash partition. It was at 100% usage.

## Root cause

`entware-packages` repo — 57 MB of OpenWRT/Entware package Makefiles —
was cloned directly to `/root/git/entware-packages/`, consuming ~14% of
the total available flash space in a single repo. Combined with the other
repos already present, this pushed the partition to 100%.

```
57M   /root/git/entware-packages/   ← culprit
```

## Resolution

```bash
# 1. Remove the large repo
rm -rf /root/git/entware-packages

# 2. Move all repos to storage volume
mkdir -p /share/homes/DOMAIN=AD/koni/git
mv /root/git/* /share/homes/DOMAIN=AD/koni/git/
rmdir /root/git
ln -s /share/homes/DOMAIN=AD/koni/git /root/git

# 3. Re-clone failed repos
cd /root/git
gh repo clone KonradLanz/bootstrap-foundation
gh repo clone KonradLanz/historic-email-vcard-rfc
gh repo clone KonradLanz/paperless-ngx-qnap
# entware-packages: only clone if actively needed, not as default
```

## Prevention

1. `/root/git` must always be a symlink to `/share/homes/.../git`
2. Add `entware-packages` to a `.cloneexclude` list in bootstrap-foundation
3. The `gh repo list | clone` loop should check available space before each clone:

```bash
check_space() {
  available=$(df -k /root/git | awk 'NR==2{print $4}')
  if [ "$available" -lt 51200 ]; then  # < 50 MB remaining
    echo "ERROR: less than 50MB left on $(df -k /root/git | awk 'NR==2{print $1}')" >&2
    exit 1
  fi
}
```

4. See `docs/storage-layout.md` for the full volume topology and placement rules.

## Related
- `docs/storage-layout.md` — volume map and placement guidelines
- `dotfiles-macos/qnap/fix-symlink-loops.sh` — other NAS hygiene issue from same session
