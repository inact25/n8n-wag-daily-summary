# n8n-wag-daily-summary

> Daily WhatsApp group chat summaries with [n8n](https://n8n.io),
> [go-whatsapp-web-multidevice](https://github.com/aldinokemal/go-whatsapp-web-multidevice),
> Postgres, and Google Gemini.

This project automatically collects a WhatsApp group's messages throughout the day and, every
night, uses an LLM to post a clean, structured **daily summary** (topics discussed + action
items + stats) back to a WhatsApp number. It handles **many groups at once** — each active group
gets its own summary sent to its own recipient.

The whole thing ships as **exported n8n workflow JSON** — there is no application code and no
build step. You import the workflows into your own n8n instance, add credentials, and run.

---

## Table of contents

- [Example output](#example-output)
- [Features](#features)
- [Architecture](#architecture)
- [Tech stack](#tech-stack)
- [Repository structure](#repository-structure)
- [Prerequisites](#prerequisites)
- [Full install from scratch (Docker Compose)](#full-install-from-scratch-docker-compose)
- [Setup](#setup)
  - [1. go-wa (WhatsApp gateway)](#1-go-wa-whatsapp-gateway)
  - [2. Import the workflows](#2-import-the-workflows)
  - [3. Create credentials](#3-create-credentials)
  - [4. Set configuration values](#4-set-configuration-values)
  - [5. Run Quick Setup](#5-run-quick-setup-recommended)
  - [6. Point the go-wa webhook and activate](#6-point-the-go-wa-webhook-and-activate)
  - [7. Wire up error alerts](#7-wire-up-error-alerts)
  - [SQL alternative](#sql-alternative)
- [How it works](#how-it-works)
- [Configuration reference](#configuration-reference)
- [Managing groups](#managing-groups)
- [Customization](#customization)
- [Operations & monitoring](#operations--monitoring)
- [Troubleshooting](#troubleshooting)
- [Cost](#cost)
- [Security](#security)
- [Regenerating the workflow JSON](#regenerating-the-workflow-json)

---

## Example output

```
WHNYHProject Daily Summary
📅 02 Juli 2026

Topik Dibahas:
- UI/Design review & roasting — tampilan perlu perbaikan, Javapixa Studio handle UI
- Knowledge Base (KB) bermasalah — ada instruksi mencurigakan, perlu dicek
- Multi-service masih fail — error pada multi-service

Pesan Penting / Action Items:
- Benerin KB yang ada instruksi aneh (Indra & Javapixa Studio)
- Multi-service perlu di-fix (Javapixa Studio)

Statistik:
- Total pesan: 114
- Anggota aktif: 5 orang (Indra, Angga Pixa, Javapixa Studio, rohimdev.com, Ibrahim)
```

---

## Features

- **One-step Quick Setup** — an in-n8n Form where you enter a single thing (the number that
  receives summaries); it creates the database and registers **all** your WhatsApp groups. No SQL,
  no "Chat JID" to look up. A separate Advanced form covers per-group tweaks.
- **Multi-group** — summarize any number of groups from one workflow; add/remove a group from the
  wizard (or a database row), no workflow changes.
- **Real-time ingestion** — every incoming message is captured via webhook and stored.
- **Deduplication** — `message_id` is unique; webhook retries never double-count.
- **Structured LLM output** — Gemini is forced (via a JSON schema) to return `topics[]` and
  `action_items[]`; the message is rendered deterministically, not parsed from free text.
- **Exact statistics** — message counts and active members are computed from the database, never
  guessed by the LLM.
- **Idempotent + auditable** — one row per group per day in `wag_summaries` (status
  `success`/`empty`/`error`); re-runs upsert.
- **Fault-isolated** — if one group fails (or Gemini hiccups), the others still complete.
- **Failure alerts** — an Error Trigger workflow sends you a WhatsApp message when anything breaks.
- **Guardrails** — transcript size cap for runaway high-volume days; media stored as
  `[image]`/`[video]`/… with captions.

---

## Architecture

Ingestion (real-time) and summarization (nightly batch) are decoupled, because go-wa cannot
return "all of today's messages" in a single call. They communicate through three Postgres tables.

```
  wag-chat-ingest.json                          wag-daily-summary.json
  ────────────────────                          ──────────────────────
  WhatsApp group                                Every day 07:00 WIB (summarize yesterday)
       │                                                │
     go-wa ──(webhook)──▶ go-wa Webhook          Get Active Groups ──▶ wag_groups
                             │                          │
                    Normalize Payload             Loop Over Groups ──done──▶ All Groups Done
                     (fields + media)                   │  (one iteration per group)
                             │                          ▼
                    Group message w/ text?      Get Today's Messages ──▶ wag_messages
                             │ yes                       │
                             ▼                    Build Transcript (+ exact stats + prompt)
                     Upsert Message                      │
                             │                    Any messages today?
                             ▼                     ├─ yes ▶ Summarize (LLM Chain)
                       wag_messages                │         ├── Google Gemini Chat Model
                     (dedupe message_id)           │         └── Structured Output Parser
                                                   │             ▶ Render Summary
                                                   └─ no  ▶ No Activity Message
                                                          │
                                                   Send via go-wa ──▶ Log Summary ──▶ wag_summaries
                                                          └──────────── loops back to Loop ──────────┘

  wag-error-alert.json:  On Workflow Error ──▶ Build Alert ──▶ Send Alert via go-wa
  (set as the "Error Workflow" of the two workflows above)
```

---

## Tech stack

| Component | Role |
|-----------|------|
| **n8n** | Orchestration / workflow engine (self-hosted recommended). |
| **go-whatsapp-web-multidevice** ("go-wa") | WhatsApp gateway — receives messages (webhook) and sends messages (REST API). |
| **PostgreSQL** | Stores the group registry, ingested messages, and the daily run log. |
| **Google Gemini** (`gemini-2.5-flash`) | Writes the topic/action-item narrative via n8n's native LangChain nodes. |

---

## Repository structure

```
.
├── workflows/
│   ├── wag-setup.json           # Quick Setup form: 1 field → install DB + register all groups
│   ├── wag-admin.json           # Manage Groups (Advanced): per-group add/update/remove
│   ├── wag-chat-ingest.json     # go-wa webhook → normalize → Postgres (dedupe)
│   ├── wag-daily-summary.json   # schedule 07:00 → loop groups → Gemini → send → log
│   ├── wag-error-alert.json     # Error Trigger → WhatsApp alert to admin
│   ├── wag-reset.json           # Form: wipe groups/messages/summaries/config (typed confirm)
│   └── wag-data.json            # Data Browser form: view groups/messages/summaries/config (read-only)
├── db/
│   └── schema.sql               # wag_groups, wag_messages, wag_summaries (optional; wizard does this)
├── docker-compose.yml           # full stack: Postgres + go-wa + n8n, pre-wired
├── .env.example                 # copy to .env for docker-compose
├── CLAUDE.md                    # architecture notes for AI coding assistants
└── README.md
```

---

## Prerequisites

- A running **n8n** instance (v1.x). Self-hosted is recommended so go-wa can reach its webhook.
- A running **go-wa** instance, already logged in to the WhatsApp account, with:
  - its REST API reachable from n8n (default `http://localhost:3000`), and
  - HTTP Basic Auth enabled.
- A **PostgreSQL** database n8n can connect to (the wizard creates the tables for you — you don't
  need `psql`).
- A **Google AI Studio API key** for Gemini (<https://aistudio.google.com/app/apikey>).

> New to all this? The [Docker Compose](#full-install-from-scratch-docker-compose) below brings up
> n8n, go-wa, and Postgres for you — you only need Docker and the Gemini key.

---

## Full install from scratch (Docker Compose)

Don't already run n8n / go-wa / Postgres? This starts all three, pre-wired (go-wa's webhook already
points at n8n, and `GOWA_BASE_URL` / `WAG_ALERT_TO` are already set). **Requirements:** Docker +
Docker Compose.

**1. Get the code and configure secrets**

```bash
git clone https://github.com/inact25/n8n-wag-daily-summary.git
cd n8n-wag-daily-summary
cp .env.example .env
# edit .env: set POSTGRES_PASSWORD, GOWA_USER/GOWA_PASS, WAG_ALERT_TO
```

**2. Start the stack**

```bash
docker compose up -d
```

- **n8n** → <http://localhost:5678> — create the owner account on first visit.
- **go-wa** → <http://localhost:3000> — log in with the go-wa basic-auth user/pass, then **scan the
  QR** (WhatsApp → *Linked devices*) to connect your WhatsApp account.

**3. Credential values for this stack** (used in [step 3](#3-create-credentials) below)

| Credential | Values |
|-----------|--------|
| Postgres | host `postgres`, port `5432`, database/user/password from your `.env`, SSL **disabled** |
| go-wa basic auth | the `GOWA_USER` / `GOWA_PASS` from your `.env` |
| Google Gemini (PaLM) API | your Google AI Studio API key |

**4. What's already done for you** — Compose handles Setup steps **1** (go-wa) and **4** (env vars),
and go-wa's webhook is already wired. So from the [Setup](#setup) section you only need:
**step 2** (import workflows), **step 3** (create the 3 credentials above), **step 5** (Quick Setup),
**step 6** (activate — the webhook is already pointed), and **step 7** (error alerts).

---

## Setup

Everything except the Postgres server itself is done **inside n8n**. The **Quick Setup** form
creates the database tables and registers all your groups from one field — you never run `psql` or
look up a Chat JID. (A raw `db/schema.sql` and a **Manage Groups (Advanced)** form are included for
SQL-first setups and per-group control — see [the SQL alternative](#sql-alternative).)

### 1. go-wa (WhatsApp gateway)

Follow the [go-wa docs](https://github.com/aldinokemal/go-whatsapp-web-multidevice) to run the
gateway and log in. Enable **Basic auth** (so n8n can call it) and note its base URL
(default `http://localhost:3000`). The webhook is configured in step 6.

### 2. Import the workflows

In n8n: **Add workflow → ⋯ menu → Import from File**, and import all four files under `workflows/`.
Or via the CLI on a self-hosted instance:

```bash
n8n import:workflow --input=workflows/wag-setup.json
n8n import:workflow --input=workflows/wag-admin.json
n8n import:workflow --input=workflows/wag-chat-ingest.json
n8n import:workflow --input=workflows/wag-daily-summary.json
n8n import:workflow --input=workflows/wag-error-alert.json
n8n import:workflow --input=workflows/wag-reset.json
n8n import:workflow --input=workflows/wag-data.json
```

Each workflow has a stable ID, so re-importing later **updates it in place** instead of creating a
duplicate. (Verified against n8n 2.28.5.)

### 3. Create credentials

Create these three credentials in n8n and assign them to the nodes that use them (imported nodes
carry placeholder credential IDs you must replace):

| Credential type | Used by | Notes |
|-----------------|---------|-------|
| **Postgres** | admin `Create Tables` / `Upsert Group` / `Select Groups` / `Delete Group`, plus `Upsert Message`, `Get Active Groups`, `Get Today's Messages`, `Log Summary` | Your database connection. |
| **Google Gemini (PaLM) API** | `Google Gemini Chat Model` | Paste your Google AI Studio API key. |
| **HTTP Basic Auth** | `Send via go-wa`, `Send Alert via go-wa`, `go-wa: List Groups` | Your go-wa username/password. |

### 4. Configure go-wa settings

The go-wa base URL, device id, and alert recipient are stored **in the database** (a `wag_config`
table) and read by the workflows at run time — **no environment variables and no node edits
required** (handy on self-hosted n8n where `$env` access may be disabled). **Quick Setup (step 5)
writes these for you** from its form fields, so most people can skip straight to step 5.

Each value resolves in this order: **`wag_config` (DB) → env var → built-in default.** So env vars
are an optional alternative/fallback:

| Setting | `wag_config` key | Env fallback | Default |
|---------|------------------|--------------|---------|
| go-wa base URL | `gowa_base_url` | `GOWA_BASE_URL` | `http://localhost:3000` |
| go-wa device id (multi-device; sent as `X-Device-Id`) | `gowa_device_id` | `GOWA_DEVICE_ID` | empty |
| alert recipient (digits, no `+`) | `alert_to` | `WAG_ALERT_TO` | built-in |

> **Finding your device id:** after go-wa is logged in, call
> `GET {base}/app/devices` (with the go-wa Basic Auth). The id is
> `results.devices[].device_id` (e.g. `org_2`). If go-wa returns `DEVICE_ID_REQUIRED`, this is
> what's missing.

Other settings — schedule, timezone, model, message format — are covered under
[Customization](#customization).

### 5. Run Quick Setup (recommended)

This is the whole database setup — no SQL, no Chat JID. Open **WAG Chat — Quick Setup** and click
**Execute Workflow** (or open the form's test URL from the `Quick Setup Form` node). A web form asks
for one thing:

- **Summary recipient number** — the WhatsApp number that should receive the daily summaries
  (digits only, e.g. `628xxxxxxxxxx`).
- *(optional)* **go-wa URL** — only if you didn't set the `GOWA_BASE_URL` env var.

Submit, and it: creates the database tables (idempotent), fetches **all** your WhatsApp groups from
go-wa, and registers every one of them to that number — summarized each morning at 07:00 (previous day). Done.

#### Advanced: manage individual groups

Need different recipients per group, or to disable/remove one? Open **WAG Chat — Manage Groups
(Advanced)**. Its form has an **Action** dropdown:

| Action | What it does |
|--------|--------------|
| Install database schema | Creates the tables (same as Quick Setup; idempotent). |
| Show WhatsApp groups (from go-wa) | Lists your groups **with their Chat JIDs** (`…@g.us`) so you can copy one. |
| Register ALL WhatsApp groups (bulk) | Same bulk registration as Quick Setup. |
| Save group (add or update) | Add/edit one group — needs **Chat JID**, **Project name**, **Send to number**, **Active**. |
| List registered groups | Shows what's currently registered. |
| Remove group | Deletes one group by **Chat JID**. |

A **Chat JID** is a group's WhatsApp address, like `1203XXXXXXXXXXXXXX@g.us` — use *Show WhatsApp
groups* to find it; you never type it by hand for Quick Setup.

### 6. Point the go-wa webhook and activate

- Activate **WAG Chat — Ingest**. **Docker Compose users:** go-wa's webhook already points at
  `http://n8n:5678/webhook/wag-incoming`, so you're done — just activate. Otherwise, copy the node's
  **Production URL** (`https://<your-n8n-host>/webhook/wag-incoming`) and set it as go-wa's webhook
  (the exact flag/env varies by go-wa version — typically `--webhook` or `WHATSAPP_WEBHOOK`).
- Activate **WAG Chat — Daily Summary**. It runs daily at 07:00 Asia/Jakarta and summarizes the previous day.

### 7. Wire up error alerts (recommended)

For each of `wag-chat-ingest` and `wag-daily-summary`, open **Settings → Error Workflow** and
select **WAG Chat — Error Alert**. The Error Trigger only fires for workflows that name it, and
the link can't be pre-baked into the JSON because workflow IDs don't exist until after import.

To test the summary immediately, open **WAG Chat — Daily Summary** and click **Execute Workflow** —
it summarizes whatever is already in `wag_messages` for today.

### SQL alternative

Prefer SQL, or automating provisioning? You can skip the wizard's "Install database schema" and
"Save group" actions and run `db/schema.sql` plus `INSERT`s directly (see
[Managing groups](#managing-groups)). The wizard and the SQL do exactly the same thing.

---

## How it works

### Ingestion (`wag-chat-ingest`)

1. **go-wa Webhook** receives a `POST` from go-wa for every incoming message.
2. **Normalize Payload** maps the (version-dependent) go-wa payload to flat fields, detects media
   type (`image`/`video`/…), and keeps the raw payload in `wag_messages.raw` for debugging.
3. **Group message with text?** keeps only group messages (`...@g.us`) that have text/caption.
4. **Upsert Message** inserts into `wag_messages` with `ON CONFLICT (message_id) DO NOTHING`.

### Summary (`wag-daily-summary`)

1. **Every day 07:00** triggers the run (timezone `Asia/Jakarta`); the queries below use the *previous* Jakarta day.
2. **Get Active Groups** reads all `active` rows from `wag_groups`.
3. **Loop Over Groups** iterates one group at a time (batch size 1).
4. **Get Today's Messages** pulls that group's messages for "today" in Asia/Jakarta.
5. **Build Transcript** assembles a timestamped transcript, computes exact stats (total messages,
   distinct senders), formats the Indonesian date, and builds the LLM prompt. A `MAX_CHARS` cap
   trims very large days.
6. **Any messages today?** branches:
   - **Yes →** **Summarize (LLM Chain)** runs **Google Gemini Chat Model** with a **Structured
     Output Parser** that enforces `{ topics[], action_items[] }`. **Render Summary** turns that
     object + the DB stats into the final message.
   - **No →** **No Activity Message** produces a short "no activity today" note.
7. **Send via go-wa** sends the message to the group's `send_to` number.
8. **Log Summary** upserts the run into `wag_summaries`, then the loop continues to the next group.

### Error alerts (`wag-error-alert`)

**On Workflow Error** fires when a linked workflow fails; **Build Alert** formats the workflow
name, failing node, and error message; **Send Alert via go-wa** sends it to the admin number.

---

## Configuration reference

| Setting | Default | Location |
|---------|---------|----------|
| Webhook path | `wag-incoming` | `go-wa Webhook` node (ingest) |
| Run time | `07:00` (summarize yesterday) | `Every day 07:00` node → hour/minute |
| Timezone | `Asia/Jakarta` | each workflow's **Settings → Timezone** |
| LLM model | `gemini-2.5-flash` | `Google Gemini Chat Model` node |
| LLM temperature | `0.3` | `Google Gemini Chat Model` node options |
| Transcript cap | `40000` chars | `MAX_CHARS` in `Build Transcript` code |
| go-wa base URL / device id | `wag_config` table (`gowa_base_url`, `gowa_device_id`) → env → default | written by Quick Setup; read by `Get Config` |
| Alert recipient | `wag_config` (`alert_to`) → `WAG_ALERT_TO` → built-in | `Build Alert` code |
| Groups & recipients | — | `wag_groups` table (via Quick Setup / Admin wizard) |

---

## Managing groups

The easiest way is **Quick Setup** (registers all groups at once). To adjust individual entries,
use **Manage Groups (Advanced)**: *Save group* / *List registered groups* / *Remove group*. If you'd
rather use SQL, change the registry table directly:

```sql
-- Add a group
INSERT INTO wag_groups (chat_jid, project_name, send_to)
VALUES ('1203...@g.us', 'New Project', '6285609200000');

-- Pause a group (keeps history, stops summaries)
UPDATE wag_groups SET active = false WHERE chat_jid = '1203...@g.us';

-- Re-enable it
UPDATE wag_groups SET active = true WHERE chat_jid = '1203...@g.us';

-- Change who receives a group's summary
UPDATE wag_groups SET send_to = '6281234567890' WHERE chat_jid = '1203...@g.us';

-- Remove a group entirely
DELETE FROM wag_groups WHERE chat_jid = '1203...@g.us';
```

### View your data (no SQL)

Don't want to run `SELECT`s? Import **`wag-data.json`** and open **WAG Chat — Data Browser**. It's a
read-only form — pick a **View** and submit; nothing is ever written or deleted:

- **Overview (counts & health)** — totals for groups/messages/summaries, messages today vs.
  yesterday, and the time of the last message received (quick "is ingest working?" check).
- **Registered groups** — every row in `wag_groups` with an 🟢/⚪ active flag, its recipient, how
  many messages it has, and when the last one arrived.
- **Recent messages** — latest messages newest-first; optional **Filter: Chat JID** to narrow to one
  group and **Limit** (50–500). Media shows as `[image]`/`[video]`/…
- **Daily summaries** — the `wag_summaries` audit trail: date, status (`success`/`empty`/`error`),
  counts, and the first line of each sent summary.
- **go-wa config** — the `wag_config` key/values the workflows read.

### Reset / cleanup (no SQL)

`go-wa` returns **every** group your account belongs to (communities, old groups…), so "register all"
can store far more than you actively use. To start clean, run **WAG Chat — Reset / Cleanup**: a form
that (after you type `RESET` to confirm) can:

- **Remove ALL registered groups** — clears `wag_groups`; then re-run Quick Setup for a fresh set.
- **Clear captured messages** / **Clear summary history** / **Reset go-wa settings** — individually.
- **FULL RESET** — wipe groups, messages, summaries, and config in one go.

The tables themselves are kept; only rows are deleted. (The daily run already ignores registered
groups that had no messages that day, so pruning is optional — but this keeps things tidy.)

---

## Customization

- **Delay between sends** — the `Delay Between Sends` (Wait) node pauses 5s between per-group
  messages to avoid WhatsApp rate-limiting; change its amount if you have many groups.
- **Empty groups don't send** — groups with no messages that day are logged (`status = empty`) but
  not messaged. Only groups with activity produce a WhatsApp message.
- **Group name in the header** — comes from `wag_groups.project_name`, set from the go-wa group name
  at registration. If a header shows `Group`/`Grup xxxx`, re-run registration or fix it via *Save
  group* / SQL `UPDATE wag_groups SET project_name = '…' WHERE chat_jid = '…'`.
- **Change the run time / window** — the default is **07:00, summarizing the previous full day**
  (00:00–24:00, no end-of-day gap). Edit the `Every day 07:00` schedule node to change the time. The
  "previous day" window lives in three places that must stay in sync: `Get Active Groups`,
  `Get Today's Messages` (both use `date_trunc('day', now() …) - interval '1 day'` … `< date_trunc(…)`),
  and the `dateStr` in `Build Transcript` (`jak.setDate(jak.getDate() - 1)`), plus the `summary_date`
  in `Log Summary`. To go back to same-night, run at 23:00 and drop the `- interval '1 day'` shifts.
- **Change the timezone** — set it in each workflow's **Settings → Timezone**, and update the
  `Asia/Jakarta` strings in `Build Transcript` and the `Get Today's Messages` query.
- **Change the model** — set `models/<name>` on `Google Gemini Chat Model` (e.g. a Pro model for
  higher quality, a Flash-Lite model for lower cost).
- **Change the message layout** — edit `Render Summary` (and `No Activity Message`). These build
  the final text deterministically; the header, sections, and stats live here.
- **Change the summary sections** — edit the JSON schema in `Structured Output Parser` and the
  prompt in `Build Transcript` together, then reflect the new fields in `Render Summary`.
- **Change the language** — the prompt in `Build Transcript` and the month names / labels in the
  code nodes are Indonesian; translate them as needed.

---

## Operations & monitoring

Handy SQL against the database:

```sql
-- Recent runs and their outcome
SELECT summary_date, chat_jid, status, message_count, member_count, created_at
FROM wag_summaries ORDER BY created_at DESC LIMIT 20;

-- Is ingestion flowing? (should keep increasing)
SELECT count(*) AS total, max("timestamp") AS latest FROM wag_messages;

-- Messages per group today (Asia/Jakarta)
SELECT chat_jid, count(*)
FROM wag_messages
WHERE ("timestamp" AT TIME ZONE 'Asia/Jakarta') >= date_trunc('day', now() AT TIME ZONE 'Asia/Jakarta')
GROUP BY chat_jid;

-- Runs that errored
SELECT * FROM wag_summaries WHERE status = 'error' ORDER BY created_at DESC;
```

In n8n itself, use **Executions** to inspect individual runs of each workflow.

---

## Troubleshooting

| Symptom | Likely cause / fix |
|---------|--------------------|
| No rows appearing in `wag_messages` | go-wa webhook not pointing at `…/webhook/wag-incoming`, or the ingest workflow isn't **active**. Check go-wa logs and n8n Executions. |
| `chat_jid` / `sender_name` / `message` stored blank | go-wa payload field names differ by version. Open a `raw` row and adjust the mappings in `Normalize Payload`. |
| Summary sends but stats say `0` / "no activity" | Nothing stored for that group today, or the group JID in `wag_groups` doesn't match what's ingested. Compare `chat_jid` values. |
| Gemini errors / empty narrative | Bad/expired API key on `Google Gemini Chat Model`, quota exhausted, or model name typo. The run is still logged with status `error`. |
| Message not delivered | Wrong go-wa base URL / basic-auth credential, `send_to` not in international digits (no `+`), or go-wa not logged in. |
| Wizard form does nothing / "Save group" has no effect | Postgres credential not assigned on the admin nodes, or you skipped **Install database schema** first. Run that action once, then retry. |
| "Show WhatsApp groups" returns nothing | go-wa basic-auth credential/URL wrong on `go-wa: List Groups`, or go-wa not logged in. |
| go-wa returns `DEVICE_ID_REQUIRED` (400) | Multi-device go-wa needs a device id. Set `GOWA_DEVICE_ID` env (or fill the form's *go-wa device id*); find it via `GET {base}/app/devices`. |
| Postgres node errors on import | n8n version differs from the exported node version (see below). Re-open and re-save the node. |

**Version-sensitive spots** (glance at these after importing into a different n8n version):

- **Loop Over Groups** outputs — expected order is **0 = done, 1 = loop**. If reversed, swap the
  two connections.
- **Postgres** parameterized inserts use `queryReplacement` (node typeVersion 2.6).
- Native LangChain nodes: `chainLlm` 1.6, `lmChatGoogleGemini` 1, `outputParserStructured` 1.2.

---

## Cost

Gemini cost scales with transcript size. As a rule of thumb, a busy group of ~1,000 messages/day
is ~25k input tokens per run. Ten such groups is roughly **a few US dollars per month** on
`gemini-2.5-flash`, and well under a dollar on a Flash-Lite model — verify current pricing at
<https://ai.google.dev/pricing>. One Gemini call per group per day keeps this the cheapest option.

---

## Security

- Secrets (Gemini key, go-wa basic auth, DB password) live **only** in n8n credentials — never in
  the workflow JSON or this repo. Do not commit `.env` files or real credential values.
- The `Get Today's Messages` query inlines the group JID from your own `wag_groups` table (trusted
  data); all values derived from chat content are passed as **bound parameters**, not string-
  concatenated into SQL.
- go-wa should be reachable only from your n8n instance (private network / firewall), not exposed
  publicly.

---

## Regenerating the workflow JSON

The workflow files are generated by a small Node script that builds the workflow objects and
`JSON.stringify`s them — this keeps the embedded Code-node JavaScript readable and guarantees
valid JSON. For **small** changes, edit in the n8n UI and re-export
(`n8n export:workflow --all --output=workflows/ --pretty`). For **structural** changes across many
nodes, regenerate. Always validate a hand-edit:

```bash
node -e "JSON.parse(require('fs').readFileSync('workflows/wag-daily-summary.json'))"
```
