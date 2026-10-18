# Sourced after scripts/backup-n8n.sh or scripts/restore-n8n.sh inside the disposable VM.
# Only two things change: the USB identity comes from /etc/jh-e2e-vm (the VM's virtual
# USB disk), and the passphrase is read from $JH_E2E_PASSFILE instead of a terminal.
# shellcheck disable=SC1091
source /etc/jh-e2e-vm
if declare -F load_config >/dev/null; then   # backup script only
  eval "orig_$(declare -f load_config)"
  load_config() { orig_load_config; USB_UUID="$JH_E2E_USB_UUID"; USB_LABEL="$JH_E2E_USB_LABEL"; }
fi
read_passphrase() { IFS= read -r PASS < "$JH_E2E_PASSFILE"; (( ${#PASS} >= 12 )) || jh_die "passphrase file too short"; }
