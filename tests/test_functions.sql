-- ---------------------------------------------------------------------------
-- Tests der Verarbeitungslogik.
--
-- Laeuft mit reinem psql, ohne Test-Bibliothek - damit die Pipeline nichts
-- installieren muss und der Test auch auf einem fremden Rechner laeuft:
--     psql -v ON_ERROR_STOP=1 -f tests/test_functions.sql
--
-- Alles steckt in einer Transaktion mit ROLLBACK am Ende. Der Test laesst
-- sich damit auch gegen eine Entwicklungsdatenbank mit Daten fahren, ohne
-- etwas zu hinterlassen.
-- ---------------------------------------------------------------------------

\set ON_ERROR_STOP on
BEGIN;

-- Eine Zusicherung, die bei Verletzung die Transaktion abbricht und damit
-- psql mit Exit-Code 3 beendet. Genau darauf prueft die Pipeline.
CREATE FUNCTION pg_temp.pruefe(bedingung BOOLEAN, beschreibung TEXT)
RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
    IF bedingung IS NOT TRUE THEN
        RAISE EXCEPTION 'FEHLGESCHLAGEN: %', beschreibung;
    END IF;
    RAISE NOTICE 'ok: %', beschreibung;
END;
$$;

-- ===========================================================================
-- 1. Eingang festhalten
-- ===========================================================================
DO $$
DECLARE
    ergebnis JSONB;
    log_id   BIGINT;
BEGIN
    ergebnis := hl7.log_message(jsonb_build_object(
        'control_id', 'TEST-0001',
        'sending_facility', 'TESTHAUS',
        'message_type', 'ADT',
        'trigger_event', 'A01',
        'message_version', '2.5',
        'raw_message', 'MSH|^~\&|KIS|TESTHAUS|...'
    ));

    log_id := (ergebnis ->> 'message_log_id')::BIGINT;

    PERFORM pg_temp.pruefe(log_id IS NOT NULL,
        'log_message gibt eine message_log_id zurueck');
    PERFORM pg_temp.pruefe((ergebnis ->> 'duplicate')::BOOLEAN IS FALSE,
        'die erste Zustellung ist keine Dublette');
    PERFORM pg_temp.pruefe(
        (SELECT status FROM hl7.message_log WHERE id = log_id) = 'received',
        'nach Schritt 1 steht der Status auf received');
    PERFORM pg_temp.pruefe(
        (SELECT processed_at FROM hl7.message_log WHERE id = log_id) IS NULL,
        'processed_at ist nach Schritt 1 noch leer');
END;
$$;

-- ===========================================================================
-- 2. Dublettenerkennung
--    Ein Quellsystem, das keine Quittung bekommt, sendet erneut. Das darf
--    keine zweite Zeile und erst recht kein zweites Patientenereignis geben.
-- ===========================================================================
DO $$
DECLARE
    erste   JSONB;
    zweite  JSONB;
    nutzlast JSONB := jsonb_build_object(
        'control_id', 'TEST-0002',
        'sending_facility', 'TESTHAUS',
        'message_type', 'ADT',
        'trigger_event', 'A08',
        'raw_message', 'MSH|...'
    );
BEGIN
    erste  := hl7.log_message(nutzlast);
    zweite := hl7.log_message(nutzlast);

    PERFORM pg_temp.pruefe((zweite ->> 'duplicate')::BOOLEAN IS TRUE,
        'die zweite Zustellung wird als Dublette erkannt');
    PERFORM pg_temp.pruefe(
        (erste ->> 'message_log_id') = (zweite ->> 'message_log_id'),
        'die Dublette verweist auf dieselbe Zeile');
    PERFORM pg_temp.pruefe(
        (SELECT count(*) FROM hl7.message_log
          WHERE control_id = 'TEST-0002' AND sending_facility = 'TESTHAUS') = 1,
        'es entsteht nur eine Zeile');
END;
$$;

-- ===========================================================================
-- 3. Fachliche Verarbeitung
-- ===========================================================================
DO $$
DECLARE
    log_id    BIGINT;
    ergebnis  JSONB;
    ereignis  hl7.patient_event;
