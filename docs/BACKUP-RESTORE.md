# Backup and restore

Job Hunter's state lives in the `n8n_data` Docker volume: the SQLite database (workflows, data tables such as `jobs` and `job_titles`, encrypted credentials, execution history), the `config` file holding the credential **encryption key**, and installed nodes. Some API keys are stored in plaintext inside workflow nodes. None of this is in Git.

## Backup set

`scripts/backup-n8n.sh` writes one set per run to `/mnt/storage/backups/job-hunter/<name>/` and to `job-hunter-backups/<name>/` on the `JOB_HUNTER` USB drive (UUID `96BD-7884`):

| File | Contents | Sensitive |
|---|---|---|
| `job-hunter-data.tar.zst.gpg` | Database snapshot, volume files incl. encryption key, `/data`, workflow and encrypted-credential exports, full manifest | Yes; GPG AES256 encrypted |
| `n8n-image.tar.zst` | The exact running n8n image (`docker save`) | No |
| `kit/` | Working-tree copy of the deployment in repository layout (`compose.yaml`, `scripts/`, `restore/`, `docs/`), including uncommitted files. **Recovery uses this.** | No |
| `repo.bundle` | Git history (`git clone repo.bundle`). Contains committed files only; not needed for recovery. | No |
| `MANIFEST.txt` | Image, n8n version, payload checksum, counts only (no names) | No |
| `SHA256SUMS` | Checksums of every file in the set | No |

Not included: n8n event logs (diagnostic, continuously appended).

## Running a backup

Run in a real terminal (the passphrase prompt needs one), with the USB drive attached but **not mounted**:

```
( set -o pipefail; sudo bash scripts/backup-n8n.sh 2>&1 | tee ~/jh-backup.log )
```

With `pipefail` in the subshell, the command's exit status is the backup's (non-zero on any failure, or if `tee` fails), so automation and `&&` chains see the real result. Do not append `; echo ...` to the line: that replaces the status with `echo`'s. The final line is `BACKUP COMPLETE` or `BACKUP FAILED`.

The script:

