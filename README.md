CONFIG
======

Path config file: `un.machines.snapshot/config.cfg`
Vars:

```sh
SNAPSHOTS_BASE="/.snapshots"
SNAPSHOTS_MAX_NUM=7
INCLUDE_MACHINES=()
EXCLUDE_MACHINES=()
```

REQUIRES / EXPECTS
==================

- systemd-nspawn containers in `/var/lib/machines`
- btrfs subvolumes in `/var/lib/machines/<machine>` for each container

NOTES
=====

- Look for systemd-nspawn machines in /var/lib/machines
- Snapshot them
- Clean-up old snapshots