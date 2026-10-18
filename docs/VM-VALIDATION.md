# Disposable VM validation

Validates the backup and restore scripts against real Docker Engine and real n8n using **synthetic data only**, in a throwaway Ubuntu VM. Nothing here touches the production host's Docker daemon, n8n, volumes, credentials or the `JOB_HUNTER` USB drive.

There are three separate phases. Each one answers a different question:

| Phase | Question | Where | Script |
|---|---|---|---|
| A. Docker semantics | Does a real Docker Engine behave the way the scripts and mocks assume? | VM | `tests/docker-integration.sh` (also step S1 of phase B) |
| B. Synthetic backup and restore | Do the real scripts back up and restore a real n8n deployment end to end? | VM | `tests/vm/e2e-synthetic.sh` |
| C. Windows/WSL recovery | Does recovery work on the replacement machine type? | Windows 11 + WSL2 | `docs/BACKUP-RESTORE.md` (Recovery drill), later |

Phase B can pass while phase C fails (different Docker engine, image store, WSL filesystem), so a pass in phase B is not proof that phase C will pass.

## 0. Requirements

- A host that is **not** running production. If the production host must be used, it needs approval: installing the hypervisor changes the host, and a 4 GB VM competes with production for its 7.2 GB of RAM. Run it outside 07:00, 12:00 and 17:00.
- KVM, libvirt and cloud-image tools on that host.
- Internet access for the VM. It installs packages and pulls the pinned n8n image.
- Resources:
  - VM: 2 vCPUs, 4 GB RAM, 40 GB disk.
  - Virtual USB disk: **8 GB raw image, attached on the USB bus**. It must show as `TRAN=usb` in the guest. Each backup set includes the n8n image, and the run creates three sets.

## 1. Create the VM (host, needs approval)

```
sudo apt install -y qemu-system-x86 libvirt-daemon-system virtinst cloud-image-utils
mkdir -p ~/jh-e2e-vm && cd ~/jh-e2e-vm
wget https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img
qemu-img create -f qcow2 -F qcow2 -b noble-server-cloudimg-amd64.img jh-e2e.qcow2 40G
qemu-img create -f raw jh-e2e-usb.img 8G
cat > user-data <<'EOF'
#cloud-config
hostname: jh-e2e
users:
  - name: tester
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys: [<your public key>]
EOF
echo "instance-id: jh-e2e" > meta-data
cloud-localds seed.iso user-data meta-data
sudo virt-install --name jh-e2e --memory 4096 --vcpus 2 --import --os-variant ubuntu24.04 \
  --disk jh-e2e.qcow2 --disk seed.iso,device=cdrom \
  --disk jh-e2e-usb.img,format=raw,bus=usb \
  --network network=default --graphics none --noautoconsole
sudo virsh domifaddr jh-e2e          # VM address for ssh
```

Copy only the code under test into the VM. This leaves out `.git`, `exports/` (the production backup tarball), and `data/`, `config/` and `logs/`:

```
cd ~/Projects/job-hunter
tar -czf - compose.yaml README.md .gitignore scripts restore docs tests | ssh tester@<vm-ip> 'mkdir -p ~/job-hunter && tar -C ~/job-hunter -xzf -'
```

## 2. Prepare the VM (inside the VM)

```
lsblk -o NAME,SIZE,TRAN,MODEL       # the 8G disk with TRAN=usb, e.g. /dev/sda
sudo bash ~/job-hunter/tests/vm/vm-prepare.sh --usb-disk /dev/sda
```

What it does:
- Refuses to run unless it's in a VM named `jh-e2e*` that hasn't been prepared before.
- Installs `docker.io`, `docker-compose-v2`, `gpg`, `zstd`, `exfatprogs` and related tools.
- Asks you to type the device name, then erases that disk and creates one exFAT partition labeled `JH_E2E_USB`.
- Records the partition's UUID in `/etc/jh-e2e-vm`.

Then, on the host, take a snapshot so phase B can be rerun from a clean state:

```
sudo virsh snapshot-create-as jh-e2e prepared
```

## 3. Phase A: Docker semantics only

