STATE_DIR=${STATE_DIR:-/data/adb/vbmeta_auto_disable}
BACKUP_DIR=$STATE_DIR/backup
LOG_FILE=$STATE_DIR/patch.log
STATE_FILE=$STATE_DIR/state
RECORDS=$STATE_DIR/records
CONFIG_FILE=$STATE_DIR/config
SEEN_FILE=$STATE_DIR/seen
ATTEMPTS_FILE=$STATE_DIR/attempts
BYNAME_DIR=${BYNAME_DIR:-}

log_line() {
  mkdir -p "$STATE_DIR" 2>/dev/null
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG_FILE" 2>/dev/null
}

fail() {
  log_line "ERROR $*"
  printf 'ERROR: %s\n' "$*" >&2
  return 1
}

is_uint() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
  esac
  return 0
}

cfg_get() {
  key=$1
  def=$2
  if [ -f "$CONFIG_FILE" ]; then
    value=$(awk -F= -v k="$key" '$1==k { sub(/^[^=]*=/, ""); last=$0 } END { if (last != "") print last }' "$CONFIG_FILE" 2>/dev/null)
    if [ -n "$value" ]; then
      printf '%s' "$value"
      return 0
    fi
  fi
  printf '%s' "$def"
}

meta_get() {
  file=$1
  key=$2
  [ -f "$file" ] || return 0
  awk -F= -v k="$key" '$1==k { sub(/^[^=]*=/, ""); print; exit }' "$file" 2>/dev/null
}

state_get() {
  head -n 1 "$STATE_FILE" 2>/dev/null
}

state_set() {
  mkdir -p "$STATE_DIR" 2>/dev/null
  printf '%s\n' "$1" > "$STATE_FILE.tmp" 2>/dev/null || return 1
  mv -f "$STATE_FILE.tmp" "$STATE_FILE" 2>/dev/null
}

root_manager() {
  if [ -d /data/adb/magisk ]; then
    printf 'Magisk'
  elif [ -d /data/adb/ksu ]; then
    printf 'KernelSU'
  elif [ -d /data/adb/ap ]; then
    printf 'APatch'
  else
    printf 'unknown'
  fi
}

boot_state_text() {
  v=$(getprop ro.boot.verifiedbootstate 2>/dev/null)
  l=$(getprop ro.boot.flash.locked 2>/dev/null)
  [ -n "$v" ] || v=unknown
  [ -n "$l" ] || l=unknown
  printf 'verifiedbootstate=%s locked=%s' "$v" "$l"
}

boot_locked() {
  if [ -n "$VB_BOOT_LOCKED" ]; then
    [ "$VB_BOOT_LOCKED" = "1" ]
    return $?
  fi
  vstate=$(getprop ro.boot.verifiedbootstate 2>/dev/null)
  flock=$(getprop ro.boot.flash.locked 2>/dev/null)
  case "$vstate" in
    green) return 0 ;;
    orange|yellow) return 1 ;;
  esac
  [ "$flock" = "1" ] && return 0
  return 1
}

current_slot() {
  if [ -n "$VB_SLOT" ]; then
    printf '%s' "$VB_SLOT"
    return 0
  fi
  s=$(getprop ro.boot.slot_suffix 2>/dev/null)
  if [ -z "$s" ]; then
    raw=$(getprop ro.boot.slot 2>/dev/null)
    [ -n "$raw" ] && s="_$raw"
  fi
  printf '%s' "$s"
}

slot_mismatch() {
  case "$1" in
    *_a|*_b) ;;
    *) return 1 ;;
  esac
  cur=$(current_slot)
  case "$cur" in
    _a|_b) ;;
    *) return 1 ;;
  esac
  case "$1" in
    *"$cur") return 1 ;;
  esac
  return 0
}

