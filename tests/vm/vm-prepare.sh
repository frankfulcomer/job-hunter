#!/usr/bin/env bash
# Prepare a DISPOSABLE Ubuntu 24.04 VM for Job Hunter validation. Run inside the VM:
#   sudo bash tests/vm/vm-prepare.sh --usb-disk /dev/sdX
# Installs Docker Engine and tools, then ERASES the given virtual USB disk and creates one
# exFAT partition labeled JH_E2E_USB. Writes /etc/jh-e2e-vm (marker + USB identity).
# Refuses to run outside a VM, on a host not named jh-e2e*, or twice.
set -euo pipefail
shopt -s inherit_errexit
die() { echo "ABORT: $*" >&2; exit 1; }

USB_DISK=""
while (( $# )); do case "$1" in --usb-disk) USB_DISK="${2:?}"; shift 2 ;; *) die "unknown argument $1" ;; esac; done
[[ -n "$USB_DISK" ]] || die "usage: vm-prepare.sh --usb-disk /dev/sdX"
[[ $EUID -eq 0 ]] || die "run with sudo"
virt="$(systemd-detect-virt --vm)" || die "not running in a virtual machine"
[[ "$(hostname)" == jh-e2e* ]] || die "hostname must start with jh-e2e (set when creating the VM)"
# shellcheck disable=SC1091
. /etc/os-release; [[ "$ID" == ubuntu ]] || die "Ubuntu required"
[[ ! -e /etc/jh-e2e-vm ]] || die "already prepared; revert the VM snapshot to start again"
echo "VM: $virt, $PRETTY_NAME, host $(hostname)"

echo "== Install Docker Engine and tools (Ubuntu packages)"
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q docker.io docker-compose-v2 gpg zstd python3 git exfatprogs util-linux curl
systemctl enable --now docker
docker version --format 'docker {{.Server.Version}}'
docker compose version

echo "== Virtual USB disk $USB_DISK"
[[ -b "$USB_DISK" && "$(lsblk -dno TYPE "$USB_DISK")" == disk ]] || die "$USB_DISK is not a whole disk"
[[ "$(lsblk -dno TRAN "$USB_DISK")" == usb ]] || die "$USB_DISK is not attached as USB"
size=$(lsblk -bdno SIZE "$USB_DISK")
(( size >= 4 * 1024**3 && size <= 64 * 1024**3 )) || die "$USB_DISK size $size is outside 4-64 GiB"
! lsblk -no MOUNTPOINTS "$USB_DISK" | grep -q . || die "$USB_DISK has mounted partitions"
[[ "$(findmnt -no SOURCE /)" != "$USB_DISK"* ]] || die "$USB_DISK holds the root filesystem"
lsblk -o NAME,SIZE,TRAN,MODEL,FSTYPE,LABEL "$USB_DISK"
read -rp "Type the device name ($USB_DISK) to ERASE it: " answer </dev/tty
[[ "$answer" == "$USB_DISK" ]] || die "not confirmed"
wipefs -a "$USB_DISK"
echo 'type=7' | sfdisk -q "$USB_DISK"
udevadm settle
part="$(lsblk -lnpo NAME,TYPE "$USB_DISK" | awk '$2 == "part" {print $1; exit}')"
[[ -b "$part" ]] || die "partition not created"
mkfs.exfat -L JH_E2E_USB "$part" >/dev/null
udevadm settle
uuid="$(blkid -s UUID -o value "$part")"
[[ -n "$uuid" ]] || die "no UUID on $part"

umask 022
cat > /etc/jh-e2e-vm <<EOF
# Disposable Job Hunter validation VM. Created $(date -Is).
JH_E2E_USB_UUID=$uuid
JH_E2E_USB_LABEL=JH_E2E_USB
JH_E2E_USB_PART=$part
EOF
mkdir -p /mnt/storage/backups
echo "Prepared. USB $part uuid=$uuid label=JH_E2E_USB. Take a VM snapshot named 'prepared' now."
