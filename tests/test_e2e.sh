#!/usr/bin/env bash
#
# End-to-End-Test: schickt die Beispielnachrichten durch den laufenden Kanal
# und prueft danach, was in der Datenbank und in der Fehlerablage steht.
#
# Setzt voraus, dass der Stapel laeuft und der Kanal ausgerollt ist:
#     make up && make deploy && make test-e2e
set -euo pipefail

cd "$(dirname "$0")/.."

MLLP_HOST="${MLLP_HOST:-localhost}"
MLLP_PORT="${MLLP_PORT:-6661}"
COMPOSE="${COMPOSE:-docker compose}"
# Die Pipeline setzt hier die Spiegelung in der GitHub Container Registry,
# weil public.ecr.aws auf den Runnern ebenfalls mit toomanyrequests abbricht.
PYTHON_IMAGE="${PYTHON_IMAGE:-public.ecr.aws/docker/library/python:3.12-alpine}"

fehlgeschlagen=0

pruefe() {
    local beschreibung="$1" erwartet="$2" tatsaechlich="$3"
    if [ "$erwartet" = "$tatsaechlich" ]; then
        printf '  ok      %s\n' "$beschreibung"
    else
        printf '  FEHLER  %s\n          erwartet: %s, tatsaechlich: %s\n' \
               "$beschreibung" "$erwartet" "$tatsaechlich"
        fehlgeschlagen=$((fehlgeschlagen + 1))
    fi
}

sql() {
    $COMPOSE exec -T postgres \
        psql -U "${POSTGRES_USER:-postgres}" -d "${POSTGRES_DB:-hl7}" \
             -tAc "$1" | tr -d '[:space:]'
}

# ---------------------------------------------------------------------------
echo "==> Datenbank leeren, damit die Zaehlungen eindeutig sind"
# ---------------------------------------------------------------------------
# TRUNCATE ... CASCADE raeumt patient_event und message_error mit ab.
$COMPOSE exec -T postgres \
    psql -U "${POSTGRES_USER:-postgres}" -d "${POSTGRES_DB:-hl7}" \
         -q -c "TRUNCATE hl7.message_log CASCADE;" > /dev/null
