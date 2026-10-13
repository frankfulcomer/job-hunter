# Daily report application-history check

## Scope and ownership

This is the operating contract for the existing ChatGPT Daily QA Job Report, tracked by [issue #2](https://github.com/frankfulcomer/job-hunter/issues/2). It fixes recommendation deduplication downstream of discovery. Job Hunter's production n8n workflow is not changed. Broader QA/SDET/BA discovery requirements remain intact.

The source of truth is the owner-maintained Job Search Hub **Excel workbook stored in Google Drive**, not the older native Google Job Search Tracker and not the similarly named Flask/SQLite Hub application. Its exact file ID and privately verified coverage baseline belong in the scheduled task configuration. Do not commit private workbook IDs, full personalized prompts, application histories or receipts here.

The implementation replaces only the old application-history paragraph of the scheduled task. The task's remaining search, screening, alert-handling, schedule and account settings are preserved. The inline prompt is what executes; this document is its maintainable contract, not an assumption that the scheduled task loads GitHub automatically. Deployment requires saved-prompt readback.

## Inline task contract

The following reproduces the deployed history block with private source configuration and baseline details removed. When configuring the task, supply the verified source ID/URL and private completeness sentinels in the corresponding paragraphs. Do not replace the entire personalized task prompt with this block.

```text
Mandatory application-history gate (before publishing):
Use the owner-maintained Job Search Hub Excel workbook in Google Drive, identified by its exact private task configuration, as authoritative application history. It is a stored XLSX, not a native Google Sheet: use Google Drive fetch/file reading, not native Sheets range tools. Retrieve it afresh each run and inspect the complete application worksheet plus the relevant Activity Log decisions. Extract only relevant history; do not use the contacts/network sheets. Do not substitute the older native "Job Search Tracker" as complete authority.

Verify source identity, required columns (employer, title, link/identifier, application date, status), full application-row coverage, retrieval time, file modification time, row count and latest application date. Use a privately verified baseline row count, recent events and coverage cutoff as completeness sentinels, not a fixed maximum or a rule to suppress by row number. If text extraction is truncated or lacks enough evidence of completeness, retrieve the raw XLSX through Drive and inspect the relevant worksheets with existing spreadsheet tools. If that cannot be done, report history incomplete. Compare the cutoff with confirmed newer application/decision evidence encountered during the run; a recent file modification time or successful connector response alone does not establish complete current history.

For every proposed APPLY, CONSIDER or STRETCH candidate, compare normalized employer and role/title with namespaced employer requisition and source posting IDs. Ignore attribution parameters, but retain identity parameters such as Indeed jk and meaningful URL fragments. Use evidence-backed employer/title aliases; do not collapse subsidiaries or confidential staffing clients by guesswork. Include all historical statuses, including rejected, withdrawn, closed and archived, and preserve all application events.

Use these outcomes:
- SUPPRESS: established same opportunity already applied to, or a matching explicit passed/deferred decision. A new advertised date or syndication URL alone does not make it new. Keep separate submission events; never merge or delete history.
- REVIEW: same employer/title with missing or different IDs, possible repost/syndication, uncertain alias/client, conflicting titles sharing an ID, or a documented material change/revisit condition. Keep it out of the new-opportunity shortlist pending verification. Do not automatically revive prior rejected applications.
- CLEAR: no established or plausible historical match after the required checks. Distinct titles and posting IDs remain distinct opportunities; prior applications do not exclude an entire employer.

Check explicit opportunity decisions in the Hub Activity Log and available confirmed owner context. Separate owner passed/deferred decisions from AI screening suggestions and from deferral of interview preparation. Preserve the reason and revisit condition; changed conditions require REVIEW. If decision coverage is partial, disclose that separately and label otherwise-clear prospects "application history checked; decision history partial" rather than claiming exhaustive clearance.

Publish a concise History Check with source link, retrieval time, modification time, application-row count, latest application date, decision coverage and any gaps. Each shortlisted candidate must have a brief history outcome/evidence; list uncertain matches separately with the matched event/decision. Recheck the source if it changed during the run. If application history is unavailable, stale relative to known events, partial or ambiguous, continue discovery only as UNVERIFIED LEADS, withhold APPLY/CONSIDER/STRETCH recommendations, and state the specific gap. An accessible dated verified Hub snapshot, older tracker or confirmed receipt may support known suppressions; none can clear unknown candidates across an unverified coverage gap. No snapshot availability is assumed. Do not quietly treat missing history as empty. These checks are read-only: do not edit trackers, application records or evidence.
```

## Source and fallback behavior

Read the complete application worksheet and relevant Activity Log decisions through existing Drive/file tools. Stored XLSX files use file retrieval, not native Sheets range APIs. Ignore contacts and network data. A partial text extraction is not a full history read; retrieve the raw workbook when needed or report the limitation.

Freshness is coverage relative to known events, not an arbitrary maximum file age. No recent applications is compatible with current history. A newer confirmed application absent from the source is an explicit gap. File timestamps and latest business-event dates are distinct.

An accessible verified dated Hub snapshot, older tracker or receipt can establish an existing application. It cannot establish absence across a newer unverified interval. No new cache, service or always-available snapshot is introduced. If no usable source is accessible, publish unverified leads and the failure reason; do not mark unknown prospects APPLY, CONSIDER or STRETCH.

Application coverage and decision coverage are separate. Existing Activity Log decisions and confirmed owner context are used without introducing a new Hub feature or reconstructing all prior decisions. Partial decision coverage is disclosed on otherwise-clear prospects. Only explicit opportunity decisions suppress by decision; preparation deferrals and AI suggestions do not become owner decisions.

## Validation and two-report observation

See [validation record](validation/daily-report-history-check.md). Prompt preservation, readback, source inspection and rule replay support the implementation, but do not prove scheduled-model compliance.

Inspect two distinct daily report runs after deployment. For each record its date/run reference, source retrieval, source identity and coverage, decision-coverage disclosure, shortlisted-candidate evidence, review/suppression outcomes, and any failure handling. A run with no recommendations still needs a History Check. A missing run or inaccessible evidence is pending, not a pass.

The existing QA Report Health Check receives a bounded supplemental instruction to observe these two reports, retaining its ordinary enabled/run-health checks. Do not introduce a second permanent monitor. Keep its observation records private; notify on failure, required action or completion, and otherwise retain the existing quiet behavior. Stop the supplemental acceptance audit after two verified passing observations, while ordinary health checks continue. Do not merge the PR or close issue #2 automatically.

## Preservation and release boundary

All source records and application events are read-only. No tracker reconciliation, migration, new Hub feature or application submission is included. The prompt change is live under owner authorization; repository changes use a review branch/PR and remain unmerged until approved. The defect remains pending observation until both daily reports pass; issue #2 also retains its wider outstanding requirements.
