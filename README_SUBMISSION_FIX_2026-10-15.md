# DNCC IT Audit — Form submission diagnostic update (15 Oct 2026)

## What was observed
The submitted screenshot says only: `Something went wrong saving your response. Please try again.`
The ZIP's `index.html` already displayed an additional `[stage: detail]` in its catch block.
That mismatch strongly suggests the website is serving a different/older HTML build, or a cached one. It **does not establish** which database operation failed. No production Supabase changes were made.

## Minimal changes
- `index.html`: shows a small build ID (`2026-10-15.1`) under Submit; shows the failing step and safe error code, plus suggested IT action. Detailed underlying errors remain in the browser developer console.
- `index.html`: requires one returned submission row with an ID before claiming a save is confirmed; never advertises a saved response on an unconfirmed save.
- `index.html`: detects device inventory/history sync errors and handover PDF generation errors **after** a successful save, rather than silently claiming all steps succeeded. Does not encourage a second submission when records might already exist.
- `index.html`: adds an accessible live region for the form error/success notice. Avoids writing employee names and IMEIs into new client error telemetry.
- `supabase/diagnostics_2026-10-15_READ_ONLY.sql`: safe SQL checks for critical tables, columns, RPCs, and role grants.
- No changes to `admin.html`, working APIs, schema migrations, PDF helpers, or backend architecture.

## How to diagnose safely (before going live)
1. Run the **read-only** `supabase/diagnostics_2026-10-15_READ_ONLY.sql` in your Supabase project's SQL Editor. If a check fails, determine which existing migration was not applied. In particular, the current form requires `2026-10-13_unique_employee_id_unified_self_service.sql` and its earlier prerequisites (including 2026-10-09). Back up the database and review migration status before applying any migration.
2. On a staging copy of the website, replace **only** `index.html` with the patched one (or upload the whole ZIP only after confirming it matches the deployed app). Do not overwrite existing `config.js` if live settings differ; this ZIP contains the original project's config.
3. Refresh the staging page. Confirm `Form build: 2026-10-15.1` appears under the Submit button, then check Console for `[DNCC Form] build 2026-10-15.1`. If absent, clear browser/site caching or check CDN/deployment path.
4. Test once using an authorized **test employee and unused test IMEI** against a test/staging Supabase database, not production. Check: `submissions`, `devices`, `device_history`, PDF download, and email separately. Verify returned save confirmation; then test duplicate prevention and existing-employee special links.
5. If form submission fails, note only the displayed **step** and **error code**. In DevTools > Network, check which Supabase request failed. Never share access keys, request payloads, employee details, IMEIs, or full private responses publicly.
6. Only deploy after database checks and staging validation. No deployment was carried out while preparing this ZIP.

## Likely causes to investigate (not confirmed)
- The deployed page and supplied ZIP are different revisions, or CDN/browser cache is serving the old one.
- One of the latest Supabase migrations or RPC execution permissions is missing (`dncc_claim_employee_id` is used before every new submission).
- The `submissions` schema or insert/SELECT policies differ from the form's expected columns; a uniqueness rule or network issue could also reject a save.

## Known unresolved risks
- A screenshot without the HTTP error or Supabase project migration status cannot identify the production root cause definitively.
- A failed network response **during** submission may leave an indeterminate save result; verify a record exists before retrying.
- The existing codebase uses public Supabase access for several sensitive workflows. Review RLS policies and any default passwords/keys in configuration and schema files before external/public deployment; rotate actual exposed secrets as appropriate. This release does **not** attempt a broad authentication rewrite.
