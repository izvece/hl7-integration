-- ---------------------------------------------------------------------------
-- Die Verarbeitungslogik. Sie liegt hier und nicht im Mirth-Kanal, damit sie
-- ohne laufenden Integrationsserver getestet werden kann - die CI-Pipeline
-- prueft genau diese Funktionen gegen ein frisches Postgres.
--
-- Wichtig ist die Zweiteilung: log_message() nimmt die Nachricht an,
-- complete_message() verarbeitet sie. Nur dadurch gibt es ueberhaupt einen
-- Zustand "angenommen, aber nicht verarbeitet" - und genau den beobachtet das
-- Monitoring. Wuerde eine einzige Funktion beides in einer Transaktion tun,
-- koennte eine Nachricht nie sichtbar haengen bleiben.
-- ---------------------------------------------------------------------------

-- Defensiver Cast: der Kanal liefert ISO-8601, aber eine kaputte Nachricht
-- darf die Transaktion nicht sprengen.
CREATE OR REPLACE FUNCTION hl7.safe_timestamp(p_value TEXT)
RETURNS TIMESTAMPTZ
LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    IF p_value IS NULL OR btrim(p_value) = '' THEN
        RETURN NULL;
    END IF;
    RETURN p_value::TIMESTAMPTZ;
EXCEPTION WHEN others THEN
    RETURN NULL;
END;
$$;

CREATE OR REPLACE FUNCTION hl7.safe_date(p_value TEXT)
RETURNS DATE
LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    IF p_value IS NULL OR btrim(p_value) = '' THEN
        RETURN NULL;
    END IF;
    RETURN p_value::DATE;
EXCEPTION WHEN others THEN
    RETURN NULL;
END;
$$;

-- ---------------------------------------------------------------------------
-- Schritt 1: Eingang festhalten.
-- Laeuft fuer JEDE Nachricht, gueltig oder nicht. Danach ist die Nachricht
-- nachweisbar angekommen, auch wenn alles Weitere scheitert.
--
-- Idempotent ueber (sending_facility, control_id): sendet das Quellsystem
-- dieselbe Nachricht erneut, entsteht keine zweite Zeile.
-- Rueckgabe: {"message_log_id": n, "duplicate": true|false}
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION hl7.log_message(p_payload JSONB)
RETURNS JSONB
LANGUAGE plpgsql AS $$
DECLARE
    v_log_id     BIGINT;
    v_control_id TEXT := NULLIF(p_payload ->> 'control_id', '');
    v_facility   TEXT := COALESCE(p_payload ->> 'sending_facility', '');
BEGIN
    -- Ohne MSH-10 ist die Nachricht nicht identifizierbar. Sie wird trotzdem
    -- festgehalten, nur unter einem erzeugten Schluessel - verwerfen waere
    -- hier das Schlimmste, was wir tun koennten.
    IF v_control_id IS NULL THEN
        v_control_id := 'OHNE-MSH10-' || gen_random_uuid()::text;
    END IF;

    INSERT INTO hl7.message_log (
        control_id, sending_facility, message_type, trigger_event,
        message_version, raw_message, status
    ) VALUES (
        v_control_id, v_facility,
        p_payload ->> 'message_type',
        p_payload ->> 'trigger_event',
        p_payload ->> 'message_version',
        COALESCE(p_payload ->> 'raw_message', ''),
        'received'
    )
    ON CONFLICT (sending_facility, control_id) DO NOTHING
    RETURNING id INTO v_log_id;

    IF v_log_id IS NOT NULL THEN
        RETURN jsonb_build_object('message_log_id', v_log_id, 'duplicate', false);
    END IF;

    -- Kein v_log_id => die Nachricht kam schon einmal an.
    SELECT id INTO v_log_id
      FROM hl7.message_log
     WHERE sending_facility = v_facility AND control_id = v_control_id;

    RETURN jsonb_build_object('message_log_id', v_log_id, 'duplicate', true);
END;
$$;

COMMENT ON FUNCTION hl7.log_message(JSONB) IS
    'Schritt 1: haelt den Eingang fest, Status received. Idempotent ueber (sending_facility, control_id).';

-- ---------------------------------------------------------------------------
-- Schritt 2: fachlich verarbeiten.
-- Schreibt das Patientenereignis und setzt den Status auf processed.
--
-- Muss idempotent sein: scheitert dieser Schritt, wiederholt Mirth ihn aus
-- der Warteschlange - und eine Wiederholung darf kein zweites Ereignis anlegen.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION hl7.complete_message(p_log_id BIGINT, p_event JSONB)
RETURNS JSONB
LANGUAGE plpgsql AS $$
DECLARE
    v_status TEXT;