BEGIN
    log_id := (hl7.log_message(jsonb_build_object(
        'control_id', 'TEST-0003', 'sending_facility', 'TESTHAUS',
        'message_type', 'ADT', 'trigger_event', 'A01',
        'raw_message', 'MSH|...'
    )) ->> 'message_log_id')::BIGINT;

    ergebnis := hl7.complete_message(log_id, jsonb_build_object(
        'trigger_event', 'A01',
        'event_occurred_at', '2026-10-09 08:15:00',
        'patient_id', '10001234',
        'patient_id_authority', 'KH_MITTE',
        'last_name', 'Mustermann',
        'first_name', 'Erika',
        'birth_date', '1985-03-12',
        'gender', 'F',
        'visit_number', 'V12345',
        'patient_class', 'I',
        'assigned_location', 'CHIR^201^01',
        'attending_physician', 'Schmidt, Anna (12345)',
        'admitted_at', '2026-10-09 08:15:00'
    ));

    PERFORM pg_temp.pruefe(ergebnis ->> 'status' = 'processed',
        'complete_message meldet processed');
    PERFORM pg_temp.pruefe(
        (SELECT status FROM hl7.message_log WHERE id = log_id) = 'processed',
        'der Status im message_log steht auf processed');
    PERFORM pg_temp.pruefe(
        (SELECT processed_at FROM hl7.message_log WHERE id = log_id) IS NOT NULL,
        'processed_at ist gesetzt');

    SELECT * INTO ereignis FROM hl7.patient_event WHERE message_log_id = log_id;

    PERFORM pg_temp.pruefe(ereignis.patient_id = '10001234',
        'die Patientennummer ist uebernommen');
    PERFORM pg_temp.pruefe(ereignis.birth_date = DATE '1985-03-12',
        'das Geburtsdatum ist als Datum gespeichert');
    PERFORM pg_temp.pruefe(ereignis.visit_number = 'V12345',
        'die Fallnummer ist uebernommen');
END;
$$;

-- ===========================================================================
-- 4. Wiederholbarkeit
--    Mirth wiederholt ein gescheitertes Ziel aus der Warteschlange. Der
--    zweite Lauf darf kein zweites Ereignis anlegen - sonst steht ein
--    Patient nach einem Netzwerkhuepfer zweimal aufgenommen in der Akte.
-- ===========================================================================
DO $$
DECLARE
    log_id   BIGINT;
    ergebnis JSONB;
BEGIN
    log_id := (hl7.log_message(jsonb_build_object(
        'control_id', 'TEST-0004', 'sending_facility', 'TESTHAUS',
        'trigger_event', 'A01', 'raw_message', 'MSH|...'
    )) ->> 'message_log_id')::BIGINT;

    PERFORM hl7.complete_message(log_id,
        jsonb_build_object('trigger_event', 'A01', 'patient_id', '10004444'));
    ergebnis := hl7.complete_message(log_id,
        jsonb_build_object('trigger_event', 'A01', 'patient_id', '10004444'));

    PERFORM pg_temp.pruefe((ergebnis ->> 'already_done')::BOOLEAN IS TRUE,
        'der zweite Aufruf meldet already_done');
    PERFORM pg_temp.pruefe(
        (SELECT count(*) FROM hl7.patient_event WHERE message_log_id = log_id) = 1,
        'es entsteht nur ein Patientenereignis');
END;
$$;

-- ===========================================================================
-- 5. Fehlerablage
-- ===========================================================================
DO $$
DECLARE
    log_id    BIGINT;
    ergebnis  JSONB;
    fehler    hl7.message_error;
