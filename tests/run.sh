#!/bin/sh
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/vbmeta-test.XXXXXX")
PASS=0
FAIL=0
CURRENT=

cleanup() {
  rm -rf "$WORK"
}
trap cleanup EXIT

ok() {
  PASS=$((PASS + 1))
  printf 'PASS  %s: %s\n' "$CURRENT" "$1"
}

bad() {
  FAIL=$((FAIL + 1))
  printf 'FAIL  %s: %s\n' "$CURRENT" "$1"
}

assert_eq() {
  label=$1
  want=$2
  got=$3
  if [ "$want" = "$got" ]; then
    ok "$label"
  else
    bad "$label (want=$want got=$got)"
  fi
}

assert_ne() {
  label=$1
  unwanted=$2
  got=$3
  if [ "$unwanted" != "$got" ]; then
    ok "$label"
  else
    bad "$label (must differ from $unwanted)"
  fi
}

mkfixture() {
  file=$1
  flags=${2:-0}
  dd if=/dev/zero of="$file" bs=512 count=1 2>/dev/null
  printf 'AVB0' | dd of="$file" bs=1 seek=0 conv=notrunc 2>/dev/null
  printf '\000\000\000\001' | dd of="$file" bs=1 seek=4 conv=notrunc 2>/dev/null
  b1=$(( (flags >> 24) & 255 ))
  b2=$(( (flags >> 16) & 255 ))
  b3=$(( (flags >> 8) & 255 ))
  b4=$(( flags & 255 ))
  printf '%b' "$(printf '\\%03o' "$b1")$(printf '\\%03o' "$b2")$(printf '\\%03o' "$b3")$(printf '\\%03o' "$b4")" | dd of="$file" bs=1 seek=120 conv=notrunc 2>/dev/null
}

begin() {
  CURRENT=$1
  CASE=$WORK/$CURRENT
  mkdir -p "$CASE/by-name" "$CASE/state" "$CASE/sysfs" "$CASE/mirror"
  VB_BYNAME_DIR=$CASE/by-name
  VB_SYSFS_DIR=$CASE/sysfs
  VB_MIRROR_DIR=$CASE/mirror
  VB_ALLOW_REGULAR=1
  VB_BOOT_LOCKED=0
  VB_SLOT=
  VB_BUILD_ID=build-one
  VB_FORCE=
  VB_MODDIR=
  STATE_DIR=$CASE/state
  export VB_BYNAME_DIR VB_SYSFS_DIR VB_MIRROR_DIR VB_ALLOW_REGULAR
  export VB_BOOT_LOCKED VB_SLOT VB_BUILD_ID VB_FORCE VB_MODDIR STATE_DIR
  unset BYNAME_DIR
  . "$ROOT/common/vbmeta.sh"
}

add_part() {
  name=$1
  flags=${2:-0}
  file=$VB_BYNAME_DIR/$name
  mkfixture "$file" "$flags"
  mkdir -p "$VB_SYSFS_DIR/$name"
  printf '1\n' > "$VB_SYSFS_DIR/$name/size"
}

file_flags() {
  dd if="$1" bs=1 skip=120 count=4 2>/dev/null | od -An -tu1 2>/dev/null | awk 'NF==4 { printf "%d", ($1 * 16777216) + ($2 * 65536) + ($3 * 256) + $4 }'
}

begin flags_roundtrip
add_part vbmeta 0
flags_write "$VB_BYNAME_DIR/vbmeta" 3
assert_eq "write then read" 3 "$(flags_read "$VB_BYNAME_DIR/vbmeta")"
flags_write "$VB_BYNAME_DIR/vbmeta" 0
assert_eq "write zero then read" 0 "$(flags_read "$VB_BYNAME_DIR/vbmeta")"

