# Syncthing Setup — Dropbox-like sync across machines and Android

## Overview

Syncthing provides peer-to-peer file sync with no central server. Every device
syncs directly with every other device it can reach. If a device is offline,
changes sync when it comes back.

```
Desktop A  <──syncthing──>  Desktop B
    \                          /
     \                        /
      ──── Fairphone ────────
```

## Install

### Linux

```bash
sudo apt install syncthing
```

Enable as a user service so it starts on login:

```bash
systemctl --user enable --now syncthing
```

Verify it's running:

```bash
systemctl --user status syncthing
```

The web UI is at http://localhost:8384.

### Android (Fairphone)

Install **Syncthing** from **F-Droid** (not Play Store).

### macOS

```bash
brew install syncthing
brew services start syncthing
```

## Pair devices

1. On each machine, open the Syncthing web UI (http://localhost:8384 on desktop,
   or open the app on Android)
2. Find your Device ID: **Actions > Show ID** (it's a long alphanumeric string)
3. On machine A: **Add Remote Device** > paste machine B's Device ID
4. On machine B: accept the incoming device request (or add machine A's ID
   manually)
5. Repeat for every pair of devices that should talk to each other

Devices only need to be paired once. After that they auto-discover each other on
the local network and over the internet via relay servers.

## Share folders

1. On any device, click **Add Folder**
2. Set the **Folder Path** to the directory you want to sync (e.g. `~/org`)
3. Give it a **Folder Label** (e.g. "org files")
4. Under the **Sharing** tab, check every device that should receive this folder
5. On each receiving device, accept the folder share and choose a local path:
   - Linux: e.g. `~/org`
   - Android: e.g. `/storage/emulated/0/org` or `/sdcard/org`

### Recommended folder settings

| Setting               | Value              | Why                                          |
|-----------------------|--------------------|----------------------------------------------|
| Folder Type           | Send & Receive     | Bidirectional sync, like Dropbox              |
| Watch for Changes     | Enabled (default)  | Picks up file saves instantly via inotify     |
| Full Rescan Interval  | 3600 (1 hour)      | Safety net; inotify handles the real-time bit |
| File Versioning       | Staggered          | Keeps old versions in `.stversions/`          |

#### Staggered file versioning

This acts like Dropbox's version history. Old versions are kept in a
`.stversions/` directory inside the synced folder with the following retention:

- Versions from the last hour: one per 30 seconds
- Versions from the last day: one per hour
- Versions from the last month: one per day
- Older versions: one per week

Add `.stversions` to your `.gitignore` if the synced folder is a git repo.

## Android-specific settings

In the Syncthing Android app under **Settings**:

- **Run on Wi-Fi only**: recommended to save mobile data
- **Run while on battery**: up to you — Syncthing is lightweight but does use
  some battery
- **Respect battery optimization**: Android may kill Syncthing in the background.
  Go to **Settings > Apps > Syncthing > Battery > Unrestricted** to prevent this

### Orgzly Revived integration

1. Install **Orgzly Revived** from F-Droid
2. In Orgzly: **Settings > Sync > Repositories > Directory**
3. Point it at the same folder Syncthing is using (e.g. `/storage/emulated/0/org`)
4. Orgzly will read/write `.org` files directly — Syncthing handles the sync

## Conflict handling

If two devices edit the same file simultaneously before syncing, Syncthing
creates a conflict file named like:

```
notes.sync-conflict-20260316-120000-ABCDEFG.org
```

The original file gets one device's version; the conflict file gets the other.
You'll need to manually merge them.

In practice this is rare with org files since you're usually only editing on one
device at a time. To minimize conflicts:

- Let Syncthing finish syncing before editing (check the UI or wait a few
  seconds after opening your laptop)
- Emacs has `global-auto-revert-mode` enabled (already in init.org) which picks
  up on-disk changes via inotify nearly instantly, so your buffers stay current

## Firewall / network notes

Syncthing uses:

- **TCP 22000**: sync protocol (data transfer between devices)
- **UDP 21027**: local discovery (finds devices on the same LAN)

If devices are on the same LAN, sync is direct and fast. If they're on different
networks, Syncthing uses relay servers (encrypted, but slower). For best
performance, port-forward TCP 22000 on your router.

## Verifying it works

1. Create a test file on one machine:
   ```bash
   echo "sync test" > ~/org/test-sync.txt
   ```
2. Check the Syncthing web UI — you should see the folder update within seconds
3. Verify the file appears on the other device
4. Delete the test file when satisfied

## Useful commands

```bash
# Check service status
systemctl --user status syncthing

# View logs
journalctl --user -u syncthing -f

# Restart after config changes
systemctl --user restart syncthing
```

## Troubleshooting

| Problem                          | Fix                                                       |
|----------------------------------|-----------------------------------------------------------|
| Devices not connecting           | Check firewall for TCP 22000 / UDP 21027                  |
| Android kills Syncthing          | Disable battery optimization for the app                  |
| Slow sync over internet          | Port-forward TCP 22000 for direct connections             |
| Conflict files appearing         | Merge manually, consider editing on one device at a time  |
| Folder marked "Out of Sync"      | Click "Override Changes" on the authoritative device       |
| Changes not picked up in Emacs   | Verify `global-auto-revert-mode` is on (it is in init.org)|
