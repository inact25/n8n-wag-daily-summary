# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Version-controlled [n8n](https://n8n.io) workflows that produce a **daily WhatsApp group chat
summary**, per group, for many groups. Messages arrive from
[go-whatsapp-web-multidevice](https://github.com/aldinokemal/go-whatsapp-web-multidevice) ("go-wa")
by aldinokemal, are stored in Postgres, and once a day each active group is summarized by
Google Gemini and sent back to a WhatsApp number via go-wa.

**This repo holds exported n8n workflow JSON only** — no application code, no build step, no test
suite. n8n is the source of truth for editing; prefer editing in the n8n UI and re-exporting over
hand-editing JSON. The JSON here is generated/edited so the code-in-nodes stays readable.

## Architecture

Three runtime workflows plus two setup Forms share three Postgres tables (`db/schema.sql`).
Ingestion (real-time) and summarization (daily batch) are decoupled because go-wa cannot return
"all of today's messages" in one call.

Setup is Form-based so users never touch `psql`:
- **`wag-setup.json`** ("Quick Setup") — the beginner path. One linear flow: Form (single
  *recipient number* field) → install DDL → fetch go-wa groups → register **all** of them → done.
  No action dropdown, no Chat JID.
- **`wag-admin.json`** ("Manage Groups (Advanced)") — `formTrigger` → `switch` (Install / Show
  groups / Bulk / Save / List / Remove) → per-action Postgres/HTTP → shared `form` completion page.
- **`wag-reset.json`** ("Reset / Cleanup") — `formTrigger` → IF (`Confirm == 'RESET'`) → `switch`
  (groups / messages / summaries / config / full) → `DELETE FROM …` → completion page. Deletes rows,
  keeps tables. Same setMsg/switchRule helpers as admin.
- **`wag-data.json`** ("Data Browser (View)") — read-only inspector so users never run `SELECT`.
  `formTrigger` (View dropdown + optional *Filter: Chat JID* + *Limit*) → `switch` (`viewRule` keyed
  on `$json.View`) → per-view Postgres `SELECT` → Code formatter → shared `form` completion page.
  Views: Overview (counts/health), Registered groups (+per-group msg count & last activity),
  Recent messages (JID filter, `LIMIT $2::int`), Daily summaries, go-wa config. Writes nothing.
  Every SELECT is `alwaysOutputData: true` so an empty result still reaches its formatter (which
  prints a "No …" message). The optional filter is `WHERE ($1 = '' OR chat_jid = $1)`.

`wag-setup`/`wag-admin` run the same DDL as `db/schema.sql` and the same `wag_groups` upsert
(`upsertGroupQuery` in the generator) — keep all in sync if you change columns. `wag-data` is
read-only; if you rename a `wag_*` column, update its SELECTs/formatters too.

```
 wag-chat-ingest.json                         wag-daily-summary.json
 ────────────────────                         ─────────────────────
 go-wa ─(webhook)▶ Webhook                     Schedule 07:00 WIB
                    │ Normalize (fields+media)   │ Get Active Groups (wag_groups)
                    │ IF group & non-empty        ▼
                    ▼                            Loop Over Groups ──done──▶ (end)
              Postgres UPSERT                      │ (per group)
              wag_messages                         ▼
              (dedupe on message_id)           Get Today's Messages (wag_messages)
                                                   │ Build Transcript (+exact stats +prompt)
                                                   │ IF any messages ─┬ yes ▶ Gemini (JSON schema) ▶ Render
                                                   │                  └ no  ▶ No-Activity message
                                                   ▼
                                               Send via go-wa  ▶  Log Summary (wag_summaries)
                                                   └────────────── loops back ──────────────┘
```

### Tables (`wag_*`)
- **`wag_groups`** — registry the summary loop iterates. Add a group = insert a row
  (`chat_jid`, `project_name`, `send_to`, `active`). No workflow edit needed.
- **`wag_messages`** — ingested messages. `message_id` is `UNIQUE`; ingest does
  `INSERT ... ON CONFLICT DO NOTHING`, so webhook retries dedupe.
- **`wag_summaries`** — one row per `(chat_jid, summary_date)` (unique). Daily run upserts status
  `success` / `empty` / `error` + the sent text. This is the audit trail and idempotency key.
- **`wag_config`** — key/value store for `gowa_base_url`, `gowa_device_id`, `alert_to`. Quick Setup
  writes it (`Save Config`); the summary and error workflows read it via a `Get Config` node so they
  need **no environment variables**. Every go-wa URL/header/recipient resolves
  **`wag_config` → `$env.*` → literal default** (`getConfigQuery` uses `NULLIF` so blank DB values
  fall through). This exists because self-hosted n8n may disable `$env` access.

### Design decisions worth preserving
- **Stats come from the DB, never the LLM.** `Build Transcript` computes `total` and distinct
  senders; Gemini only produces the narrative. Don't ask the model to count.
- **Structured LLM output via native nodes.** `Summarize (LLM Chain)`
  (`@n8n/n8n-nodes-langchain.chainLlm`) drives a **Google Gemini Chat Model** sub-node
  (`lmChatGoogleGemini`) with a **Structured Output Parser** sub-node (`outputParserStructured`)
  enforcing `{ topics[], action_items[] }`. The chain returns the parsed object at `$json.output`;
  `Render Summary` formats the message deterministically — no free-text parsing. If you change the
  message layout, edit `Render Summary`/`No Activity Message`, not the prompt.
- **Per-group loop with `onError: continueRegularOutput`** on `Summarize (LLM Chain)` and
  `Send via go-wa` — one group failing doesn't abort the rest; the failure is still logged.
- **The daily loop only covers groups with activity today.** `Get Active Groups` filters
  `wag_groups` with an `EXISTS` against `wag_messages` for the Asia/Jakarta day, so a large registry
  (go-wa `/user/my/groups` often returns *all* member groups incl. communities — hundreds) doesn't
  bloat the run; only groups that actually got messages are processed/messaged.
- **Empty groups are logged, not messaged** (safety net if a looped group's messages all filter out). The IF false-branch goes `No Activity Message → Log
  Empty → loop` (status `empty`) with **no send**, so registering many quiet groups doesn't spam the
  recipient. Only groups with activity go through `Render Summary → Send via go-wa → Log Summary`.
  Each branch has its own log node reading its own branch's data node (avoids the `$json`-replaced
  cross-branch problem). `alwaysOutputData: true` on `Get Today's Messages` keeps empty groups flowing.
- **Per-send delay:** a `Delay Between Sends` Wait node (5s) sits on the success path before looping,
  to avoid WhatsApp rate-limit/ban from rapid sends. Adjust its amount as needed.
- **Header shows the group name** — `Render Summary` uses `project_name` from `wag_groups`, set at
  registration from the go-wa group `subject` (fallbacks to `Grup <last4 of JID>`).
- **Transcript cap** (`MAX_CHARS` in `Build Transcript`) guards a runaway high-volume day.
- **Loop wiring:** `Loop Over Groups` (Split in Batches, size 1) output **0 = done**, **1 = loop**;
  the loop body ends at `Log Summary`, which connects back to the loop node.

## Setup / configuration checklist

1. Preferred: import `wag-setup.json` ("Quick Setup"), run it, enter the recipient number, submit —
   it installs the schema and registers every go-wa group. For per-group control use `wag-admin.json`
   ("Manage Groups (Advanced)"). Both are equivalent to running `db/schema.sql` and `INSERT`ing into
   `wag_groups` by hand (still supported for SQL-first setups).
2. Create three n8n credentials and map them onto the placeholder-credential nodes:
   - **Postgres** — on the admin nodes, the five `wag-data` `Query *` nodes, plus `Upsert Message`,
     `Get Active Groups`, `Get Today's Messages`, `Log Summary`.
   - **Google Gemini (PaLM) API** (an API key from Google AI Studio) — on the
     `Google Gemini Chat Model` sub-node.
   - **HTTP Basic Auth** for go-wa — on `Send via go-wa`, `Send Alert via go-wa`, and the admin
     `go-wa: List Groups` nodes.
3. Configure go-wa settings — **preferably just run Quick Setup**, which writes `gowa_base_url`,
   `gowa_device_id`, and `alert_to` into `wag_config`. The summary/error workflows read them via
   `Get Config`, so no env vars are needed. Env vars (`GOWA_BASE_URL`, `GOWA_DEVICE_ID`,
   `WAG_ALERT_TO`) still work as a fallback. Device id (multi-device go-wa) is sent as the
   `X-Device-Id` header — find it via `GET {base}/app/devices` → `results.devices[].device_id`.
4. Point go-wa's webhook at `https://<n8n-host>/webhook/wag-incoming`; activate the ingest and
   summary workflows.
5. **Error alerts:** import `wag-error-alert.json` (an Error Trigger → go-wa message; recipient via
   `WAG_ALERT_TO`). Then in **both** other workflows set
   *Settings → Error Workflow* to it — the trigger only fires for workflows that name it. This is
   the only cross-workflow link and must be set after import (IDs don't exist until then).

## go-wa integration facts

- **API contract** (from go-wa `docs/openapi.yaml`): all device-scoped calls need the device id via
  the `X-Device-Id` header (or `?device_id=`); `/health` and `/app/devices` are exempt.
- **Send:** `POST {baseUrl}/send/message`, HTTP Basic Auth, JSON `{ "phone": "<jid>", "message": "<text>" }`.
  `phone` is a JID; the send body appends `@s.whatsapp.net` when only digits are given.
- **List groups:** `GET {baseUrl}/user/my/groups` → array at **`results.groups[]`**, each with `id`
  (the `…@g.us` JID) and `subject` (name). The group-list Code nodes read `results.groups`.
- **Devices:** `GET {baseUrl}/app/devices` → `results.devices[].device_id` (e.g. `org_2`).
- **Webhook payload field names vary by go-wa version.** `Normalize Payload` uses fallbacks
  (`chat_id`/`from`, `pushname`, `message.text`/`message.conversation`, media objects) and stores
  the full payload in `wag_messages.raw`. If ingested fields come out blank, inspect a `raw` row
  and adjust that Code node — it's the single place to absorb payload drift.

## Regenerating the workflow JSON

The JSON was produced by a Node generator (kept in the session scratchpad, not committed) that
builds the workflow objects and `JSON.stringify`s them — this keeps embedded Code-node JS readable
and guarantees valid JSON. Small changes: edit in n8n and re-export. Structural changes across many
nodes: prefer regenerating. Always validate a hand-edit:
`node -e "JSON.parse(require('fs').readFileSync('workflows/<file>.json'))"`.

## Common operations (self-hosted n8n CLI)

```bash
n8n import:workflow --input=workflows/wag-chat-ingest.json
n8n import:workflow --input=workflows/wag-daily-summary.json
n8n export:workflow --all --output=workflows/ --pretty
```

There is no lint/build/test. "Testing" = run a workflow manually in n8n and inspect output. The
summary workflow can be executed on demand; ingest via a test webhook POST. Useful checks:
`SELECT * FROM wag_summaries ORDER BY created_at DESC LIMIT 20;` and
`SELECT count(*), max("timestamp") FROM wag_messages;`.