Phase B runs this automatically as step S1. To run it on its own, use the pinned image:

```
img=$(grep -oP '^\s*image:\s*\K\S+' ~/job-hunter/compose.yaml); sudo docker pull -q "$img"
sudo bash ~/job-hunter/tests/docker-integration.sh --context default "$img"
```

Expected: every line is `ok`, it ends with `cleanup verified` and `passed: N  failed: 0`, and the exit status is 0. It backs up and restores nothing.

## 4. Phase B: synthetic backup and restore

```
sudo bash ~/job-hunter/tests/vm/e2e-synthetic.sh
```

To rerun, first revert the VM: `sudo virsh snapshot-revert jh-e2e prepared` on the host.

The script uses the real scripts unchanged, apart from two overrides in `tests/vm/vm-overrides.sh`:
- the USB UUID and label come from `/etc/jh-e2e-vm`;
- the passphrase is a synthetic one read from a file.

Steps run in this order. Each step's log and verdict go to `/var/tmp/jh-e2e-evidence/<timestamp>/`.

| Step | Action | Expected result |
|---|---|---|
| S0 | Pull the pinned image | Exit 0 |
| S1 | `docker-integration.sh`, before any `n8n_data` volume exists | Exit 0, all checks ok, cleanup verified |
| S2 | Deploy a copy of the repo at `/opt/jh-e2e/job-hunter`. Seed it with `n8n import:workflow` and `n8n import:credentials` from `tests/vm/fixtures` (2 workflows, 1 credential with a fake value), plus 2 files in `data/`. | n8n is healthy (`/healthz` returns 200) |
| S3 | Backup, `online` | Exit 0; last line `BACKUP COMPLETE`; manifest `counts: workflows=2 credentials=1 data_tables=0 data_table_rows=0 executions=0 data_files=2`; `consistency: online capture` |
| S4 | Backup with the USB already mounted | Non-zero exit, `already mounted`, no new set |
| S5 | Backup, `pause` | Exit 0; `paused capture`; n8n unpaused afterwards |
| S6 | `docker compose stop`, then backup `stopped`, then `start` | Container status `exited 0`; backup exit 0; `stopped capture`; n8n healthy again |
| S7 | SIGTERM during backup | Non-zero exit; `BACKUP FAILED`; no set; no plaintext, labeled containers or mount left behind |
| S8.1–3 | Restore each set into a new volume and data folder | Exit 0; `ARTIFACT VERIFICATION: PASS`; `2 files, contents match`; set checksums unchanged |
| S9 | Isolated drill of the S6 restore with `restore/compose.drtest.yaml` | `/healthz` returns 200 inside the container; `egress-check.sh` prints `EGRESS BLOCKED` after its positive control passes; `/data` has 2 entries |
| S10.1 | Restore with the wrong passphrase | Non-zero exit; no volume created |
| S10.2 | Restore a tampered set | Non-zero exit at checksum verification |
| S11 | Final state | All sets verify; nothing left behind; synthetic n8n running |

The run passes only if it prints `E2E SYNTHETIC: PASS` and exits 0. Keep the evidence folder; its `environment.txt` records the SHA-256 of every script under test.

Not covered in phase B:
- Data tables (n8n has no CLI import for them), so the counts expect 0.
- Physical USB hardware.
- Docker Desktop.
- Removing the stick mid-copy.

## 5. Teardown

On the host: `sudo virsh destroy jh-e2e; sudo virsh undefine jh-e2e --remove-all-storage --snapshots-metadata`, then delete `~/jh-e2e-vm`. Copy out the evidence folder first if you need it.

## 6. Phase C: Windows/WSL recovery (later, separate)

Do this only after phase B passes. Use the Windows 11 drill machine with Docker Desktop and WSL2 Ubuntu, and follow the "Recovery drill" and smoke test in `docs/BACKUP-RESTORE.md`.

Start with a backup set produced in phase B, so the passphrase is synthetic and no production data is involved. A production set comes later, and only with separate approval.

Run `tests/docker-integration.sh --context <desktop context> job-hunter/n8n:restored` first. Docker Desktop's image store and `docker cp` behavior can differ from Docker Engine's.
