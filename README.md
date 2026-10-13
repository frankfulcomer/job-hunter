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

## Daily report application-history verification

The downstream Daily QA Job Report uses the owner-maintained Hub Excel workbook in Google Drive to check prior applications before recommending opportunities. This is separate from Job Hunter's discovered-listing deduplication. See the [history-check operating contract](docs/daily-report-history-check.md) and [validation/observation record](docs/validation/daily-report-history-check.md). The task's private source configuration and personal application data are not stored in this public repository.