BEGIN
    -- Zeile sperren, damit zwei gleichzeitige Wiederholungen sich nicht
    -- gegenseitig ueberholen.
    SELECT status INTO v_status
      FROM hl7.message_log
     WHERE id = p_log_id
       FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'message_log_id % existiert nicht', p_log_id;
    END IF;

    IF v_status = 'processed' THEN
        RETURN jsonb_build_object('status', 'processed', 'already_done', true);
    END IF;

    INSERT INTO hl7.patient_event (
        message_log_id, trigger_event, event_occurred_at,
        patient_id, patient_id_authority, last_name, first_name,
        birth_date, gender, visit_number, patient_class,
        assigned_location, attending_physician, admitted_at, discharged_at
    ) VALUES (
        p_log_id,
        p_event ->> 'trigger_event',
        hl7.safe_timestamp(p_event ->> 'event_occurred_at'),
        p_event ->> 'patient_id',
        p_event ->> 'patient_id_authority',
        p_event ->> 'last_name',
        p_event ->> 'first_name',
        hl7.safe_date(p_event ->> 'birth_date'),
        p_event ->> 'gender',
        p_event ->> 'visit_number',
        p_event ->> 'patient_class',
        p_event ->> 'assigned_location',
        p_event ->> 'attending_physician',
        hl7.safe_timestamp(p_event ->> 'admitted_at'),
        hl7.safe_timestamp(p_event ->> 'discharged_at')
    );

    UPDATE hl7.message_log
       SET status = 'processed', processed_at = now()
     WHERE id = p_log_id;

    RETURN jsonb_build_object('status', 'processed', 'already_done', false);
END;
$$;

COMMENT ON FUNCTION hl7.complete_message(BIGINT, JSONB) IS
    'Schritt 2: schreibt das Patientenereignis und setzt processed. Gefahrlos wiederholbar.';

-- ---------------------------------------------------------------------------
-- Fehlerablage.
-- Die Nachricht bleibt im message_log stehen, nur mit Status error. So bleibt
-- die Zahl der eingegangenen Nachrichten vollstaendig und das Monitoring kann
-- "angekommen, aber nicht verarbeitet" von "abgelehnt" unterscheiden.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION hl7.reject_message(
    p_log_id  BIGINT,
    p_reason  TEXT,
    p_details JSONB DEFAULT '{}'::jsonb)
RETURNS JSONB
LANGUAGE plpgsql AS $$
DECLARE
    v_error_id   BIGINT;
    v_control_id TEXT;
    v_raw        TEXT;
BEGIN
    UPDATE hl7.message_log
       SET status = 'error', processed_at = now()
     WHERE id = p_log_id
    RETURNING control_id, raw_message INTO v_control_id, v_raw;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'message_log_id % existiert nicht', p_log_id;
    END IF;

    -- Bei einer Wiederholung soll kein zweiter offener Fehler entstehen.
    SELECT id INTO v_error_id
      FROM hl7.message_error
     WHERE message_log_id = p_log_id AND resolved_at IS NULL
     LIMIT 1;

    IF v_error_id IS NOT NULL THEN
        RETURN jsonb_build_object('status', 'error', 'error_id', v_error_id, 'already_done', true);
    END IF;

    INSERT INTO hl7.message_error (
        message_log_id, control_id, reason, details, raw_message
    ) VALUES (
        p_log_id, v_control_id,
        COALESCE(NULLIF(p_reason, ''), 'UNKNOWN'),
        COALESCE(p_details, '{}'::jsonb),
        v_raw
    )
    RETURNING id INTO v_error_id;

    RETURN jsonb_build_object('status', 'error', 'error_id', v_error_id, 'already_done', false);
END;
$$;

COMMENT ON FUNCTION hl7.reject_message(BIGINT, TEXT, JSONB) IS
    'Legt eine fehlerhafte Nachricht in die Fehlerablage. Gefahrlos wiederholbar.';

-- ---------------------------------------------------------------------------
-- Fehlerbehandlung von Hand.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION hl7.mark_error_retried(p_error_id BIGINT)
RETURNS VOID
LANGUAGE sql AS $$
    UPDATE hl7.message_error
       SET retry_count = retry_count + 1, last_retry_at = now()
     WHERE id = p_error_id;
$$;

CREATE OR REPLACE FUNCTION hl7.resolve_error(
    p_error_id BIGINT, p_by TEXT, p_note TEXT DEFAULT NULL)
RETURNS VOID
LANGUAGE sql AS $$
    UPDATE hl7.message_error
       SET resolved_at = now(), resolved_by = p_by, resolution_note = p_note
     WHERE id = p_error_id AND resolved_at IS NULL;
$$;
