-- Postgres schema for wag-chat-summary
-- Run once against the database configured in n8n's Postgres credential.

-- ---------------------------------------------------------------------------
-- Group registry: the summary workflow loops over every active row here.
-- Add a group = insert a row. No workflow edit needed.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS wag_groups (
    chat_jid     TEXT PRIMARY KEY,               -- e.g. 1203...@g.us
    project_name TEXT        NOT NULL,           -- shown in the summary header
    send_to      TEXT        NOT NULL,           -- phone that receives the summary (digits, no +)
    active       BOOLEAN     NOT NULL DEFAULT TRUE,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------------
-- Raw ingested messages. message_id is unique so webhook retries dedupe.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS wag_messages (
    id          BIGSERIAL PRIMARY KEY,
    message_id  TEXT        UNIQUE,              -- go-wa message id (NULL allowed; NULLs never conflict)
    chat_jid    TEXT        NOT NULL,
    sender_jid  TEXT,
    sender_name TEXT,
    message     TEXT,                            -- text or caption; media stored as "[image]" etc.
    media_type  TEXT,                            -- image|video|audio|document|sticker|location|NULL
    is_group    BOOLEAN     NOT NULL DEFAULT TRUE,
    "timestamp" TIMESTAMPTZ NOT NULL DEFAULT now(),
    raw         TEXT                             -- full go-wa payload (JSON string) for debugging
);

CREATE INDEX IF NOT EXISTS idx_wag_messages_chat_time
    ON wag_messages (chat_jid, "timestamp");

-- ---------------------------------------------------------------------------
-- One row per group per day: audit trail + idempotency for the daily run.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS wag_summaries (
    id            BIGSERIAL PRIMARY KEY,
    chat_jid      TEXT        NOT NULL,
    summary_date  DATE        NOT NULL,
    message_count INT         NOT NULL DEFAULT 0,
    member_count  INT         NOT NULL DEFAULT 0,
    status        TEXT        NOT NULL,          -- success | empty | error
    summary_text  TEXT,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (chat_jid, summary_date)
);

-- ---------------------------------------------------------------------------
-- Key/value config so the workflows need no environment variables.
-- Quick Setup writes gowa_base_url / gowa_device_id / alert_to here; the
-- summary and error workflows read them via their "Get Config" node.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS wag_config (
    key   TEXT PRIMARY KEY,
    value TEXT
);

-- ---------------------------------------------------------------------------
-- Seed example — edit and run to register your groups.
-- ---------------------------------------------------------------------------
-- INSERT INTO wag_groups (chat_jid, project_name, send_to) VALUES
--   ('1203XXXXXXXXXXXXXX@g.us', 'WHNYHProject', '6285609200000')
-- ON CONFLICT (chat_jid) DO NOTHING;
