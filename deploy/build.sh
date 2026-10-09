#!/usr/bin/env bash
#
# Baut aus der Kanal-Vorlage und den .js-Dateien die fertige Mirth-Kanal-XML.
#
# Warum ueberhaupt ein Build-Schritt: Mirth speichert einen Kanal als eine
# XML-Datei, in der das gesamte JavaScript als escapter Text steht. Direkt
# versioniert waere jede Aenderung ein unlesbarer Einzeiler-Diff. Deshalb liegt
# die Logik in src/*.js und wird hier eingesetzt.
set -euo pipefail

CHANNEL_DIR="${1:-mirth/channels/adt-inbound}"
BUILD_DIR="${BUILD_DIR:-build}"
TEMPLATE="$CHANNEL_DIR/channel.xml"
SRC_DIR="$CHANNEL_DIR/src"
NAME="$(basename "$CHANNEL_DIR")"
OUT="$BUILD_DIR/$NAME.xml"

[ -f "$TEMPLATE" ] || { echo "FEHLER: $TEMPLATE nicht gefunden" >&2; exit 1; }

mkdir -p "$BUILD_DIR"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --------------------------------------------------------------------------
# JavaScript XML-sicher machen. Die Reihenfolge ist zwingend: erst das
# kaufmaennische Und, sonst werden die gerade erzeugten Entities nochmal
# escapt. Unser Code enthaelt alle drei Zeichen - "^~\&" im MSH-Aufbau,
# "length() > 0" in den Pruefungen.
# --------------------------------------------------------------------------
escape_xml() {
    sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' "$1"
}

for js in "$SRC_DIR"/*.js; do
    [ -e "$js" ] || continue
    escape_xml "$js" > "$WORK/$(basename "$js")"
done

# --------------------------------------------------------------------------
# Die HL7-v2-Datentyp-Bloecke. Mirth braucht sie an jedem Transformer und
# jedem Response-Transformer - in dieser Kanal-Vorlage zwoelfmal. Einmal hier
# definiert statt zwoelfmal in der XML wiederholt.
#
# Die wichtigste Einstellung ist useStrictParser=false: der nachsichtige
# Parser nimmt auch Nachrichten an, die nicht exakt der Norm entsprechen.
# Genau die wollen wir sehen und in die Fehlerablage schicken - ein strenger
# Parser wuerde sie vorher mit einer Exception abweisen, und dann steht nichts
# Verwertbares in der Fehlerablage.
# --------------------------------------------------------------------------
datatype_block() {
    local element="$1"
    cat <<BLOCK
<$element class="com.mirth.connect.plugins.datatypes.hl7v2.HL7v2DataTypeProperties" version="4.5.2">
        <serializationProperties class="com.mirth.connect.plugins.datatypes.hl7v2.HL7v2SerializationProperties">
          <handleRepetitions>true</handleRepetitions>
          <handleSubcomponents>true</handleSubcomponents>
          <useStrictParser>false</useStrictParser>
          <useStrictValidation>false</useStrictValidation>
          <stripNamespaces>false</stripNamespaces>
          <segmentDelimiter>\\r</segmentDelimiter>
          <convertLineBreaks>true</convertLineBreaks>
        </serializationProperties>
        <deserializationProperties class="com.mirth.connect.plugins.datatypes.hl7v2.HL7v2DeserializationProperties">
          <useStrictParser>false</useStrictParser>
          <useStrictValidation>false</useStrictValidation>
          <segmentDelimiter>\\r</segmentDelimiter>
        </deserializationProperties>
        <batchProperties class="com.mirth.connect.plugins.datatypes.hl7v2.HL7v2BatchProperties">
          <splitType>MSH_Segment</splitType>
          <batchScript></batchScript>
        </batchProperties>
        <responseGenerationProperties class="com.mirth.connect.plugins.datatypes.hl7v2.HL7v2ResponseGenerationProperties">
          <segmentDelimiter>\\r</segmentDelimiter>
          <successfulACKCode>AA</successfulACKCode>
          <successfulACKMessage></successfulACKMessage>
          <errorACKCode>AE</errorACKCode>
          <errorACKMessage>Fehler bei der Verarbeitung der Nachricht.</errorACKMessage>
          <rejectedACKCode>AR</rejectedACKCode>
          <rejectedACKMessage>Nachricht abgewiesen.</rejectedACKMessage>
          <msh15ACKAccept>false</msh15ACKAccept>
          <dateFormat>yyyyMMddHHmmss.SSS</dateFormat>
        </responseGenerationProperties>
        <responseValidationProperties class="com.mirth.connect.plugins.datatypes.hl7v2.HL7v2ResponseValidationProperties">
          <successfulACKCode>AA,CA</successfulACKCode>
          <errorACKCode>AE,CE</errorACKCode>
          <rejectedACKCode>AR,CR</rejectedACKCode>
          <validateMessageControlId>true</validateMessageControlId>
          <originalMessageControlId>Destination_Encoded</originalMessageControlId>
          <originalIdMapVariable></originalIdMapVariable>
        </responseValidationProperties>
      </$element>
BLOCK
}

datatype_block inboundProperties  > "$WORK/datatype_inbound"
datatype_block outboundProperties > "$WORK/datatype_outbound"

# --------------------------------------------------------------------------
# Platzhalter ersetzen. awk statt sed, weil der eingesetzte Inhalt mehrzeilig
# ist und beliebige Sonderzeichen enthaelt - sed wuerde daran scheitern.
# --------------------------------------------------------------------------
awk -v work="$WORK" '
{
    line = $0
    out = ""
    while (match(line, /@@(SCRIPT|BLOCK):[^@]+@@/)) {
        token = substr(line, RSTART + 2, RLENGTH - 4)   # ohne die @@
        split(token, parts, ":")
        path = work "/" parts[2]

        out = out substr(line, 1, RSTART - 1)
        while ((getline chunk < path) > 0) {
            out = out chunk "\n"
        }
        close(path)
        # Den eingefuegten letzten Zeilenumbruch wieder entfernen, damit der
        # schliessende Tag direkt anschliesst.
        sub(/\n$/, "", out)

        line = substr(line, RSTART + RLENGTH)
    }
    print out line
}
' "$TEMPLATE" > "$OUT"

# --------------------------------------------------------------------------
# Kontrolle: unersetzte Platzhalter und XML-Wohlgeformtheit
# --------------------------------------------------------------------------
if grep -q '@@' "$OUT"; then
    echo "FEHLER: unersetzte Platzhalter in $OUT:" >&2
    grep -n '@@' "$OUT" >&2
    exit 1
fi

if command -v xmllint >/dev/null 2>&1; then
    xmllint --noout "$OUT" || { echo "FEHLER: $OUT ist kein gueltiges XML" >&2; exit 1; }
    echo "XML geprueft: wohlgeformt"
else
    echo "Hinweis: xmllint nicht vorhanden, XML-Pruefung uebersprungen"
fi

echo "gebaut: $OUT ($(wc -l < "$OUT" | tr -d ' ') Zeilen)"
