-- Laeuft in der Datenbank "hl7" (POSTGRES_DB).
CREATE SCHEMA IF NOT EXISTS hl7;
COMMENT ON SCHEMA hl7 IS 'Zieldaten der HL7-ADT-Integration';

-- ---------------------------------------------------------------------------
-- message_log: eine Zeile pro eingehender Nachricht, gueltig oder nicht.
-- Das ist der Anker fuer Monitoring: "status" und "received_at" beantworten
-- die Frage, ob Nachrichten haengen bleiben.
-- ---------------------------------------------------------------------------
CREATE TABLE hl7.message_log (
    id                BIGSERIAL PRIMARY KEY,
    control_id        TEXT        NOT NULL,          -- MSH-10
    sending_facility  TEXT        NOT NULL DEFAULT '',  -- MSH-4
    message_type      TEXT,                          -- MSH-9.1, z.B. ADT
    trigger_event     TEXT,                          -- MSH-9.2, z.B. A01
    message_version   TEXT,                          -- MSH-12
    received_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    processed_at      TIMESTAMPTZ,
    status            TEXT        NOT NULL DEFAULT 'received',
    raw_message       TEXT        NOT NULL,
    CONSTRAINT message_log_status_chk
        CHECK (status IN ('received', 'processed', 'error')),
    -- Ein Sender darf dieselbe MSH-10 nicht zweimal vergeben. Wiederholungen
    -- sind damit erkennbar statt stillschweigend doppelt gespeichert.
    CONSTRAINT message_log_control_id_uq UNIQUE (sending_facility, control_id)
);

-- Der Index, auf dem das Monitoring sitzt: offene Nachrichten nach Alter.
CREATE INDEX message_log_open_idx
    ON hl7.message_log (received_at)
    WHERE status = 'received';
CREATE INDEX message_log_status_idx ON hl7.message_log (status, received_at DESC);

COMMENT ON COLUMN hl7.message_log.status IS
    'received = angenommen, noch nicht verarbeitet; processed = fertig; error = in der Fehlerablage';

-- ---------------------------------------------------------------------------
-- patient_event: die fachlichen Daten aus einer gueltigen ADT-Nachricht.
-- ---------------------------------------------------------------------------
CREATE TABLE hl7.patient_event (
    id                  BIGSERIAL PRIMARY KEY,
    message_log_id      BIGINT      NOT NULL
                        REFERENCES hl7.message_log (id) ON DELETE CASCADE,
    trigger_event       TEXT        NOT NULL,   -- A01, A03, A08 ...
    event_occurred_at   TIMESTAMPTZ,            -- EVN-2
    patient_id          TEXT        NOT NULL,   -- PID-3.1
    patient_id_authority TEXT,                  -- PID-3.4
    last_name           TEXT,                   -- PID-5.1
    first_name          TEXT,                   -- PID-5.2
    birth_date          DATE,                   -- PID-7
    gender              TEXT,                   -- PID-8
    visit_number        TEXT,                   -- PV1-19
    patient_class       TEXT,                   -- PV1-2
    assigned_location   TEXT,                   -- PV1-3 (zusammengesetzt)
    attending_physician TEXT,                   -- PV1-7
    admitted_at         TIMESTAMPTZ,            -- PV1-44
    discharged_at       TIMESTAMPTZ,            -- PV1-45
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX patient_event_patient_idx ON hl7.patient_event (patient_id, event_occurred_at DESC);
CREATE INDEX patient_event_visit_idx   ON hl7.patient_event (visit_number);
CREATE INDEX patient_event_log_idx     ON hl7.patient_event (message_log_id);

-- ---------------------------------------------------------------------------
-- message_error: die Fehlerablage. Bewusst eine eigene Tabelle, damit ein
-- Fehler einen Lebenszyklus hat (aufgetreten -> erneut versucht -> geklaert).
-- ---------------------------------------------------------------------------
CREATE TABLE hl7.message_error (
    id              BIGSERIAL PRIMARY KEY,
    message_log_id  BIGINT      REFERENCES hl7.message_log (id) ON DELETE CASCADE,
    control_id      TEXT,
    reason          TEXT        NOT NULL,   -- kurzer Code, z.B. MISSING_SEGMENT
    details         JSONB       NOT NULL DEFAULT '{}'::jsonb,
    raw_message     TEXT,
    occurred_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    retry_count     INT         NOT NULL DEFAULT 0,
    last_retry_at   TIMESTAMPTZ,
    resolved_at     TIMESTAMPTZ,
    resolved_by     TEXT,
    resolution_note TEXT
);

CREATE INDEX message_error_open_idx
    ON hl7.message_error (occurred_at DESC)
    WHERE resolved_at IS NULL;
CREATE INDEX message_error_reason_idx ON hl7.message_error (reason, occurred_at DESC);
