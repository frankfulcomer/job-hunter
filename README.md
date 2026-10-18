# Job Hunter

A self-hosted job-discovery pipeline built with n8n and Docker.

Job Hunter queries multiple public job sources, normalizes their different response formats, removes duplicate listings, evaluates location criteria, caches geocoding results, stores newly discovered jobs, and sends an email digest.

## Highlights

- Integrates multiple job APIs and applicant-tracking systems
- Normalizes inconsistent source data into a common structure
- Deduplicates listings across sources and previous runs
- Filters remote and location-based opportunities
- Caches geocoding results to reduce unnecessary API calls
- Stores discovered jobs locally
- Sends new-job digests through Resend
- Runs on a three-times-daily schedule
- Uses a pinned n8n container image for reproducibility
- Applies a Docker CPU limit for thermal stability

## Deployment

The production instance runs on Ubuntu using Docker Engine and Docker Compose.

The included `compose.yaml`:

- pins the validated n8n image by digest,
- binds the n8n editor to localhost,
- uses an external persistent Docker volume,
- mounts a local data directory,
- configures the America/New_York timezone,
- limits n8n to two CPU cores,
- and restarts the service automatically unless intentionally stopped.

## Migration and validation

The project was migrated from Docker Desktop on Windows to Docker Engine on Linux using a checksum-verified offline backup.

Validation included:

- restoring the n8n SQLite database and credential configuration,
- confirming workflow and execution-history integrity,
- performing an end-to-end production test,
- verifying job collection and deduplication,
- confirming successful email delivery,
- and load-testing the workflow under CPU and thermal monitoring.

## Backup and recovery

`scripts/backup-n8n.sh` creates an encrypted, verified backup set on the local backup disk and a USB drive; `scripts/restore-n8n.sh` restores it offline into a new, isolated Docker volume and reports artifact verification separately from the application smoke test. See [docs/BACKUP-RESTORE.md](docs/BACKUP-RESTORE.md). Tests: `bash tests/run-tests.sh` (mocked) and `bash tests/docker-integration.sh --context CONTEXT IMAGE` (real Docker semantics, disposable VM only; see [docs/VM-VALIDATION.md](docs/VM-VALIDATION.md)).

## Security

This repository intentionally excludes:

- API keys and authorization headers
- n8n credential encryption material
- SQLite databases and execution history
- backup archives
- generated job data
- logs and personal information

A sanitized workflow export may be added after all credentials and personal data have been removed.

## Technology

- n8n
- Docker Engine
- Docker Compose
- SQLite
- REST APIs
- Resend
- Linux
- Git and GitHub

## Status

The workflow is running in production on Linux at 7:00 AM, 12:00 PM, and 5:00 PM Eastern Time.