build_id() {
  if [ -n "$VB_BUILD_ID" ]; then
    printf '%s' "$VB_BUILD_ID"
    return 0
  fi
  printf '%s|%s|%s|%s' \
    "$(getprop ro.build.fingerprint 2>/dev/null)" \
    "$(getprop ro.build.version.incremental 2>/dev/null)" \
    "$(getprop ro.product.device 2>/dev/null)" \
    "$(getprop ro.boot.hardware 2>/dev/null)"
}

is_blockish() {
  [ -b "$1" ] && return 0
  [ "$VB_ALLOW_REGULAR" = "1" ] && [ -f "$1" ] && return 0
  return 1
}

byname_dir() {
  if [ -n "$VB_BYNAME_DIR" ]; then
    printf '%s' "$VB_BYNAME_DIR"
    return 0
  fi
  for d in /dev/block/by-name /dev/block/bootdevice/by-name /dev/block/platform/*/by-name /dev/block/platform/*/*/by-name; do
    [ -d "$d" ] || continue
    found=
    for node in "$d"/vbmeta*; do
      [ -e "$node" ] || continue
      found=1
      break
    done
    [ -n "$found" ] || continue
    printf '%s' "$d"
    return 0
  done
  return 1
}

byname_cached() {
  if [ -z "$BYNAME_DIR" ]; then
    BYNAME_DIR=$(byname_dir) || return 1
  fi
  printf '%s' "$BYNAME_DIR"
}

part_dev() {
  dir=$(byname_cached) || return 1
  printf '%s/%s' "$dir" "$1"
}

part_list() {
  dir=$(byname_cached) || return 0
  for node in "$dir"/vbmeta*; do
    [ -e "$node" ] || continue
    printf '%s\n' "${node##*/}"
  done
}

