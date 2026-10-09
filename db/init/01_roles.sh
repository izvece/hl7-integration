#!/bin/bash
# Legt die drei Dienst-Benutzer an. Die Passwoerter kommen aus der .env und
# stehen damit nicht im Repository.
#
# Drei getrennte Rollen, weil sie unterschiedlich viel duerfen:
#   mirth       - Eigentuemer der internen Mirth-Datenbank. Keine Rechte auf hl7.
#   hl7_app     - der Kanal. Darf genau vier Funktionen aufrufen, keine Tabelle.
#   hl7_monitor - der Prometheus-Exporter. Darf drei Sichten lesen, sonst nichts.
#
# Die Trennung ist nicht Formalismus: faellt ein Mirth-Kanal einem Angreifer in
# die Haende, kommt er ueber hl7_app an keine Tabelle direkt heran.
set -euo pipefail

: "${MIRTH_DB_PASSWORD:?MIRTH_DB_PASSWORD muss gesetzt sein}"
: "${HL7_APP_PASSWORD:?HL7_APP_PASSWORD muss gesetzt sein}"
: "${HL7_MONITOR_PASSWORD:?HL7_MONITOR_PASSWORD muss gesetzt sein}"

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<EOSQL
DO \$\$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'mirth') THEN
        CREATE ROLE mirth LOGIN PASSWORD '${MIRTH_DB_PASSWORD}';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'hl7_app') THEN
        CREATE ROLE hl7_app LOGIN PASSWORD '${HL7_APP_PASSWORD}';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'hl7_monitor') THEN
        CREATE ROLE hl7_monitor LOGIN PASSWORD '${HL7_MONITOR_PASSWORD}';
    END IF;
END
\$\$;

COMMENT ON ROLE mirth       IS 'Mirth Connect - interner Zustand, keine klinischen Daten';
COMMENT ON ROLE hl7_app     IS 'Mirth Connect - Verarbeitung der ADT-Nachrichten';
COMMENT ON ROLE hl7_monitor IS 'Prometheus Exporter - nur lesend, keine Patientendaten';
EOSQL