rm -f data/error-store/*.hl7 2>/dev/null || true

# ---------------------------------------------------------------------------
echo "==> Nachrichten senden"
# ---------------------------------------------------------------------------
# Der MLLP-Client laeuft in einem Container, damit lokal kein Python noetig
# ist. --network host, damit localhost:6661 erreichbar bleibt.
docker run --rm --network host \
    -v "$PWD/tests:/tests:ro" -w /tests \
    "$PYTHON_IMAGE" python send_hl7.py \
        --host "$MLLP_HOST" --port "$MLLP_PORT" \
        samples/01_gueltig_a01_aufnahme.hl7 \
        samples/02_gueltig_a08_aktualisierung.hl7 \
        samples/03_gueltig_a03_entlassung.hl7 \
        samples/10_fehler_ohne_pid.hl7 \
        samples/11_fehler_ohne_patientennummer.hl7 \
        samples/12_fehler_geburtsdatum.hl7 \
        samples/13_fehler_ereignis_a40.hl7 \
        samples/14_fehler_ohne_fallnummer.hl7

# Die Ziele arbeiten asynchron. Statt blind zu warten: pollen, bis sich
# nichts mehr bewegt oder die Frist ablaeuft.
echo "==> Auf das Ende der Verarbeitung warten"
frist=$(( $(date +%s) + 60 ))
while [ "$(date +%s)" -lt "$frist" ]; do
    offen=$(sql "SELECT count(*) FROM hl7.message_log WHERE status = 'received';")
    gesamt=$(sql "SELECT count(*) FROM hl7.message_log;")
    if [ "$offen" = "0" ] && [ "$gesamt" = "8" ]; then
        break
    fi
    sleep 2
done

# ---------------------------------------------------------------------------
echo
echo "==> Eingang"
# ---------------------------------------------------------------------------
pruefe "alle 8 Nachrichten sind im message_log" \
       "8" "$(sql 'SELECT count(*) FROM hl7.message_log;')"
pruefe "keine Nachricht haengt mehr" \
       "0" "$(sql "SELECT count(*) FROM hl7.message_log WHERE status = 'received';")"

# ---------------------------------------------------------------------------
echo
echo "==> Gueltige Nachrichten"
# ---------------------------------------------------------------------------
pruefe "3 Nachrichten sind verarbeitet" \
       "3" "$(sql "SELECT count(*) FROM hl7.message_log WHERE status = 'processed';")"
pruefe "3 Patientenereignisse geschrieben" \
       "3" "$(sql 'SELECT count(*) FROM hl7.patient_event;')"
pruefe "die Aufnahme ist korrekt zerlegt" \
       "Mustermann|Erika|1985-03-12|V12345" \
       "$(sql "SELECT last_name||'|'||first_name||'|'||birth_date||'|'||visit_number
                 FROM hl7.patient_event WHERE trigger_event = 'A01';")"
pruefe "die Entlassung hat einen Entlasszeitpunkt" \
       "t" "$(sql "SELECT discharged_at IS NOT NULL FROM hl7.patient_event
                    WHERE trigger_event = 'A03';")"
pruefe "der behandelnde Arzt ist lesbar zusammengesetzt" \
       "Schmidt,Anna(12345)" \
       "$(sql "SELECT attending_physician FROM hl7.patient_event
                WHERE trigger_event = 'A01';")"

# ---------------------------------------------------------------------------
echo
echo "==> Fehlerhafte Nachrichten"
# ---------------------------------------------------------------------------
pruefe "5 Nachrichten sind abgelehnt" \
       "5" "$(sql "SELECT count(*) FROM hl7.message_log WHERE status = 'error';")"
pruefe "5 Eintraege in der Fehlerablage" \
       "5" "$(sql 'SELECT count(*) FROM hl7.message_error;')"
pruefe "jeder Fehler hat die Rohnachricht dabei" \
       "0" "$(sql "SELECT count(*) FROM hl7.message_error
                    WHERE raw_message IS NULL OR raw_message = '';")"

# Die Gruende muessen stimmen - nicht nur die Anzahl. Sonst merkt niemand,
# wenn jede kaputte Nachricht pauschal als UNKNOWN abgelegt wird.
echo "  Fehlergruende:"
$COMPOSE exec -T postgres psql -U "${POSTGRES_USER:-postgres}" -d "${POSTGRES_DB:-hl7}" \
    -c "SELECT reason, count(*) FROM hl7.message_error GROUP BY reason ORDER BY reason;"

for grund in MISSING_SEGMENT MISSING_PATIENT_ID INVALID_BIRTH_DATE \
             UNSUPPORTED_TRIGGER_EVENT MISSING_VISIT_NUMBER; do
    pruefe "Grund $grund ist vertreten" \
           "1" "$(sql "SELECT count(*) FROM hl7.message_error WHERE reason = '$grund';")"
done

# ---------------------------------------------------------------------------
echo
echo "==> Fehlerablage als Datei"
# ---------------------------------------------------------------------------
# Die doppelte Ablage ist Absicht: haette die Datenbank ein Problem, waere
# eine Fehlerablage in genau dieser Datenbank nichts wert.
pruefe "5 Dateien in der Fehlerablage" \
       "5" "$(find data/error-store -name '*.hl7' -type f 2>/dev/null | wc -l | tr -d '[:space:]')"
pruefe "die Dateien enthalten die Rohnachricht" \
       "5" "$(grep -l '^MSH' data/error-store/*.hl7 2>/dev/null | wc -l | tr -d '[:space:]')"

# ---------------------------------------------------------------------------
echo
echo "==> Dublettenerkennung"
# ---------------------------------------------------------------------------
docker run --rm --network host \
    -v "$PWD/tests:/tests:ro" -w /tests \
    "$PYTHON_IMAGE" python send_hl7.py \
        --host "$MLLP_HOST" --port "$MLLP_PORT" \
        samples/01_gueltig_a01_aufnahme.hl7 > /dev/null
sleep 5

pruefe "die wiederholte Nachricht erzeugt keine zweite Zeile" \
       "8" "$(sql 'SELECT count(*) FROM hl7.message_log;')"
pruefe "die wiederholte Nachricht erzeugt kein zweites Ereignis" \
       "3" "$(sql 'SELECT count(*) FROM hl7.patient_event;')"

# ---------------------------------------------------------------------------
echo
echo "==> Monitoring-Kennzahlen"
# ---------------------------------------------------------------------------
pruefe "v_pipeline meldet keinen Rueckstau" \
       "0" "$(sql 'SELECT backlog::int FROM hl7.v_pipeline;')"
pruefe "v_pipeline meldet 0 fuer haengende Nachrichten" \
       "0" "$(sql 'SELECT oldest_unprocessed_seconds::int FROM hl7.v_pipeline;')"
# Abgefragt aus einem Container, der schon laeuft und wget mitbringt. Ein
# eigener curl-Container waere ein zusaetzlicher Image-Pull, und genau die
# sind in der Pipeline knapp (Docker Hub begrenzt unauthentifizierte Pulls).
pruefe "der Exporter liefert die eigene Kennzahl aus" \
       "1" "$($COMPOSE exec -T blackbox-exporter \
                wget -qO- http://postgres-exporter:9187/metrics 2>/dev/null \
                | grep -c '^hl7_pipeline_oldest_unprocessed_seconds' || echo 0)"

# ---------------------------------------------------------------------------
echo
if [ "$fehlgeschlagen" -eq 0 ]; then
    echo "Alle End-to-End-Pruefungen bestanden."
else
    echo "$fehlgeschlagen Pruefung(en) fehlgeschlagen."
    exit 1
fi