part_bytes() {
  node=$(readlink -f "$1" 2>/dev/null)
  [ -n "$node" ] || node=$1
  base=${node##*/}
  sysdir=${VB_SYSFS_DIR:-/sys/class/block}
  sectors=$(cat "$sysdir/$base/size" 2>/dev/null)
  if is_uint "$sectors"; then
    printf '%s' $((sectors * 512))
    return 0
  fi
  blockdev --getsize64 "$1" 2>/dev/null
}

read_magic() {
  dd if="$1" bs=1 count=4 2>/dev/null
}

read_major() {
  dd if="$1" bs=1 skip=4 count=4 2>/dev/null | od -An -tx1 2>/dev/null | tr -d ' \n'
}

avb_magic_ok() {
  is_blockish "$1" || return 1
  [ "$(read_magic "$1")" = "AVB0" ] || return 1
  [ "$(read_major "$1")" = "00000001" ]
}

vbmeta_file_valid() {
  [ -f "$1" ] || return 1
  size=$(wc -c < "$1" 2>/dev/null)
  is_uint "$size" || return 1
  [ "$size" -ge 256 ] || return 1
  [ "$(read_magic "$1")" = "AVB0" ] || return 1
  [ "$(read_major "$1")" = "00000001" ]
}

flags_read() {
  dd if="$1" bs=1 skip=120 count=4 2>/dev/null | od -An -tu1 2>/dev/null | awk 'NF==4 { v = ($1 * 16777216) + ($2 * 65536) + ($3 * 256) + $4; seen = 1 } END { if (seen) printf "%d", v; else exit 1 }'
}

flags_write() {
  dev=$1
  value=$2
  seq=
  shift_by=24
  while [ "$shift_by" -ge 0 ]; do
    byte=$(( (value >> shift_by) & 255 ))
    seq="$seq$(printf '\\%03o' "$byte")"
    shift_by=$((shift_by - 8))
  done
  printf '%b' "$seq" | dd of="$dev" bs=1 seek=120 conv=notrunc 2>/dev/null || return 1
  sync
  return 0
}

mirror_root() {
  if [ -n "$VB_MIRROR_DIR" ]; then
    mkdir -p "$VB_MIRROR_DIR" 2>/dev/null || return 1
    printf '%s' "$VB_MIRROR_DIR"
    return 0
  fi
  if mkdir -p /sdcard/backupvb 2>/dev/null && [ -d /sdcard/backupvb ]; then
    printf '%s' /sdcard/backupvb
    return 0
  fi
  if mkdir -p /data/media/0/backupvb 2>/dev/null && [ -d /data/media/0/backupvb ]; then
    printf '%s' /data/media/0/backupvb
    return 0
  fi
  return 1
}

mirror_one() {
  name=$1
  src=$BACKUP_DIR/$name.img
  [ -f "$src" ] || return 0
  root=$(mirror_root) || { log_line "mirror unavailable for $name"; return 0; }
  cp -f "$src" "$root/$name.img" 2>/dev/null || { log_line "mirror copy failed for $name"; return 0; }
  cp -f "$src.sha256" "$root/$name.sha256" 2>/dev/null
  cp -f "$src.meta" "$root/$name.meta" 2>/dev/null
  chmod 0644 "$root/$name.img" "$root/$name.sha256" "$root/$name.meta" 2>/dev/null
  chown 1023:1023 "$root/$name.img" "$root/$name.sha256" "$root/$name.meta" 2>/dev/null
  printf '%s backup=%s sha256=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$root/$name.img" "$(cat "$src.sha256" 2>/dev/null)" >> "$root/manifest.txt" 2>/dev/null
  chmod 0644 "$root/manifest.txt" 2>/dev/null
  chown 1023:1023 "$root/manifest.txt" 2>/dev/null
  restorecon -R "$root" 2>/dev/null
  return 0
}

mirror_sync() {
  root=$(mirror_root) || return 0
  [ -f "$root/$1.img" ] && return 0
  mirror_one "$1"
}

record_add() {
  mkdir -p "$STATE_DIR" 2>/dev/null
  printf '%s\n' "$1" >> "$RECORDS" 2>/dev/null
}

seen_check() {
  dev=$(part_dev "$1") || dev=$1
  resolved=$(readlink -f "$dev" 2>/dev/null)
  [ -n "$resolved" ] || resolved=$dev
  if grep -qxF "$resolved" "$SEEN_FILE" 2>/dev/null; then
    return 0
  fi
  printf '%s\n' "$resolved" >> "$SEEN_FILE"
  return 1
}

install_standalone() {
  moddir=$1
  src=$moddir/common/vbmeta.sh
  [ -f "$src" ] || return 1
  cp -f "$src" "$STATE_DIR/vbmeta.sh" 2>/dev/null || return 1
  {
    printf '#!/system/bin/sh\n'
    printf 'STATE_DIR=%s\n' "$STATE_DIR"
    printf '%s\n' ". \"\$STATE_DIR/vbmeta.sh\""
    printf 'restore_all\n'
  } > "$STATE_DIR/restore.sh" 2>/dev/null || return 1
  chmod 0644 "$STATE_DIR/vbmeta.sh" 2>/dev/null
  chmod 0755 "$STATE_DIR/restore.sh" 2>/dev/null
  return 0
}

ensure_setup() {
  mkdir -p "$STATE_DIR" "$BACKUP_DIR" 2>/dev/null
  if [ ! -f "$CONFIG_FILE" ]; then
    printf 'AUTO_PATCH=1\nAUTO_REBOOT=0\nPATCH_ALL_SLOTS=0\nMAX_ATTEMPTS=3\n' > "$CONFIG_FILE" 2>/dev/null
  fi
  if [ ! -f "$STATE_DIR/vbmeta.sh" ] && [ -n "$VB_MODDIR" ]; then
    install_standalone "$VB_MODDIR"
  fi
  return 0
}

backup_one() {
  name=$1
  dev=$(part_dev "$name") || { fail "partition path unresolved: $name"; return 1; }
  is_blockish "$dev" || { fail "partition missing: $name"; return 1; }
  avb_magic_ok "$dev" || { fail "not a vbmeta partition: $name"; return 1; }
  bytes=$(part_bytes "$dev")
  is_uint "$bytes" || { fail "partition size unreadable: $name"; return 1; }
  [ "$bytes" -ge 256 ] || { fail "partition too small: $name"; return 1; }
  mkdir -p "$BACKUP_DIR" 2>/dev/null
  dest=$BACKUP_DIR/$name.img
  if [ -f "$dest" ]; then
    if ! vbmeta_file_valid "$dest"; then
      fail "existing backup corrupt: $name"
      return 1
    fi
    stored=$(cat "$dest.sha256" 2>/dev/null)
    actual=$(sha256sum "$dest" | cut -d' ' -f1)
    if [ "$stored" != "$actual" ]; then
      fail "backup checksum mismatch: $name"
      return 1
    fi
    old_build=$(meta_get "$dest.meta" build)
    now_build=$(build_id)
    if [ -n "$old_build" ] && [ "$old_build" != "$now_build" ]; then
      stamp=$(printf '%s' "$old_build" | sha256sum | cut -c1-8)
      if ! mv -f "$dest" "$dest.stale-$stamp"; then
        fail "stale backup archive failed: $name"
        return 1
      fi
      mv -f "$dest.sha256" "$dest.sha256.stale-$stamp" 2>/dev/null
      mv -f "$dest.meta" "$dest.meta.stale-$stamp" 2>/dev/null
      log_line "stale backup archived: $name -> $dest.stale-$stamp"
    else
      log_line "backup kept: $name sha256=$actual"
      mirror_sync "$name"
      return 0
    fi
  fi
  tmp=$dest.part
  rm -f "$tmp"
  if ! dd if="$dev" of="$tmp" bs=4096 conv=fsync 2>/dev/null; then
    rm -f "$tmp"
    fail "backup read failed: $name"
    return 1
  fi
  if ! vbmeta_file_valid "$tmp"; then
    rm -f "$tmp"
    fail "backup failed validation: $name"
    return 1
  fi
  bsize=$(wc -c < "$tmp" 2>/dev/null)
  if [ "$bsize" != "$bytes" ]; then
    rm -f "$tmp"
    fail "backup size mismatch: $name backup=$bsize device=$bytes"
    return 1
  fi
  hash=$(sha256sum "$tmp" | cut -d' ' -f1)
  if ! mv -f "$tmp" "$dest"; then
    rm -f "$tmp"
    fail "backup move failed: $name"
    return 1
  fi
  printf '%s\n' "$hash" > "$dest.sha256"
  {
    printf 'name=%s\n' "$name"
    printf 'sha256=%s\n' "$hash"
    printf 'size=%s\n' "$bytes"
    printf 'build=%s\n' "$(build_id)"
    printf 'slot=%s\n' "$(current_slot)"
    printf 'created=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
  } > "$dest.meta"
  flags=$(flags_read "$dest" 2>/dev/null)
  log_line "backup stored: $name size=$bytes sha256=$hash flags=0x$(printf '%x' "${flags:-0}")"
  if is_uint "$flags" && [ $((flags & 3)) -ne 0 ]; then
    log_line "warning: $name already carried verification flags before backup"
  fi
  mirror_one "$name"
}

patch_one() {
  name=$1
  dev=$(part_dev "$name") || { fail "partition path unresolved: $name"; return 1; }
  dest=$BACKUP_DIR/$name.img
  if [ ! -f "$dest" ]; then
    fail "no backup for $name"
    return 1
  fi
  if ! avb_magic_ok "$dev"; then
    fail "not a vbmeta partition: $name"
    return 1
  fi
  cur=$(flags_read "$dev" 2>/dev/null)
  if ! is_uint "$cur"; then
    fail "flags unreadable: $name"
    return 1
  fi
  record_add "$name"
  if [ $((cur & 3)) -eq 3 ]; then
    log_line "already disabled: $name flags=0x$(printf '%x' "$cur")"
    return 0
  fi
  wanted=$((cur | 3))
  if ! flags_write "$dev" "$wanted"; then
    fail "write failed: $name"
    return 1
  fi
  got=$(flags_read "$dev" 2>/dev/null)
  if [ "$got" != "$wanted" ]; then
    fail "readback mismatch: $name want=0x$(printf '%x' "$wanted") got=0x$(printf '%x' "${got:-0}")"
    return 1
  fi
  log_line "patched: $name 0x$(printf '%x' "$cur") -> 0x$(printf '%x' "$got")"
}

restore_one() {
  name=$1
  dev=$(part_dev "$name") || { fail "partition path unresolved: $name"; return 1; }
  dest=$BACKUP_DIR/$name.img
  if [ ! -f "$dest" ]; then
    fail "no backup for $name"
    return 1
  fi
  if ! vbmeta_file_valid "$dest"; then
    fail "backup invalid: $name"
    return 1
  fi
  stored=$(cat "$dest.sha256" 2>/dev/null)
  actual=$(sha256sum "$dest" | cut -d' ' -f1)
  if [ "$stored" != "$actual" ]; then
    fail "backup checksum mismatch: $name"
    return 1
  fi
  if [ "$VB_FORCE" != "1" ]; then
    want_build=$(meta_get "$dest.meta" build)
    now_build=$(build_id)
    if [ -n "$want_build" ] && [ "$want_build" != "$now_build" ]; then
      fail "backup build mismatch: $name backup=$want_build current=$now_build"
      return 1
    fi
  fi
  is_blockish "$dev" || { fail "partition missing: $name"; return 1; }
  if ! avb_magic_ok "$dev"; then
    fail "target not a vbmeta partition: $name"
    return 1
  fi
  bytes=$(part_bytes "$dev")
  bsize=$(wc -c < "$dest" 2>/dev/null)
  if is_uint "$bytes" && [ "$bytes" != "$bsize" ]; then
    fail "backup size mismatch: $name backup=$bsize device=$bytes"
    return 1
  fi
  current_hash=$(dd if="$dev" bs=4096 2>/dev/null | sha256sum | cut -d' ' -f1)
  if [ "$current_hash" = "$stored" ]; then
    log_line "already restored: $name"
    return 0
  fi
  if ! dd if="$dest" of="$dev" bs=4096 conv=fsync 2>/dev/null; then
    fail "restore write failed: $name"
    return 1
  fi
  sync
  got=$(dd if="$dev" bs=4096 2>/dev/null | sha256sum | cut -d' ' -f1)
  if [ "$got" != "$stored" ]; then
    fail "restore verify failed: $name"
    return 1
  fi
  log_line "restored: $name sha256=$got"
}

rollback_all() {
  [ -f "$RECORDS" ] || return 0
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    restore_one "$name" || log_line "rollback failed: $name"
  done < "$RECORDS"
  log_line "rollback finished"
}

patch_all() {
  if boot_locked; then
    fail "bootloader locked or verified boot green, refusing to patch"
    return 1
  fi
  ensure_setup
  mkdir -p "$STATE_DIR" "$BACKUP_DIR" 2>/dev/null
  : > "$RECORDS"
  : > "$SEEN_FILE"
  all_slots=$(cfg_get PATCH_ALL_SLOTS 0)
  found=0
  for name in $(part_list); do
    if [ "$all_slots" != "1" ] && slot_mismatch "$name"; then
      log_line "inactive slot skipped: $name"
      continue
    fi
    if seen_check "$name"; then
      log_line "duplicate partition skipped: $name"
      continue
    fi
    found=$((found + 1))
    if ! backup_one "$name"; then
      rollback_all
      return 1
    fi
    if ! patch_one "$name"; then
      rollback_all
      return 1
    fi
  done
  if [ "$found" -eq 0 ]; then
    fail "no vbmeta partition found"
    return 1
  fi
  state_set patched
  log_line "patch complete: $found partition(s)"
  return 0
}

restore_all() {
  ensure_setup
  count=0
  failed=0
  skipped=0
  if [ -d "$BACKUP_DIR" ]; then
    for img in "$BACKUP_DIR"/*.img; do
      [ -f "$img" ] || continue
      name=${img##*/}
      name=${name%.img}
      dev=$(part_dev "$name" 2>/dev/null)
      if [ -z "$dev" ] || [ ! -e "$dev" ]; then
        skipped=$((skipped + 1))
        log_line "restore skipped, partition absent: $name"
        continue
      fi
      if restore_one "$name"; then
        count=$((count + 1))
      else
        failed=$((failed + 1))
      fi
    done
  fi
  if [ "$count" -eq 0 ] && [ "$failed" -eq 0 ]; then
    if [ "$skipped" -ne 0 ]; then
      state_set restored
      log_line "restore complete: no present partition to write"
      return 0
    fi
    fail "no backup image found in $BACKUP_DIR"
    return 1
  fi
  if [ "$failed" -ne 0 ]; then
    fail "restore incomplete: $failed partition(s) failed"
    return 1
  fi
  state_set restored
  log_line "restore complete: $count partition(s)"
  return 0
}

