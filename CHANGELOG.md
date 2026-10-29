# Changelog

Fixes only.

## v1.1.0 — 2026-10-29

- The zip had no `META-INF`, so Magisk had nothing to run. Added `update-binary` and `updater-script`.
- `uninstall.sh` removed the module and left vbmeta patched. It restores first now, and a standalone restore script stays behind in `/data/adb/vbmeta_auto_disable`.
- Only Magisk worked. KernelSU, KernelSU Next, SukiSU Ultra and APatch are supported now, and setup reruns from `post-fs-data.sh` when the installer never ran.
- `/dev/block/by-name` was hardcoded. Discovery now checks `by-name`, `bootdevice/by-name` and both platform layouts.
- Nothing checked whether the bootloader was locked. Patching refuses on green verified boot, or on `flash.locked=1` without an orange or yellow state.
- Both A/B slots got patched. Only the active one now, unless `PATCH_ALL_SLOTS=1`.
- Restore compared sizes and nothing else, so a backup from a different build could be written over a fresh OTA vbmeta. Each backup now records its build id and restore refuses the mismatch. `--force` skips it.
- A backup taken before an OTA sat in the restore path forever. It gets archived as `.img.stale-<id>` and a fresh one is taken.
- The flag write built its byte sequence from a format string made out of variables. It emits escaped bytes one at a time now.
- A failure halfway through left some partitions patched and some not. Any failure rolls back the whole run.
- Nothing validated the live partition before writing. It now has to carry `AVB0` and major version 1.
- The boot retry had no limit. Capped at `MAX_ATTEMPTS`, after which it waits for the action button.
- `state` was written in place, so a bad shutdown could leave it half written. It goes through a temp file now.
- Config parsing used `sed` with a raw pattern. Now `awk` with an exact key match.
- The action button trusted the state file. It reads the live partition flags now, so an OTA doesn't leave it stuck on the restore path.
- The same device node behind two by-name symlinks got patched twice. It's counted once now.
- Restore wrote even when the partition already matched the backup. It's a no-op now.
- Duplicate `record` entries piled up across runs. The list resets each time now.
