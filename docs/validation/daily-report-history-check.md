# Daily report history-check validation

Validation date: 2026-10-13. Related: [issue #2](https://github.com/frankfulcomer/job-hunter/issues/2).

## Evidence and limits

This increment changes a scheduled-task prompt and operating documentation, not application code. Applicable verification consists of prompt preservation/readback, live source retrieval, read-only scenario replay and two later scheduled-run observations. There is no new matcher service or runtime script to deploy. No n8n, Hub application or database test suite is affected.

- The old and new personalized prompts were retained privately.
- Replacing the new history block with the old paragraph reproduces the original prompt exactly.
- Saved UI readback matches the new prompt exactly. Daily timing and enabled state remain preserved.
- A fresh complete connector extraction of the authoritative workbook included the expected recent application events and coverage baseline.
- Seven source/prompt checks and nineteen read-only matching/publication/preservation checks passed.
- Historical replay excluded the duplicate recommended by the pre-change report while retaining distinct-role and no-history controls. Exact personal records and results remain private.

The mechanical replay is an analytical model of the written rules, not the scheduled LLM implementation. It checks the intended decisions and source evidence; it does not claim end-to-end automation compliance. No full daily-report rerun was triggered, avoiding unrelated alert mutations. Scheduled observations remain required.

## Representative cases

The table uses generalized/synthetic descriptions in place of personal application history. The private replay also used actual retrieved historical cases.

| Case | Expected outcome | Checked outcome |
| --- | --- | --- |
| Two application events, same employer/title/posting, different attribution parameters | SUPPRESS; retain both events | Pass |
| Same employer, different role and posting | CLEAR relative to that prior role | Pass |
| Same employer/title, syndicated URL without verified linkage | REVIEW | Pass |
| Reapplication with different source ID and no verified correspondence | REVIEW | Pass |
| Rejected prior application, same advertised posting | SUPPRESS | Pass |
| Verified company-name alias, same role/ID | SUPPRESS | Pass |
| Same source ID reused for conflicting titles | REVIEW | Pass |
| Changed posting ID but same employer/title | REVIEW | Pass |
| Four candidate employers/titles without historical application matches | CLEAR for application history, subject to decision coverage | Pass |
| Application source unavailable or text truncated | UNVERIFIED LEADS ONLY | Pass |
| Older snapshot with a known newer receipt | UNVERIFIED LEADS ONLY for unknown candidates | Pass |
| Complete applications but partial decision history | Eligible with explicit decision-coverage limitation | Pass |
| Read-only replay over history | Original event rows unchanged | Pass |

Additional decision checks: a documented declined role remains held, a different role at the same staffing firm remains eligible, preparation deferral is not treated as opportunity deferral, and synthetic deferrals before/at their revisit date produce HOLD/REVIEW respectively. Material changes require REVIEW, never automatic reactivation.

## Observation status

| Observation | Status | Evidence |
| --- | --- | --- |
| First post-change daily report | Pending | Record privately after execution |
| Second distinct post-change daily report | Pending | Record privately after execution |

A report counts only after checking current source retrieval/coverage, candidate history evidence, uncertainty handling and explicit limitations. Missing, inaccessible or failed evidence does not count. Mark the defect resolved only after two passing reports; do not close the broader issue or merge without owner approval.