run_boot() {
  ensure_setup
  if [ ! -f "$STATE_DIR/auto_pending" ]; then
    return 0
  fi
  if [ "$(cfg_get AUTO_PATCH 1)" != "1" ]; then
    log_line "auto patch disabled by config"
    return 0
  fi
  max=$(cfg_get MAX_ATTEMPTS 3)
  is_uint "$max" || max=3
  attempts=$(cat "$ATTEMPTS_FILE" 2>/dev/null)
  is_uint "$attempts" || attempts=0
  if [ "$attempts" -ge "$max" ]; then
    mv -f "$STATE_DIR/auto_pending" "$STATE_DIR/auto_disabled" 2>/dev/null
    log_line "auto patch halted after $attempts attempts, use the action button"
    return 1
  fi
  if patch_all; then
    rm -f "$STATE_DIR/auto_pending" "$STATE_DIR/auto_disabled"
    printf '0\n' > "$ATTEMPTS_FILE"
    log_line "auto patch done, verification off after next reboot"
    if [ "$(cfg_get AUTO_REBOOT 0)" = "1" ]; then
      log_line "auto reboot requested"
      sync
      reboot
    fi
    return 0
  fi
  attempts=$((attempts + 1))
  printf '%s\n' "$attempts" > "$ATTEMPTS_FILE"
  log_line "auto patch failed, attempt $attempts of $max"
  return 1
}

