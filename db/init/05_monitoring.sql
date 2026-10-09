-- ---------------------------------------------------------------------------
-- Sichten fuer das Monitoring und die Rechtevergabe.
-- Prometheus liest ausschliesslich diese Sichten ueber einen eigenen, nur
-- lesenden Benutzer - der Exporter kommt nie an raw_message und damit nie an
-- Patientendaten.
-- ---------------------------------------------------------------------------

-- Eine Zeile, die den Zustand der Pipeline beschreibt.
-- oldest_unprocessed_seconds ist DAS Signal fuer "Nachrichten bleiben haengen".
CREATE OR REPLACE VIEW hl7.v_pipeline AS
SELECT
    -- Alter der aeltesten noch nicht verarbeiteten Nachricht, in Sekunden.
    -- 0 heisst: es liegt nichts offen.
    COALESCE(
        EXTRACT(EPOCH FROM now() - MIN(received_at) FILTER (WHERE status = 'received')),
        0
    )::float8 AS oldest_unprocessed_seconds,

    -- Wie viele Nachrichten warten gerade.
    COUNT(*) FILTER (WHERE status = 'received')::float8 AS backlog,

    -- Alter der neuesten Nachricht ueberhaupt. Laeuft dieser Wert hoch,
    -- sendet das Quellsystem nicht mehr - ein ebenso wichtiger Ausfall, der
    -- ohne diese Metrik unsichtbar bleibt, weil dann eben nichts haengt.
    COALESCE(
        EXTRACT(EPOCH FROM now() - MAX(received_at)),
        -1
    )::float8 AS last_message_age_seconds,

    -- Durchsatz des letzten Zeitfensters, fuer das Dashboard.
    COUNT(*) FILTER (WHERE received_at > now() - INTERVAL '5 minutes')::float8
        AS received_last_5m
FROM hl7.message_log;

COMMENT ON VIEW hl7.v_pipeline IS
    'Kennzahlen der Verarbeitungsstrecke. Quelle fuer die Prometheus-Alarme.';

-- Nachrichten nach Status, als Label-Dimension fuer Prometheus.
CREATE OR REPLACE VIEW hl7.v_status_counts AS
SELECT status, COUNT(*)::float8 AS total
  FROM hl7.message_log
 GROUP BY status;

-- Offene Fehler nach Grund. Zeigt im Dashboard sofort, ob es ein Muster gibt
-- (ein kaputter Sender) oder ob es Einzelfaelle sind.
CREATE OR REPLACE VIEW hl7.v_error_reasons AS
SELECT
    reason,
    COUNT(*)::float8 AS open_total,
    COALESCE(EXTRACT(EPOCH FROM now() - MIN(occurred_at)), 0)::float8 AS oldest_seconds
  FROM hl7.message_error
 WHERE resolved_at IS NULL
 GROUP BY reason;

-- Fuer die taegliche Sichtung der Fehlerablage von Hand.
CREATE OR REPLACE VIEW hl7.v_error_inbox AS
SELECT
    e.id,
    e.occurred_at,
    e.control_id,
    e.reason,
    e.details,
    e.retry_count,
    l.sending_facility,
    l.trigger_event,
    left(e.raw_message, 200) AS raw_preview
  FROM hl7.message_error e
  LEFT JOIN hl7.message_log l ON l.id = e.message_log_id
 WHERE e.resolved_at IS NULL
 ORDER BY e.occurred_at DESC;

-- ---------------------------------------------------------------------------
-- Rechte fuer den Prometheus-Exporter.
-- Absichtlich OHNE Rechte auf die Tabellen selbst: nur die drei Sichten, und
-- keine davon enthaelt raw_message. Der Exporter kann damit konstruktiv keine
-- Patientendaten nach Prometheus tragen.
-- ---------------------------------------------------------------------------
GRANT CONNECT ON DATABASE hl7 TO hl7_monitor;
GRANT USAGE  ON SCHEMA hl7      TO hl7_monitor;
GRANT SELECT ON
    hl7.v_pipeline,
    hl7.v_status_counts,
    hl7.v_error_reasons
TO hl7_monitor;

-- pg_monitor gibt zusaetzlich die Standard-Postgres-Metriken (Verbindungen,
-- Locks, Transaktionsalter) frei, ohne Zugriff auf Nutzdaten.
GRANT pg_monitor TO hl7_monitor;

-- ---------------------------------------------------------------------------
-- Rechte fuer den Integrationsserver.
-- Er arbeitet ausschliesslich ueber die Funktionen, nicht direkt auf den
-- Tabellen. Ein Fehler im Kanal kann damit keine Zeile loeschen und den
-- Status nicht beliebig verbiegen.
-- ---------------------------------------------------------------------------
GRANT CONNECT ON DATABASE hl7 TO hl7_app;
GRANT USAGE ON SCHEMA hl7 TO hl7_app;

GRANT EXECUTE ON FUNCTION
    hl7.log_message(JSONB),
    hl7.complete_message(BIGINT, JSONB),
    hl7.reject_message(BIGINT, TEXT, JSONB),
    hl7.mark_error_retried(BIGINT)
TO hl7_app;

-- Die Funktionen laufen als Eigentuemer, damit hl7_app selbst keine
-- Tabellenrechte braucht.
ALTER FUNCTION hl7.log_message(JSONB)                  SECURITY DEFINER;
ALTER FUNCTION hl7.complete_message(BIGINT, JSONB)     SECURITY DEFINER;
ALTER FUNCTION hl7.reject_message(BIGINT, TEXT, JSONB) SECURITY DEFINER;
ALTER FUNCTION hl7.mark_error_retried(BIGINT)          SECURITY DEFINER;

-- Bei SECURITY DEFINER muss der search_path festgenagelt werden, sonst kann
-- ein Aufrufer mit eigenem search_path andere Objekte unterschieben.
ALTER FUNCTION hl7.log_message(JSONB)                  SET search_path = hl7, pg_temp;
ALTER FUNCTION hl7.complete_message(BIGINT, JSONB)     SET search_path = hl7, pg_temp;
ALTER FUNCTION hl7.reject_message(BIGINT, TEXT, JSONB) SET search_path = hl7, pg_temp;
ALTER FUNCTION hl7.mark_error_retried(BIGINT)          SET search_path = hl7, pg_temp;

-- Lesender Blick in die Fehlerablage.
GRANT SELECT ON hl7.v_error_inbox TO hl7_app;
