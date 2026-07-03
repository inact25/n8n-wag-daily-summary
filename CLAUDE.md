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

Both run the same DDL as `db/schema.sql` and the same `wag_groups` upsert (`upsertGroupQuery` in the
generator) — keep all three in sync if you change columns.

```
 wag-chat-ingest.json                         wag-daily-summary.json
 ────────────────────                         ─────────────────────
 go-wa ─(webhook)▶ Webhook                     Schedule 23:00 WIB
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
- **Empty days** are handled via `alwaysOutputData: true` on `Get Today's Messages` so the IF
  false-branch can send/log a "no activity" note instead of the run silently ending.
- **Transcript cap** (`MAX_CHARS` in `Build Transcript`) guards a runaway high-volume day.
- **Loop wiring:** `Loop Over Groups` (Split in Batches, size 1) output **0 = done**, **1 = loop**;
  the loop body ends at `Log Summary`, which connects back to the loop node.

## Setup / configuration checklist

1. Preferred: import `wag-setup.json` ("Quick Setup"), run it, enter the recipient number, submit —
   it installs the schema and registers every go-wa group. For per-group control use `wag-admin.json`
   ("Manage Groups (Advanced)"). Both are equivalent to running `db/schema.sql` and `INSERT`ing into
   `wag_groups` by hand (still supported for SQL-first setups).
2. Create three n8n credentials and map them onto the placeholder-credential nodes:
   - **Postgres** — on the admin nodes plus `Upsert Message`, `Get Active Groups`,
     `Get Today's Messages`, `Log Summary`.
   - **Google Gemini (PaLM) API** (an API key from Google AI Studio) — on the
     `Google Gemini Chat Model` sub-node.
   - **HTTP Basic Auth** for go-wa — on `Send via go-wa`, `Send Alert via go-wa`, and the admin
     `go-wa: List Groups` nodes.
3. Set env vars on the n8n instance: **`GOWA_BASE_URL`** (go-wa base URL, used by every send/list
   node with a `http://localhost:3000` fallback), **`GOWA_DEVICE_ID`** (multi-device go-wa requires
   it; sent as the `X-Device-Id` header on all go-wa calls — find it via `GET {base}/app/devices`),
   and **`WAG_ALERT_TO`** (failure-alert recipient). Not hardcoded — URLs/headers are
   `={{ $env.* }}` expressions, overridable by the wizard form fields.
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
