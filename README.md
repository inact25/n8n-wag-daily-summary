# n8n-wag-chat-summary

[n8n](https://n8n.io) workflows that post a **daily summary of a WhatsApp group chat**.
Messages come in through [go-whatsapp-web-multidevice](https://github.com/aldinokemal/go-whatsapp-web-multidevice)
("go-wa"), are stored in Postgres, and once a day are summarized by Google Gemini and sent
back to a WhatsApp number via go-wa.

The daily message looks like:

```
WHNYHProject Daily Summary
📅 02 Juli 2026

Topik Dibahas:
- ...

Pesan Penting / Action Items:
- ...

Statistik:
- Total pesan: 114
- Anggota aktif: 5 orang (...)
```

It handles **many groups** — each active group in the `wag_groups` table gets its own daily
summary sent to its own recipient. This repository holds **exported workflow JSON only** —
there is no custom code or build step.

## Layout

```
workflows/
  wag-chat-ingest.json     go-wa webhook → normalize → Postgres (dedupe)
  wag-daily-summary.json   schedule 23:00 WIB → loop groups → Gemini → send → log
  wag-error-alert.json     Error Trigger → go-wa alert to admin on any failure
db/
  schema.sql               wag_groups, wag_messages, wag_summaries
CLAUDE.md                  architecture + setup notes
```

## Setup

1. Run `db/schema.sql` on your Postgres database.
2. Register groups: insert rows into `wag_groups` (`chat_jid`, `project_name`, `send_to`).
   See the seed example at the bottom of `db/schema.sql`.
3. Import both files under `workflows/` into n8n (*Add workflow → Import from File*).
4. Create and assign three credentials: Postgres, HTTP Header Auth for Gemini
   (`x-goog-api-key`), and HTTP Basic Auth for go-wa.
5. Set your **go-wa base URL** in the summary workflow's `Send via go-wa` node
   (default `http://localhost:3000`).
6. Point go-wa's webhook at `https://<n8n-host>/webhook/wag-incoming`, then activate the
   ingest and summary workflows.
7. Optional but recommended: import `wag-error-alert.json`, set the admin phone in its
   `Build Alert` node (default `6285609200000`), and in **both** other workflows set
   *Settings → Error Workflow* to **WAG Chat — Error Alert** so failures ping you on WhatsApp.

## Adding / removing groups

No workflow edits — just change the registry:

```sql
INSERT INTO wag_groups (chat_jid, project_name, send_to)
VALUES ('1203...@g.us', 'WHNYHProject', '6285609200000');

UPDATE wag_groups SET active = false WHERE chat_jid = '1203...@g.us';  -- pause a group
```

See [CLAUDE.md](CLAUDE.md) for the full architecture and the go-wa payload/API details.

## Credentials

Credentials (Gemini API key, go-wa auth, DB password) live inside n8n, never in the workflow
JSON or in this repo. Do not commit `.env` files or real secrets.