begin header_validation
add_part vbmeta 0
printf 'JUNKJUNK' > "$CASE/notavb.img"
dd if=/dev/zero of="$CASE/short.img" bs=1 count=128 2>/dev/null
if vbmeta_file_valid "$VB_BYNAME_DIR/vbmeta"; then ok "accepts valid image"; else bad "accepts valid image"; fi
if vbmeta_file_valid "$CASE/notavb.img"; then bad "rejects bad magic"; else ok "rejects bad magic"; fi
if vbmeta_file_valid "$CASE/short.img"; then bad "rejects short image"; else ok "rejects short image"; fi

begin backup_creates_artifacts
add_part vbmeta 0
before=$(sha256sum "$VB_BYNAME_DIR/vbmeta" | cut -d' ' -f1)
backup_one vbmeta >/dev/null 2>&1
assert_eq "backup hash file" "$before" "$(cat "$BACKUP_DIR/vbmeta.img.sha256" 2>/dev/null)"
assert_eq "backup meta build" "build-one" "$(meta_get "$BACKUP_DIR/vbmeta.img.meta" build)"
assert_eq "backup meta size" 512 "$(meta_get "$BACKUP_DIR/vbmeta.img.meta" size)"
if [ -f "$VB_MIRROR_DIR/vbmeta.img" ]; then ok "mirror copy written"; else bad "mirror copy written"; fi

begin patch_sets_flags
add_part vbmeta 0
patch_all >/dev/null 2>&1
assert_eq "device flags after patch" 3 "$(file_flags "$VB_BYNAME_DIR/vbmeta")"
assert_eq "state after patch" "patched" "$(state_get)"

begin restore_returns_original
add_part vbmeta 0
before=$(sha256sum "$VB_BYNAME_DIR/vbmeta" | cut -d' ' -f1)
patch_all >/dev/null 2>&1
restore_all >/dev/null 2>&1
assert_eq "hash after restore" "$before" "$(sha256sum "$VB_BYNAME_DIR/vbmeta" | cut -d' ' -f1)"
assert_eq "state after restore" "restored" "$(state_get)"

begin patch_is_idempotent
add_part vbmeta 0
patch_all >/dev/null 2>&1
count_before=$(grep -c "already disabled" "$BACKUP_DIR/../patch.log" 2>/dev/null || true)
patch_all >/dev/null 2>&1
count_after=$(grep -c "already disabled" "$BACKUP_DIR/../patch.log" 2>/dev/null || true)
assert_eq "second run logs already disabled" "1" "$((count_after - count_before))"
assert_eq "flags stay disabled" 3 "$(file_flags "$VB_BYNAME_DIR/vbmeta")"

begin locked_bootloader_refused
add_part vbmeta 0
VB_BOOT_LOCKED=1
if patch_all >/dev/null 2>&1; then bad "refuses locked bootloader"; else ok "refuses locked bootloader"; fi
assert_eq "flags untouched" 0 "$(file_flags "$VB_BYNAME_DIR/vbmeta")"

begin inactive_slot_skipped
add_part vbmeta_a 0
add_part vbmeta_b 0
VB_SLOT=_a
patch_all >/dev/null 2>&1
assert_eq "active slot patched" 3 "$(file_flags "$VB_BYNAME_DIR/vbmeta_a")"
assert_eq "inactive slot untouched" 0 "$(file_flags "$VB_BYNAME_DIR/vbmeta_b")"

begin non_vbmeta_partition_refused
mkdir -p "$VB_BYNAME_DIR"
mkfixture "$VB_BYNAME_DIR/vbmeta" 0
printf 'NOPE' | dd of="$VB_BYNAME_DIR/vbmeta" bs=1 seek=0 conv=notrunc 2>/dev/null
mkdir -p "$VB_SYSFS_DIR/vbmeta"
printf '1\n' > "$VB_SYSFS_DIR/vbmeta/size"
mkdir -p "$BACKUP_DIR"
mkfixture "$BACKUP_DIR/vbmeta.img" 0
printf '%s\n' "$(sha256sum "$BACKUP_DIR/vbmeta.img" | cut -d' ' -f1)" > "$BACKUP_DIR/vbmeta.img.sha256"
if patch_one vbmeta >/dev/null 2>&1; then bad "refuses non-avb target"; else ok "refuses non-avb target"; fi

