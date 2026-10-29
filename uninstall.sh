#!/system/bin/sh
MODDIR=${0%/*}
STATE_DIR=${STATE_DIR:-/data/adb/vbmeta_auto_disable}

if [ -f "$MODDIR/common/vbmeta.sh" ]; then
  VB_MODDIR=$MODDIR
  . "$MODDIR/common/vbmeta.sh"
elif [ -f "$STATE_DIR/vbmeta.sh" ]; then
  VB_MODDIR=
  . "$STATE_DIR/vbmeta.sh"
else
  exit 0
fi

ensure_setup

if [ "$(state_get)" = "patched" ]; then
  log_line "module removal requested while patched, restoring"
  if restore_all; then
    log_line "restore on removal succeeded"
  else
    log_line "restore on removal failed, run $STATE_DIR/restore.sh manually"
  fi
fi

log_line "module removed, backups kept in $BACKUP_DIR and /sdcard/backupvb"
