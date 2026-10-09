#!/usr/bin/env bash
#
# Rollt den Kanal auf einen laufenden Mirth-Server aus.
#
# Ablauf:
#   1. warten, bis die REST-API antwortet
#   2. Configuration Map setzen (Datenbank-Zugang, Pfad der Fehlerablage)
#   3. Kanal importieren bzw. ueberschreiben
#   4. Kanal ausrollen und starten
#   5. nachsehen, ob er wirklich laeuft
#
# Die Zugangsdaten landen in Mirths Configuration Map und NICHT in der
# Kanal-XML. Dadurch bleibt die XML frei von Geheimnissen und dieselbe Datei
# laeuft gegen Test und Betrieb.
set -euo pipefail

MIRTH_URL="${MIRTH_URL:-https://localhost:8443}"
MIRTH_USER="${MIRTH_ADMIN_USER:-admin}"
MIRTH_PASS="${MIRTH_ADMIN_PASSWORD:-admin}"
CHANNEL_FILE="${CHANNEL_FILE:-build/adt-inbound.xml}"
CHANNEL_ID="${CHANNEL_ID:-3a9f1c7e-2b4d-4e58-9a61-7c0d5e8f1b23}"
WAIT_SECONDS="${WAIT_SECONDS:-180}"

# Was der Kanal zur Laufzeit braucht.
DB_URL="${DB_URL:-jdbc:postgresql://postgres:5432/hl7}"
DB_USER="${DB_USER:-hl7_app}"
DB_PASSWORD="${HL7_APP_PASSWORD:?HL7_APP_PASSWORD muss gesetzt sein}"
ERROR_STORE_PATH="${ERROR_STORE_PATH:-/data/error-store}"

# -k, weil Mirth ein selbst signiertes Zertifikat mitbringt. Fuer echten
# Betrieb hier das eigene CA-Zertifikat mit --cacert angeben.
# Der Header X-Requested-With ist Pflicht: ohne ihn weist Mirth die Anfrage
# als moeglichen CSRF-Versuch ab.
CURL=(curl --silent --show-error --insecure
      --user "${MIRTH_USER}:${MIRTH_PASS}"
      --header "X-Requested-With: hl7-deploy")

schritt() { printf '\n==> %s\n' "$1"; }
fehler()  { printf 'FEHLER: %s\n' "$1" >&2; exit 1; }

# Mirth antwortet auf einen Fehler mit einer XML-Exception samt vollstaendigem
# Java-Stacktrace - achtzig Zeilen Jetty-Innenleben, in denen die eigentliche
# Meldung untergeht. Hier bleibt nur die Meldung uebrig.
meldung() {
    local rumpf="$1"
    local kurz
    kurz=$(printf '%s' "$rumpf" |
           xmllint --xpath 'string(//detailMessage)' - 2>/dev/null || true)
    if [ -n "$kurz" ]; then
        printf '%s' "$kurz"
    else
        printf '%s' "$rumpf" | head -5
    fi
}

[ -f "$CHANNEL_FILE" ] || fehler "$CHANNEL_FILE fehlt. Zuerst deploy/build.sh ausfuehren."

# ---------------------------------------------------------------------------
schritt "Warte auf die Mirth-REST-API ($MIRTH_URL)"
# ---------------------------------------------------------------------------
frist=$(( $(date +%s) + WAIT_SECONDS ))
version=""
http_code=""
while [ "$(date +%s)" -lt "$frist" ]; do
    antwort=$("${CURL[@]}" --max-time 5 --write-out '\n%{http_code}' \
              --header "Accept: text/plain" \
              "${MIRTH_URL}/api/server/version" 2>/dev/null || true)
    http_code=$(printf '%s' "$antwort" | tail -1)

    if [ "$http_code" = "401" ] || [ "$http_code" = "403" ]; then
        # Ein falsches Passwort sieht sonst aus wie ein nicht erreichbarer
        # Server, und man sucht an der falschen Stelle.
        fehler "Mirth lehnt die Anmeldung ab (HTTP $http_code) als Benutzer \"$MIRTH_USER\".
       Mirth startet mit admin/admin und verlangt beim ersten Login in der
       Weboberflaeche eine Passwortaenderung. Entweder MIRTH_ADMIN_PASSWORD
       in der .env auf das neue Passwort setzen, oder sich erstmals unter
       ${MIRTH_URL} anmelden."
    fi

    version=$(printf '%s' "$antwort" | sed '$d')
    if [ -n "$version" ] && [ "${http_code:0:1}" = "2" ]; then
        echo "Mirth $version ist bereit."
        break
    fi
    version=""
    printf '.'
    sleep 3
