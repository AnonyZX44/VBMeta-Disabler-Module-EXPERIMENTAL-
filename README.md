# vbmeta auto disable

Flips the verification and verity flags inside your vbmeta partitions, so a modified boot image stops getting rejected. Backs up first, checks every write, and can put everything back.

**Use at your own risk.** This writes raw bytes to the partition that decides whether your phone boots. A bad write means a bootloop, and the way out is a fastboot flash of the stock vbmeta for your exact firmware. Nobody is going to fix your phone for you. If you don't have a PC and the stock firmware handy, don't install this.

## What it does

A vbmeta header starts with `AVB0`. At offset 120 sits a 32-bit flags field: bit 0 disables hashtree verification, bit 1 disables verification entirely. This module sets both. That's the whole patch.

It reads the header before writing and refuses to touch a partition without the `AVB0` magic and major version 1, so it can't drop four bytes into something random.

Before the first write it dumps the partition, records the sha256 and the build id it came from, mirrors the image to `/sdcard/backupvb`, then patches. After the write it reads those four bytes back. If they don't match, every partition touched during that run gets restored.

Restore refuses a backup taken from a different build. That guard exists because restoring an old vbmeta after an OTA is a clean way to brick a phone that would otherwise boot fine. If you know what you're doing, `restore.sh --force` skips it.

## Install

Flash the zip from your root manager. Magisk, KernelSU, KernelSU Next, SukiSU Ultra and APatch all work. Nothing depends on `util_functions.sh`, and if a manager skips `customize.sh`, `post-fs-data.sh` sets things up on the first boot instead.

The patch is scheduled for the next boot, not applied during install. Reboot after flashing.

## Action button

Toggles patch and restore. It reads the real flags on the partitions instead of trusting a state file, so after an OTA it patches again rather than getting stuck trying to restore.

## Config

`/data/adb/vbmeta_auto_disable/config`

```
AUTO_PATCH=1        patch on boot
AUTO_REBOOT=0       reboot when the patch succeeds
PATCH_ALL_SLOTS=0   1 patches both A/B slots
MAX_ATTEMPTS=3      failed boots before auto patch gives up
```

Only the active slot gets patched by default.

## When it goes wrong

Log: `/data/adb/vbmeta_auto_disable/patch.log`
Backups: `/data/adb/vbmeta_auto_disable/backup` and `/sdcard/backupvb`

```
su
sh /data/adb/vbmeta_auto_disable/restore.sh
```

Add `--force` if the build guard is what's blocking you.

That restore script survives module removal on purpose, so uninstalling the module doesn't leave you with a patched vbmeta and no way back. If the phone won't boot at all, fastboot flash the stock vbmeta from your firmware.

A locked bootloader can't be helped. The module checks `ro.boot.verifiedbootstate` and `ro.boot.flash.locked`, and refuses to patch when the device is locked or green.