1. Identifies the USB by UUID, label, filesystem and USB transport, and refuses if it is already mounted.
2. Validates the running container against `compose.yaml`: compose labels, image, exactly the `n8n_data` volume at `/home/node/.n8n` and `./data` at `/data`, SQLite, and no external-storage or encryption-key environment settings.
3. Prompts twice for the passphrase (minimum 12 characters).
4. Captures a transactional SQLite snapshot (`VACUUM INTO`) and the other volume files. Non-database files get a **metadata** fingerprint (path, type, mode, size, mtime, inode) before and after; any detected change, or any unreadable path, aborts the run. A rewrite that keeps size and mtime is not detected, so this does not prove contents unchanged.
5. Verifies the snapshot with the same n8n image in a container with **no network**: workflows export, and every credential decrypts with the backed-up key (decrypted output stays inside that container's tmpfs).
6. Encrypts the payload, writes the set to `<name>.partial`, verifies checksums and a streamed decrypt, fsyncs, then renames to `<name>`.
7. Copies to the USB the same way, unmounts, **remounts and re-verifies from the device**, then unmounts.

It prints `BACKUP COMPLETE: <name>` only after every step, including the final unmount, succeeds. Otherwise it prints `BACKUP FAILED`, names any `.partial` items (encrypted or non-secret only) and exits non-zero. Existing backups are never modified.

Plaintext is staged only in a private (mode 0700) directory under `/dev/shm`; see Limitations.

### Consistency

Each set records a descriptive `consistency:` line in `MANIFEST.txt`, repeated in restore reports, plus the number of unfinished executions (`new`, `running`, `waiting`) found in the snapshot. None of the script's modes is an authoritative recovery baseline:

| `CAPTURE_MODE` | Recorded as | What it guarantees |
|---|---|---|
| `online` (default) | `online capture (n8n running)` | Transactionally consistent database snapshot; no metadata change detected in other files during capture. In-flight work is not quiesced and restores as unfinished. |
| `pause` | `paused capture (n8n frozen, not shut down)` | As above, with n8n's processes frozen (`docker pause`) for the capture, normally seconds. Freezing is not a shutdown: in-flight executions, open connections and in-memory state are captured mid-operation. Affects production briefly; requires approval. |
| `stopped` | `stopped capture (container exited cleanly before backup)` | The operator stopped n8n before the run and the container exited with code 0. This is the strongest available. The script never stops or starts n8n itself. |

#### Clean-shutdown baseline procedure (operator-run, requires approval)

Use this for the reference backup before a migration or recovery drill. n8n is offline for the backup duration; choose a time away from 7:00, 12:00 and 17:00.

1. Confirm no execution is running (n8n UI → Executions).
2. `cd ~/Projects/job-hunter && sudo docker compose stop n8n` (graceful stop; n8n finishes or cancels running work).
3. `sudo docker container inspect --format '{{.State.Status}} {{.State.ExitCode}}' n8n` must print `exited 0`.
4. `( set -o pipefail; sudo CAPTURE_MODE=stopped bash scripts/backup-n8n.sh 2>&1 | tee ~/jh-backup.log )`
5. `sudo docker compose start n8n`, then confirm `curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:5678/healthz` prints `200`.
6. Keep the set as the baseline only if step 4 ended with `BACKUP COMPLETE` and exit status 0, and the manifest reports `unfinished executions recorded: 0`.

### Secrets you must keep outside the machine

Store these in a password manager. The backup is useless without the first one.

- Backup passphrase
- n8n encryption key (inside the backup, but keep a copy)
- Resend, Adzuna and USAJOBS API keys (inside workflow nodes)
- Google OAuth client and service-account details
- n8n owner login

## Restoring (Linux or Windows)

`kit/scripts/restore-n8n.sh` restores into a **new** volume and proves it works without starting n8n or using the network.

### Windows 11 preparation

1. Install Docker Desktop (WSL2 backend) and an Ubuntu WSL distribution; enable Docker Desktop's WSL integration for it.
2. In Ubuntu: `sudo apt install gpg zstd python3 git`.
3. Optional: limit WSL memory in `%UserProfile%\.wslconfig` (`[wsl2]` / `memory=6GB`), then `wsl --shutdown`.
4. Copy the set into the WSL filesystem (not `/mnt/c`): `cp -r /mnt/d/job-hunter-backups/<name> ~/` (drive letter varies).
5. Make sure no other n8n instance with these credentials is running against the internet.

### Rules

- Treat the backup set as **read-only**. Do not run commands that write inside it (no `git clone`, reports, or extraction there). The restore script refuses report and data paths inside the set and re-verifies `SHA256SUMS` at the end to prove the set is unchanged.
- Work from a copy of `kit/` for compose files and scripts. `repo.bundle` may lack uncommitted files.
- The restore script creates a new volume, labels it with a random run id, and aborts unless the label is its own and the volume is empty. It never reuses an existing volume.

### Recovery drill (isolated)

```
SET=~/<name>                                   # copied backup set (read-only from here on)
(cd "$SET" && sha256sum -c --quiet SHA256SUMS)
bash "$SET/kit/scripts/restore-n8n.sh" "$SET"  # creates volume jh_drtest_<timestamp>
```

This verifies checksums, decrypts into `/dev/shm`, validates every archive (relative paths, regular files and directories only) before extracting, checks the database against the manifest, loads the image and tags it `job-hunter/n8n:restored`, fills the new volume, restores `/data` to `~/<volume>-data` and checks every file's SHA-256 against the archive, then runs the n8n CLI with no network and the restored `/data` mounted read-only to export workflows, decrypt every credential, read the n8n version and count the files visible at `/data`. It writes `~/job-hunter-restore-report-<timestamp>.txt`, and fails if any cleanup (containers, plaintext work directory) cannot be confirmed.

The report separates **artifact verification** (what the script proves) from **application recovery**, which it does not demonstrate. Demonstrate startup with the smoke test, still with no outbound network:

```
cp -r "$SET/kit" ~/jh-drill && cd ~/jh-drill
export JH_DRTEST_VOLUME=jh_drtest_<timestamp> JH_DRTEST_DATA=~/jh_drtest_<timestamp>-data   # printed by restore-n8n.sh
docker compose -f restore/compose.drtest.yaml up -d
docker compose -f restore/compose.drtest.yaml exec n8n node -e "fetch('http://localhost:5678/healthz').then(r=>console.log(r.status))"
bash restore/egress-check.sh --context "$(docker context show)" job-hunter/n8n:restored "$(docker compose -f restore/compose.drtest.yaml ps -q n8n)"
docker compose -f restore/compose.drtest.yaml exec n8n node -e "console.log(require('fs').readdirSync('/data'))"
docker compose -f restore/compose.drtest.yaml logs --tail 50 n8n    # no migration or decryption errors
docker compose -f restore/compose.drtest.yaml down
docker volume rm "$JH_DRTEST_VOLUME" && rm -rf "$JH_DRTEST_DATA"
```

Pass criteria: health returns `200`, `egress-check.sh` prints `EGRESS BLOCKED` (its positive control proves the probe works, so a machine without internet cannot pass by accident), `/data` lists the restored files, logs show no migration or decryption errors. Record the result in the report. Schedules may fire during the smoke test; with no network they fail inside the drill volume only.

### Real recovery (replacement machine)

Production on the old machine must be stopped first, or both instances will send email.

```
cp -r "$SET/kit" ~/job-hunter                 # directory name keeps the compose project name
bash ~/job-hunter/scripts/restore-n8n.sh "$SET" --volume n8n_data --data-dir ~/job-hunter/data
cd ~/job-hunter
docker compose -f compose.yaml -f restore/compose.restore.yaml up -d
```

Then log in, open each credential, run Job Hunter once manually and confirm the email arrives. Re-authorize Google OAuth credentials if prompted. Optionally `git clone "$SET/repo.bundle"` elsewhere for history.

Use the image from the backup (`compose.restore.yaml`). A newer n8n image migrates the database irreversibly.

## Testing the scripts

Three separate levels; only the last validates recovery.

1. `bash tests/run-tests.sh` — unit and scripted end-to-end tests with fixtures and **mocked** Docker and device commands. No root, Docker or USB needed. The Docker mock imitates the real behaviors the scripts depend on (e.g. `docker volume create` silently returns an existing volume; missing objects report `No such ...`), but a mock cannot prove Docker's behavior.
2. `bash tests/docker-integration.sh --context CONTEXT IMAGE` — **Docker semantics only**: checks those behaviors on a real engine (volume re-create, `docker cp -a` ownership, emptiness listing, isolation against controlled endpoints with positive controls and timeouts, read-only `/data`, version output, the exact missing-object messages for containers, volumes, images and networks). It backs up and restores nothing. It requires an explicit context that matches the current one, refuses `DOCKER_HOST`/`DOCKER_CONTEXT`, refuses engines with an `n8n` container or `n8n_data` volume, labels and tracks everything it creates, and fails if cleanup cannot be confirmed. Never run it against production.
3. **Synthetic end-to-end recovery test** — not yet performed; planned below.

### Disposable VM validation

The executable procedure for levels 2 and 3 is in [docs/VM-VALIDATION.md](VM-VALIDATION.md) (scripts in `tests/vm/`).

## Limitations

- **Plaintext staging:** decrypted data exists in a 0700 directory on `/dev/shm` (tmpfs) for the run. Root can read it. Under memory pressure tmpfs pages can be written to **swap**, which is unencrypted on this host; the scripts disclose active swap but cannot prevent it. Deletion is not secure erasure.
- **Capacity checks are estimates:** about three times the live database plus other files, bounded by tmpfs space and `MemAvailable` minus 512 MiB. Other processes can consume memory during the run. Local and USB checks allow for the payload, image and a margin. Docker's own disk space for `docker load` on restore is not checked.
- **Consistency:** see the table above. Metadata fingerprints do not prove file contents unchanged. Event logs are not backed up.
- **Integrity, not authenticity:** `SHA256SUMS` is unsigned. GPG's integrity check protects the encrypted payload; the image, bundle and kit are protected against corruption only, not deliberate replacement.
- **Privileges:** the backup runs entirely as root.
- **Not yet demonstrated:** a real backup run, real n8n CLI behavior in the verification container, `docker load` producing the same image ID on Docker Desktop, the Windows/WSL path, and application recovery (smoke test). The synthetic end-to-end test above is the plan for these.