done
[ -n "$version" ] || fehler "Mirth antwortet nach ${WAIT_SECONDS}s nicht. 'docker compose logs mirth' ansehen."

# ---------------------------------------------------------------------------
schritt "Configuration Map setzen"
# ---------------------------------------------------------------------------
# Mirth erwartet hier seine eigene XML-Form. Die Kommentare erscheinen in der
# Weboberflaeche und erklaeren dem naechsten Menschen, was der Wert tut.
eintrag() {
    cat <<ENTRY
  <entry>
    <string>$1</string>
    <com.mirth.connect.util.ConfigurationProperty>
      <value>$2</value>
      <comment>$3</comment>
    </com.mirth.connect.util.ConfigurationProperty>
  </entry>
ENTRY
}

configmap="$(mktemp)"
{
  echo '<map>'
  eintrag "dbDriver"       "org.postgresql.Driver" "JDBC-Treiber der Zieldatenbank"
  eintrag "dbUrl"          "$DB_URL"               "Zieldatenbank fuer die ADT-Daten"
  eintrag "dbUser"         "$DB_USER"              "Darf nur die hl7-Funktionen aufrufen, keine Tabelle direkt"
  eintrag "dbPassword"     "$DB_PASSWORD"          "Kommt aus der .env, nicht aus der Kanal-XML"
  eintrag "errorStorePath" "$ERROR_STORE_PATH"     "Verzeichnis der Fehlerablage als Datei"
  echo '</map>'
} > "$configmap"

antwort=$("${CURL[@]}" --write-out '\n%{http_code}' \
          --request PUT \
          --header "Content-Type: application/xml" \
          --data-binary "@$configmap" \
          "${MIRTH_URL}/api/server/configurationMap")
rm -f "$configmap"

code=$(printf '%s' "$antwort" | tail -1)
case "$code" in
    2*) echo "Configuration Map gesetzt (HTTP $code)." ;;
    *)  printf '%s\n' "$(meldung "$antwort")" >&2
        fehler "Configuration Map abgelehnt (HTTP $code)" ;;
esac

# ---------------------------------------------------------------------------
schritt "Kanal importieren"
# ---------------------------------------------------------------------------
# override=true, damit ein erneutes Ausrollen den bestehenden Kanal ersetzt
# statt einen zweiten mit gleichem Namen anzulegen. Die feste Kanal-ID in der
# XML sorgt dafuer, dass immer derselbe Kanal getroffen wird - sonst wuerde
# jede Pipeline-Ausfuehrung einen weiteren Kanal hinterlassen.
antwort=$("${CURL[@]}" --write-out '\n%{http_code}' \
          --request PUT \
          --header "Content-Type: application/xml" \
          --data-binary "@${CHANNEL_FILE}" \
          "${MIRTH_URL}/api/channels/${CHANNEL_ID}?override=true")

code=$(printf '%s' "$antwort" | tail -1)
rumpf=$(printf '%s' "$antwort" | sed '$d')
case "$code" in
    2*) echo "Kanal importiert (HTTP $code). Antwort: ${rumpf:-leer}" ;;
    *)  printf '%s\n' "$(meldung "$rumpf")" >&2
        fehler "Import abgelehnt (HTTP $code)" ;;
esac