flags_state() {
  patched=0
  clean=0
  all_slots=$(cfg_get PATCH_ALL_SLOTS 0)
  for name in $(part_list); do
    if [ "$all_slots" != "1" ] && slot_mismatch "$name"; then
      continue
    fi
    dev=$(part_dev "$name" 2>/dev/null) || continue
    avb_magic_ok "$dev" || continue
    value=$(flags_read "$dev" 2>/dev/null) || continue
    is_uint "$value" || continue
    if [ $((value & 3)) -eq 3 ]; then
      patched=$((patched + 1))
    else
      clean=$((clean + 1))
    fi
  done
  if [ "$patched" -gt 0 ] && [ "$clean" -eq 0 ]; then
    printf 'patched'
    return 0
  fi
  if [ "$patched" -eq 0 ] && [ "$clean" -gt 0 ]; then
    printf 'clean'
    return 0
  fi
  if [ "$patched" -gt 0 ]; then
    printf 'mixed'
    return 0
  fi
  printf 'none'
}

run_toggle() {
  ensure_setup
  mode=$(flags_state)
  case "$mode" in
    patched)
      printf '%s\n' "all vbmeta partitions carry the disable flags, restoring"
      if restore_all; then
        printf '%s\n' "restored, reboot to apply"
        return 0
      fi
      printf '%s\n' "restore failed, see $LOG_FILE"
      return 1
      ;;
    none)
      printf '%s\n' "no vbmeta partition detected"
      return 1
      ;;
    *)
      printf '%s\n' "patching vbmeta ($mode)"
      if patch_all; then
        printf '%s\n' "patched, reboot to apply"
        return 0
      fi
      printf '%s\n' "patch failed, see $LOG_FILE"
      return 1
      ;;
  esac
}
