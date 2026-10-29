#!/system/bin/sh
MODPATH=${MODPATH:-$(pwd)}
if [ ! -f "$MODPATH/module.prop" ]; then
  MODPATH=$(cd "$(dirname "$0")" 2>/dev/null && pwd)
fi

if ! command -v ui_print >/dev/null 2>&1; then
  ui_print() { printf '%s\n' "$*"; }
fi
if ! command -v abort >/dev/null 2>&1; then
  abort() { ui_print "ABORT: $*"; exit 1; }
fi

ui_print "vbmeta auto disable v1.1.0"

for tool in dd od printf sha256sum readlink awk sed sync; do
  command -v "$tool" >/dev/null 2>&1 || abort "missing tool: $tool"
done

chown -R 0:0 "$MODPATH" 2>/dev/null
chmod 0755 "$MODPATH" "$MODPATH/common" "$MODPATH/META-INF" 2>/dev/null
chmod 0755 "$MODPATH/post-fs-data.sh" "$MODPATH/action.sh" "$MODPATH/restore.sh" "$MODPATH/uninstall.sh" "$MODPATH/customize.sh" 2>/dev/null
chmod 0644 "$MODPATH/common/vbmeta.sh" "$MODPATH/module.prop" "$MODPATH/sepolicy.rule" 2>/dev/null

STATE_DIR=/data/adb/vbmeta_auto_disable
mkdir -p "$STATE_DIR/backup" 2>/dev/null
if [ ! -f "$STATE_DIR/config" ]; then
  printf 'AUTO_PATCH=1\nAUTO_REBOOT=0\nPATCH_ALL_SLOTS=0\nMAX_ATTEMPTS=3\n' > "$STATE_DIR/config" 2>/dev/null
fi

VB_MODDIR=$MODPATH
. "$MODPATH/common/vbmeta.sh"

ensure_setup

vstate=$(getprop ro.boot.verifiedbootstate 2>/dev/null)
if [ "$vstate" = "green" ]; then
  ui_print "verified boot state is green, patch stays disabled"
  ui_print "run the action button after unlocking the bootloader"
else
  touch "$STATE_DIR/auto_pending"
  ui_print "patch scheduled for the next boot"
fi

ui_print "backup target: $STATE_DIR/backup and /sdcard/backupvb"
ui_print "action button toggles patch and restore"