BEGIN
    log_id := (hl7.log_message(jsonb_build_object(
        'control_id', 'TEST-0005', 'sending_facility', 'TESTHAUS',
        'trigger_event', 'A01', 'raw_message', 'MSH|kaputt'
    )) ->> 'message_log_id')::BIGINT;

    ergebnis := hl7.reject_message(log_id, 'MISSING_PATIENT_ID',
        '{"problems": [{"code": "MISSING_PATIENT_ID", "detail": "PID-3.1 ist leer"}]}'::jsonb);

    PERFORM pg_temp.pruefe(ergebnis ->> 'status' = 'error',
        'reject_message meldet error');
    PERFORM pg_temp.pruefe(
        (SELECT status FROM hl7.message_log WHERE id = log_id) = 'error',
        'die Nachricht bleibt im message_log, mit Status error');

    SELECT * INTO fehler FROM hl7.message_error WHERE message_log_id = log_id;

    PERFORM pg_temp.pruefe(fehler.reason = 'MISSING_PATIENT_ID',
        'der Fehlergrund ist festgehalten');
    PERFORM pg_temp.pruefe(fehler.raw_message = 'MSH|kaputt',
        'die Rohnachricht liegt in der Fehlerablage - ohne sie kann man den Fehler nicht nachstellen');
    PERFORM pg_temp.pruefe(fehler.details -> 'problems' IS NOT NULL,
        'alle Einzelprobleme stehen in den Details');
    PERFORM pg_temp.pruefe(fehler.resolved_at IS NULL,
        'der Fehler ist zunaechst offen');

    -- Wiederholung darf keinen zweiten offenen Fehler erzeugen.
    ergebnis := hl7.reject_message(log_id, 'MISSING_PATIENT_ID', '{}'::jsonb);
    PERFORM pg_temp.pruefe((ergebnis ->> 'already_done')::BOOLEAN IS TRUE,
        'eine Wiederholung legt keinen zweiten Fehler an');
    PERFORM pg_temp.pruefe(
        (SELECT count(*) FROM hl7.message_error WHERE message_log_id = log_id) = 1,
        'es bleibt bei einem Fehlereintrag');
END;
$$;

-- ===========================================================================
-- 6. Fehlerlebenszyklus
-- ===========================================================================
DO $$
DECLARE
    log_id   BIGINT;
    fehler_id BIGINT;
BEGIN
    log_id := (hl7.log_message(jsonb_build_object(
        'control_id', 'TEST-0006', 'sending_facility', 'TESTHAUS',
        'raw_message', 'MSH|...'
    )) ->> 'message_log_id')::BIGINT;

    fehler_id := (hl7.reject_message(log_id, 'INVALID_BIRTH_DATE') ->> 'error_id')::BIGINT;

    PERFORM hl7.mark_error_retried(fehler_id);
    PERFORM pg_temp.pruefe(
        (SELECT retry_count FROM hl7.message_error WHERE id = fehler_id) = 1,
        'ein erneuter Versuch wird gezaehlt');

    PERFORM hl7.resolve_error(fehler_id, 'izem', 'Sender hat das Format korrigiert');
    PERFORM pg_temp.pruefe(
        (SELECT resolved_at FROM hl7.message_error WHERE id = fehler_id) IS NOT NULL,
        'ein geklaerter Fehler ist als geklaert markiert');
    PERFORM pg_temp.pruefe(
        NOT EXISTS (SELECT 1 FROM hl7.v_error_inbox WHERE id = fehler_id),
        'ein geklaerter Fehler verschwindet aus der Fehlerablage-Ansicht');
END;
$$;

-- ===========================================================================
-- 7. Fehlertolerante Umwandlung
--    Eine unlesbare Angabe darf die Transaktion nicht sprengen, sondern muss
--    zu NULL werden. Sonst reisst eine einzige kaputte Nachricht die ganze
--    Verarbeitung mit.
-- ===========================================================================
DO $$
BEGIN
    PERFORM pg_temp.pruefe(hl7.safe_date('kein datum') IS NULL,
        'safe_date gibt bei Unsinn NULL zurueck');
    PERFORM pg_temp.pruefe(hl7.safe_date('') IS NULL,
        'safe_date gibt bei leerem Text NULL zurueck');
    PERFORM pg_temp.pruefe(hl7.safe_date(NULL) IS NULL,
        'safe_date gibt bei NULL NULL zurueck');
    PERFORM pg_temp.pruefe(hl7.safe_date('1985-03-12') = DATE '1985-03-12',
        'safe_date liest ein gueltiges Datum');
    PERFORM pg_temp.pruefe(hl7.safe_timestamp('2026-02-30 10:00:00') IS NULL,
        'safe_timestamp gibt beim 30. Februar NULL zurueck');
    PERFORM pg_temp.pruefe(hl7.safe_timestamp('2026-10-09 08:15:00') IS NOT NULL,
        'safe_timestamp liest einen gueltigen Zeitstempel');