# ---------------------------------------------------------------------------
schritt "Pruefen, ob Mirth den Kanal annimmt"
# ---------------------------------------------------------------------------
# Mirth meldet einen Kanal, den es nicht lesen kann, NICHT als Fehler: der
# Import antwortet mit 200 und "true", und Mirth legt stillschweigend eine
# leere Huelle an, die es "invalid channel" nennt. Ohne diese Pruefung meldet
# die Pipeline gruen, waehrend kein Connector existiert.
#
# Typische Ursache: ein Feld in der XML, das die Zielklasse nicht hat -
# etwa <queueBufferSize> oder <tags> unter den Kanal-properties. Oder ein
# fehlendes version="..." an einem Element.
beschreibung=$("${CURL[@]}" --header "Accept: application/xml" \
               "${MIRTH_URL}/api/channels?channelId=${CHANNEL_ID}" 2>/dev/null |
               xmllint --xpath 'string(//channel/description)' - 2>/dev/null || true)

case "$beschreibung" in
    "This channel is invalid"*)
        fehler "Mirth hat den Kanal als ungueltig verworfen.
       Mirth sagt dazu nur: \"$beschreibung\"
       Haeufigste Ursachen:
         - ein Element, das die Zielklasse nicht kennt (Mirth ignoriert es
           nicht, sondern verwirft den ganzen Kanal)
         - ein fehlendes version=\"...\" an einem Element; ohne das laeuft
           Mirth in seinen Migrationspfad fuer Altversionen
       Eingrenzen: Bloecke der XML einzeln hochladen und pruefen, ab welchem
       die Beschreibung auf \"This channel is invalid\" wechselt."
        ;;
    "")
        fehler "Der Kanal ist nach dem Import nicht abrufbar."
        ;;
    *)
        echo "Mirth hat den Kanal gelesen."
        ;;
esac

# ---------------------------------------------------------------------------
schritt "Kanal ausrollen"
# ---------------------------------------------------------------------------
antwort=$("${CURL[@]}" --write-out '\n%{http_code}' \
          --request POST \
          --header "Content-Type: application/xml" \
          --data-binary "<set><string>${CHANNEL_ID}</string></set>" \
          "${MIRTH_URL}/api/channels/_deploy?returnErrors=true")

code=$(printf '%s' "$antwort" | tail -1)
rumpf=$(printf '%s' "$antwort" | sed '$d')
case "$code" in
    2*) echo "Ausrollen angestossen (HTTP $code)." ;;
    *)  printf '%s\n' "$(meldung "$rumpf")" >&2
        fehler "Ausrollen abgelehnt (HTTP $code)" ;;
esac

# ---------------------------------------------------------------------------
schritt "Nachsehen, ob der Kanal laeuft"
# ---------------------------------------------------------------------------
# Ein erfolgreiches Ausrollen heisst noch nicht, dass der Kanal gestartet ist:
# ein Fehler im Deploy-Skript oder ein belegter Port zeigt sich erst hier.
# Ohne diese Pruefung meldet die Pipeline gruen, waehrend nichts laeuft.
frist=$(( $(date +%s) + 60 ))
status=""
while [ "$(date +%s)" -lt "$frist" ]; do
    status=$("${CURL[@]}" --header "Accept: application/json" \
             "${MIRTH_URL}/api/channels/statuses" 2>/dev/null |
             jq -r --arg id "$CHANNEL_ID" \
                '[ .. | objects | select(.channelId? == $id) ] | .[0].state // empty' \
             2>/dev/null || true)
    [ -n "$status" ] && break
    sleep 2
done

if [ "$status" = "STARTED" ]; then
    echo "Kanal \"ADT Inbound\" laeuft."
elif [ -n "$status" ]; then
    fehler "Kanal ist im Zustand \"$status\" statt STARTED. 'docker compose logs mirth' ansehen."
else
    echo "WARNUNG: Zustand liess sich nicht auslesen. Kanal in der Oberflaeche pruefen: ${MIRTH_URL}"
fi

printf '\nFertig. Weboberflaeche: %s\n' "$MIRTH_URL"
