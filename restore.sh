#!/system/bin/sh
MODDIR=${0%/*}
VB_MODDIR=$MODDIR
. "$MODDIR/common/vbmeta.sh"

ensure_setup
if [ "$1" = "--force" ]; then
  VB_FORCE=1
fi
restore_all