begin build_mismatch_blocks_restore
add_part vbmeta 0
patch_all >/dev/null 2>&1
VB_BUILD_ID=build-two
if restore_all >/dev/null 2>&1; then bad "blocks stale restore"; else ok "blocks stale restore"; fi
assert_eq "flags still disabled" 3 "$(file_flags "$VB_BYNAME_DIR/vbmeta")"
VB_FORCE=1
restore_all >/dev/null 2>&1
assert_eq "force overrides build guard" 0 "$(file_flags "$VB_BYNAME_DIR/vbmeta")"

begin rollback_on_second_partition_failure
add_part vbmeta 0
add_part vbmeta_system 0
printf 'JUNK' | dd of="$VB_BYNAME_DIR/vbmeta_system" bs=1 seek=0 conv=notrunc 2>/dev/null
patch_all >/dev/null 2>&1
assert_eq "first partition rolled back" 0 "$(file_flags "$VB_BYNAME_DIR/vbmeta")"
assert_eq "state not patched" "" "$(state_get)"

begin setup_is_recreated
rm -f "$CONFIG_FILE"
ensure_setup
if [ -f "$CONFIG_FILE" ]; then ok "config recreated"; else bad "config recreated"; fi
assert_eq "default auto patch" "1" "$(cfg_get AUTO_PATCH 0)"
assert_eq "default max attempts" "3" "$(cfg_get MAX_ATTEMPTS 0)"

begin uninstall_restores
add_part vbmeta 0
before=$(sha256sum "$VB_BYNAME_DIR/vbmeta" | cut -d' ' -f1)
patch_all >/dev/null 2>&1
STATE_DIR="$CASE/state" sh "$ROOT/uninstall.sh" >/dev/null 2>&1
assert_eq "hash restored by uninstall" "$before" "$(sha256sum "$VB_BYNAME_DIR/vbmeta" | cut -d' ' -f1)"

begin auto_patch_halts_after_max
add_part vbmeta 0
printf 'AUTO_PATCH=1\nMAX_ATTEMPTS=2\n' > "$CONFIG_FILE"
touch "$STATE_DIR/auto_pending"
VB_BOOT_LOCKED=1
run_boot >/dev/null 2>&1
run_boot >/dev/null 2>&1
run_boot >/dev/null 2>&1
if [ -f "$STATE_DIR/auto_pending" ]; then bad "auto pending cleared after max"; else ok "auto pending cleared after max"; fi

begin stale_backup_replaced
add_part vbmeta 0
patch_all >/dev/null 2>&1
mkfixture "$VB_BYNAME_DIR/vbmeta" 0
VB_BUILD_ID=build-two
patch_all >/dev/null 2>&1
assert_eq "new backup build" "build-two" "$(meta_get "$BACKUP_DIR/vbmeta.img.meta" build)"
if ls "$BACKUP_DIR"/vbmeta.img.stale-* >/dev/null 2>&1; then ok "stale backup archived"; else bad "stale backup archived"; fi
assert_eq "fresh backup is a clean image" 0 "$(file_flags "$BACKUP_DIR/vbmeta.img")"
assert_eq "device patched again" 3 "$(file_flags "$VB_BYNAME_DIR/vbmeta")"

begin toggle_patches_when_clean
add_part vbmeta 0
printf 'patched\n' > "$STATE_FILE"
run_toggle >/dev/null 2>&1
assert_eq "toggle patches a clean device" 3 "$(file_flags "$VB_BYNAME_DIR/vbmeta")"
assert_eq "toggle records patched" "patched" "$(state_get)"

begin toggle_restores_when_patched
add_part vbmeta 0
patch_all >/dev/null 2>&1
run_toggle >/dev/null 2>&1
assert_eq "toggle restores a patched device" 0 "$(file_flags "$VB_BYNAME_DIR/vbmeta")"
assert_eq "toggle records restored" "restored" "$(state_get)"

begin flags_state_mixed
add_part vbmeta 0
add_part vbmeta_system 3
assert_eq "mixed state detected" "mixed" "$(flags_state)"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