END;
$$;

-- ===========================================================================
-- 8. Die Monitoring-Sicht
--    Das Wichtigste: eine haengende Nachricht MUSS sichtbar werden.
-- ===========================================================================
DO $$
DECLARE
    log_id  BIGINT;
    alter_s FLOAT8;
    stau    FLOAT8;
BEGIN
    log_id := (hl7.log_message(jsonb_build_object(
        'control_id', 'TEST-0008', 'sending_facility', 'TESTHAUS',
        'raw_message', 'MSH|...'
    )) ->> 'message_log_id')::BIGINT;

    -- Eine Nachricht, die vor zwei Stunden ankam und nie verarbeitet wurde.
    UPDATE hl7.message_log
       SET received_at = now() - INTERVAL '2 hours'
     WHERE id = log_id;

    SELECT oldest_unprocessed_seconds, backlog
      INTO alter_s, stau
      FROM hl7.v_pipeline;

    PERFORM pg_temp.pruefe(alter_s > 7000,
        'v_pipeline meldet das Alter der haengenden Nachricht (ca. 7200s)');
    PERFORM pg_temp.pruefe(stau >= 1,
        'v_pipeline zaehlt die haengende Nachricht zum Rueckstau');

    -- Und nach der Verarbeitung muss das Signal verschwinden.
    PERFORM hl7.complete_message(log_id,
        jsonb_build_object('trigger_event', 'A01', 'patient_id', '10008888'));

    SELECT oldest_unprocessed_seconds INTO alter_s FROM hl7.v_pipeline;
    PERFORM pg_temp.pruefe(alter_s = 0,
        'nach der Verarbeitung meldet v_pipeline wieder 0');
END;
$$;

-- ===========================================================================
-- 9. Statuszaehlung fuer Prometheus
-- ===========================================================================
DO $$
DECLARE
    anzahl_fehler FLOAT8;
BEGIN
    SELECT total INTO anzahl_fehler
      FROM hl7.v_status_counts WHERE status = 'error';

    PERFORM pg_temp.pruefe(anzahl_fehler >= 2,
        'v_status_counts zaehlt die abgelehnten Nachrichten');
    PERFORM pg_temp.pruefe(
        (SELECT count(*) FROM hl7.v_error_reasons WHERE reason = 'MISSING_PATIENT_ID') = 1,
        'v_error_reasons gruppiert nach Fehlergrund');
END;
$$;

-- ===========================================================================
-- 10. Rechte
--     Der Exporter darf keine Patientendaten sehen koennen. Das ist eine
--     Zusicherung, die man testen muss und nicht hoffen darf.
-- ===========================================================================
DO $$
DECLARE
    darf BOOLEAN;
BEGIN
    SELECT has_table_privilege('hl7_monitor', 'hl7.message_log', 'SELECT') INTO darf;
    PERFORM pg_temp.pruefe(darf IS FALSE,
        'hl7_monitor darf message_log NICHT lesen (dort steht die Rohnachricht)');

    SELECT has_table_privilege('hl7_monitor', 'hl7.patient_event', 'SELECT') INTO darf;
    PERFORM pg_temp.pruefe(darf IS FALSE,
        'hl7_monitor darf patient_event NICHT lesen');

    SELECT has_table_privilege('hl7_monitor', 'hl7.v_pipeline', 'SELECT') INTO darf;
    PERFORM pg_temp.pruefe(darf IS TRUE,
        'hl7_monitor darf die Kennzahlen-Sicht lesen');

    SELECT has_table_privilege('hl7_app', 'hl7.message_log', 'INSERT') INTO darf;
    PERFORM pg_temp.pruefe(darf IS FALSE,
        'hl7_app darf nicht direkt in message_log schreiben, nur ueber die Funktionen');

    SELECT has_function_privilege('hl7_app', 'hl7.log_message(jsonb)', 'EXECUTE') INTO darf;
    PERFORM pg_temp.pruefe(darf IS TRUE,
        'hl7_app darf log_message aufrufen');
END;
$$;

ROLLBACK;

\echo ''
\echo 'Alle Tests bestanden.'
