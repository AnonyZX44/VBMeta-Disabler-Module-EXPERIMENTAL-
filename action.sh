#!/system/bin/sh
MODDIR=${0%/*}
VB_MODDIR=$MODDIR
. "$MODDIR/common/vbmeta.sh"

ensure_setup
printf 'root:       %s\n' "$(root_manager)"
printf 'boot:       %s\n' "$(boot_state_text)"
printf 'state:      %s\n' "$(state_get)"
printf 'flags:      %s\n' "$(flags_state)"
printf 'by-name:    %s\n' "$(byname_cached)"
printf 'backup dir: %s\n' "$BACKUP_DIR"
run_toggle
printf 'log: %s\n' "$LOG_FILE"
tail -n 12 "$LOG_FILE" 2>/dev/null
