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

Three runtime workflows plus an admin wizard share three Postgres tables (`db/schema.sql`).
Ingestion (real-time) and summarization (daily batch) are decoupled because go-wa cannot return
"all of today's messages" in one call. **`wag-admin.json`** is an n8n Form (`formTrigger` →
`switch` → per-action Postgres/HTTP → shared `form` completion page) that installs the schema and
does group CRUD, so users never touch `psql`. It runs the same DDL as `db/schema.sql` and the same
upsert as the SQL in the README — keep the two in sync if you change columns.

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

1. Preferred: import `wag-admin.json`, run it, and use the form — *Install database schema*, then
   *Register ALL WhatsApp groups (bulk)* (one submission registers every go-wa group to a single
   recipient) or *Save group* for individual entries. The form's *go-wa base URL* field feeds the
   go-wa actions. Equivalent to running `db/schema.sql` and `INSERT`ing into `wag_groups` by hand
   (still supported for SQL-first setups).
2. Create three n8n credentials and map them onto the placeholder-credential nodes:
   - **Postgres** — on the admin nodes plus `Upsert Message`, `Get Active Groups`,
     `Get Today's Messages`, `Log Summary`.
   - **Google Gemini (PaLM) API** (an API key from Google AI Studio) — on the
     `Google Gemini Chat Model` sub-node.
   - **HTTP Basic Auth** for go-wa — on `Send via go-wa`, `Send Alert via go-wa`, and the admin
     `go-wa: List Groups` nodes.
3. Set env vars on the n8n instance: **`GOWA_BASE_URL`** (go-wa base URL, used by every send/list
   node with a `http://localhost:3000` fallback) and **`WAG_ALERT_TO`** (failure-alert recipient).
   These are not hardcoded in nodes — the URLs are `={{ $env.GOWA_BASE_URL || '...' }}` expressions.
4. Point go-wa's webhook at `https://<n8n-host>/webhook/wag-incoming`; activate the ingest and
   summary workflows.
5. **Error alerts:** import `wag-error-alert.json` (an Error Trigger → go-wa message; recipient via
   `WAG_ALERT_TO`). Then in **both** other workflows set
   *Settings → Error Workflow* to it — the trigger only fires for workflows that name it. This is
   the only cross-workflow link and must be set after import (IDs don't exist until then).

## go-wa integration facts

- **Send:** `POST {baseUrl}/send/message`, HTTP Basic Auth, JSON `{ "phone": "<digits,no +>", "message": "<text>" }`.
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
