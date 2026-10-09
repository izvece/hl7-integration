# HL7-ADT-Integration, lokal in Docker

Ein vollständiger HL7-v2-Integrationskanal zum Anfassen: Nachrichten kommen per
MLLP herein, werden geprüft, nach PostgreSQL geschrieben, und was nicht passt,
landet nachvollziehbar in einer Fehlerablage. Dazu eine Pipeline, die das
ausrollt, und ein Monitoring, das meldet, wenn Nachrichten hängen bleiben.

## Was hier läuft

```
  Quellsystem (KIS)
        │  HL7 v2 ADT über MLLP, Port 6661
        ▼
  ┌─────────────────────────────────────────────┐
  │  Mirth Connect – Kanal "ADT Inbound"        │
  │                                             │
  │  Transformer: prüfen und abbilden           │
  │        │                                    │
  │        ├─ Ziel 1  Eingang festhalten  ──────┼──▶ hl7.message_log (received)
  │        │                                    │
  │        ├─ Ziel 2  [gültig]            ──────┼──▶ hl7.patient_event
  │        │           Patientendaten           │    + Status processed
  │        │                                    │
  │        ├─ Ziel 3  [fehlerhaft]        ──────┼──▶ hl7.message_error
  │        │           Fehlerablage DB          │    + Status error
  │        │                                    │
  │        └─ Ziel 4  [fehlerhaft]        ──────┼──▶ /data/error-store/*.hl7
  │                    Fehlerablage Datei       │
  │                                             │
  │  Postprocessor: Quittung AA / AE  ──────────┼──▶ zurück ans Quellsystem
  └─────────────────────────────────────────────┘
                      │
                      ▼
          hl7.v_pipeline ──▶ postgres_exporter ──▶ Prometheus ──▶ Alertmanager
                                                        │
                                                   Grafana
```

## Schnellstart

Voraussetzung: Docker mit Compose v2.

```bash
make init          # .env aus der Vorlage anlegen – danach Passwörter ändern
make up            # alle Container starten
make deploy        # Kanal bauen und ausrollen
make test          # SQL-Logik und Ende-zu-Ende prüfen
```

Danach:

| Oberfläche    | Adresse                  |
|---------------|--------------------------|
| Mirth Connect | https://localhost:8443   |
| Grafana       | http://localhost:3000    |
| Prometheus    | http://localhost:9090    |
| Alertmanager  | http://localhost:9093    |
| MLLP-Listener | localhost:6661           |

`make` ohne Argument zeigt alle Befehle.

## Einmal von Hand durchspielen

```bash
make send          # alle Beispielnachrichten senden
make status        # Zustand der Pipeline
make fehler        # was in der Fehlerablage liegt
```

Von den acht Beispielnachrichten sind drei gültig und fünf fehlerhaft – jede mit
einem anderen Problem. Die Quittungen zeigen den Unterschied direkt:

```
AA  01_gueltig_a01_aufnahme.hl7          -> angenommen
AE  10_fehler_ohne_pid.hl7               -> abgelehnt: MISSING_SEGMENT: PID fehlt …
AE  13_fehler_ereignis_a40.hl7           -> abgelehnt: UNSUPPORTED_TRIGGER_EVENT: …
```

## Den Alarm ausprobieren

Ein Monitoring, das man nie hat feuern gesehen, ist kein Monitoring:

```bash
make alarm-ausloesen   # täuscht eine seit einer Stunde hängende Nachricht vor
make logs-alarme       # zusehen, wie der Alarm eintrifft
make alarm-aufraeumen
```

Nach gut zwei Minuten (`for: 2m` in der Regel) erscheint im Log des
`alert-sink`-Containers die Meldung samt Hinweis, was zu prüfen ist.

## Aufbau des Repositories

```
db/init/              Schema, Funktionen, Rollen. Laufen beim ersten Start.
  01_roles.sh           drei Dienst-Benutzer mit unterschiedlichen Rechten
  03_schema.sql         message_log, patient_event, message_error
  04_functions.sql      die Verarbeitungslogik
  05_monitoring.sql     Sichten für Prometheus und die Rechtevergabe

mirth/channels/adt-inbound/
  channel.xml           Kanal-Vorlage mit Platzhaltern
  src/*.js              die eigentliche Logik, als normale JS-Dateien

deploy/
  build.sh              setzt src/*.js in die Kanal-XML ein
  deploy.sh             rollt über die Mirth-REST-API aus

monitoring/             Prometheus, Alertmanager, Grafana, Exporter
tests/                  SQL-Tests, MLLP-Client, Beispielnachrichten, E2E-Test
.github/workflows/ci.yml
```

## Vier Entscheidungen, die den Unterschied machen

### 1. Die Logik liegt in SQL-Funktionen, nicht im Kanal

Der Kanal ruft nur `hl7.log_message()`, `hl7.complete_message()` und
`hl7.reject_message()` auf. Das hat zwei Gründe: die Logik ist ohne laufenden
Mirth testbar – `tests/test_functions.sql` prüft sie mit 43 Zusicherungen gegen
ein leeres PostgreSQL – und sie ist nicht in einer XML-Datei eingemauert.

### 2. Annehmen und Verarbeiten sind getrennt

`log_message()` hält den Eingang fest, `complete_message()` verarbeitet. Erst
diese Trennung erzeugt überhaupt den Zustand "angenommen, aber nicht
verarbeitet" – und genau den beobachtet das Monitoring.

Täte eine einzige Funktion beides in einer Transaktion, wäre der Status
`received` nie zu sehen, `oldest_unprocessed_seconds` stünde dauerhaft auf 0 und
der wichtigste Alarm könnte niemals feuern. Ein Monitoring, das strukturell
nichts melden kann, ist schlimmer als keines.

### 3. Die Logik liegt in .js-Dateien, nicht in der XML

Mirth speichert einen Kanal als eine XML-Datei mit dem gesamten JavaScript als
escaptem Text darin. Direkt versioniert wäre jede Änderung ein unlesbarer
Einzeiler-Diff und jede Code-Review sinnlos.

`deploy/build.sh` setzt die Dateien aus `src/` in die Vorlage ein. Die Pipeline
prüft dabei, ob das eingebettete JavaScript unverändert wieder herauskommt – ein
Fehler beim Escaping fällt sonst erst zur Laufzeit an unerwarteter Stelle auf.

### 4. Die Datenbank-Ziele laufen im JavaScript-Modus

Im normalen SQL-Modus setzt Mirth `${variablen}` als Text in das Statement ein.
Rohe HL7-Nachrichten enthalten Anführungszeichen und Zeilenumbrüche – das wäre
eine SQL-Injection-Lücke mit Patientendaten als Einfallstor. Die Ziel-Skripte
binden die Werte stattdessen als echte Parameter.

## Rechte

Drei Rollen, bewusst klein gehalten:

| Rolle         | darf                                                      |
|---------------|-----------------------------------------------------------|
| `mirth`       | nur die eigene Datenbank `mirthdb`, nichts im Schema `hl7` |
| `hl7_app`     | vier Funktionen aufrufen – **keine** Tabelle direkt         |
| `hl7_monitor` | drei Sichten lesen, in denen keine Rohnachricht vorkommt   |

Der Exporter kann damit konstruktiv keine Patientendaten nach Prometheus tragen.
`tests/test_functions.sql` prüft das mit – eine Zusicherung über Rechte sollte
man testen, nicht hoffen.

## Was das Monitoring meldet

| Alarm                             | Bedeutung                                      |
|-----------------------------------|------------------------------------------------|
| `HL7NachrichtenBleibenHaengen`    | älteste unverarbeitete Nachricht > 5 Min        |
| `HL7RueckstauWaechst`             | > 50 wartende Nachrichten – Durchsatzproblem    |
| `HL7KeineNachrichtenMehr`         | > 30 Min Stille – sendet die Quelle noch?       |
| `HL7FehlerHaeufenSich`            | > 5 Ablehnungen in 15 Min – Format geändert?    |
| `HL7FehlerablageNichtAbgearbeitet`| ältester offener Fehler > 24 h                  |
| `HL7MllpListenerNichtErreichbar`  | Port 6661 nimmt nichts an                       |
| `HL7MirthApiNichtErreichbar`      | Verwaltungsschnittstelle antwortet nicht        |
| `HL7DatenbankNichtErreichbar`     | PostgreSQL weg                                  |
| `HL7MonitoringBlind`              | der Exporter liefert nichts – alles andere wertlos |

Zwei davon verdienen eine Erklärung:

**`HL7KeineNachrichtenMehr`** gibt es, weil Stille kein Erfolg ist. Ohne diesen
Alarm ist ein ausgefallener Sender nicht von einem ruhigen Wochenende zu
unterscheiden.

**`HL7MonitoringBlind`** überwacht das Monitoring selbst. Ein Monitoring, das
still ausfällt, ist gefährlicher als keines – man glaubt dann, alles sei in
Ordnung.

Der Alertmanager hat außerdem `inhibit_rules`: ist die Datenbank weg, meldet nur
die Ursache, nicht zusätzlich die Folge. Sonst sucht man beim nächsten Mal an
der falschen Stelle.

## Die Pipeline

Vier Stufen, in dieser Reihenfolge:

1. **Konfiguration prüfen** – shellcheck, Kanal-XML bauen, JavaScript-Einbettung
   gegenprüfen, `promtool check rules`, `amtool check-config`, Dashboard-JSON.
   Läuft in Sekunden und fängt die Hälfte aller Fehler, bevor ein Container startet.
2. **SQL-Logik testen** – gegen ein echtes PostgreSQL, ohne Mirth.
3. **Ende-zu-Ende** – kompletter Stapel, Kanal ausrollen, acht Nachrichten durch,
   Datenbank und Fehlerablage prüfen. Dazu: feuert der Alarm wirklich? Dafür legt
   die Pipeline eine hängende Nachricht an und wartet, bis Prometheus reagiert.
4. **Ausrollen** – nur von `main`. Nimmt die in Stufe 1 geprüfte XML als
   Artefakt, nicht eine neu gebaute.

Für das Ausrollen auf einen echten Server braucht es eine GitHub-Environment
`integration` mit den Secrets `MIRTH_URL`, `MIRTH_ADMIN_USER`,
`MIRTH_ADMIN_PASSWORD`, `HL7_APP_PASSWORD`, `DB_URL`, `DB_USER`. Ohne die
überspringt die Stufe sich selbst mit einem Hinweis. In einer Environment lässt
sich zusätzlich eine Freigabe durch einen Menschen verlangen – bei
Patientendaten üblich und sinnvoll.

## Mirth-Fallstricke, die hier Zeit gekostet haben

Beim Aufbau des Kanals sind drei Dinge aufgefallen, die man nicht erahnen kann.
Sie stehen hier, weil sie beim nächsten Kanal wieder zuschlagen.

### Mirth verwirft einen Kanal stillschweigend

Enthält die Kanal-XML ein Element, das die Zielklasse nicht hat, antwortet der
Import mit **HTTP 200 und `{"boolean":true}`** — und Mirth legt eine leere Hülle
an, deren Beschreibung lautet: *"This channel is invalid. Verify all required
extensions are loaded correctly."* Kein Fehler, kein Log-Eintrag, nichts.

Konkret waren `<queueBufferSize>` und `<tags>` unter den Kanal-`<properties>`
schuld. Beide Felder existieren auf `ChannelProperties` nicht: `queueBufferSize`
sitzt auf den Connector-Properties, Kanal-Tags leben in
`exportData/channelTags`.

Irreführend dabei: die Meldung spricht von Extensions, obwohl alle Extensions
geladen waren. Und Mirth speichert die XML trotzdem vollständig in seiner
eigenen Datenbank — man kann sie dort lesen und hält sie für in Ordnung.

Deshalb prüft `deploy/deploy.sh` nach dem Import ausdrücklich, ob Mirth den
Kanal gelesen hat. Ohne diesen Schritt meldet die Pipeline grün, während kein
einziger Connector existiert.

Zum Eingrenzen taugt nur Bisektion: Blöcke der XML einzeln unter einer eigenen
Kanal-ID hochladen und sehen, ab welchem die Beschreibung umschlägt.

### Jedes Element braucht sein `version`-Attribut

Fehlt `version="4.5.2"` an einem Element wie `<filter>` oder `<transformer>`,
hält Mirth die Datei für einen Export einer Altversion und schickt sie durch
`ImportConverter3_0_0`. Dort stirbt sie an einem NullPointer — ebenfalls ohne
verwertbare Meldung.

### Mirths API verlangt `X-Requested-With`

Ohne diesen Header antwortet Mirth auf jede Anfrage mit **HTTP 400**, egal wie
richtig sie sonst ist — das ist sein CSRF-Schutz. Das trifft auch das
Monitoring: der blackbox-Prober bekam erst ein nutzloses 400, wo ein 401
("lebt, verlangt Anmeldung") das brauchbare Signal ist. Er sendet den Header
deshalb jetzt mit.

### Falls `docker` nach der Installation nicht gefunden wird

Docker Desktop legt die CLI nach `~/.docker/bin` und setzt den Symlink nach
`/usr/local/bin` nur mit Admin-Rechten. Wurden die beim Setup nicht erteilt,
fehlt Docker im PATH. Abhilfe in `~/.zshrc`:

```bash
export PATH="$HOME/.docker/bin:$PATH"
```

## Nach einer Schema-Änderung

Die Skripte in `db/init/` laufen **nur bei einer leeren Datenbank**. Nach einer
Änderung am Schema:

```bash
make reset         # löscht die Volumes, fragt vorher nach
make up && make deploy
```

Für echten Betrieb gehören Schema-Änderungen in ein Migrationswerkzeug
(Flyway, Liquibase, sqitch) statt in `docker-entrypoint-initdb.d`.

## Was hier bewusst fehlt

Das ist eine Lernumgebung, kein Produktivsystem. Vor einem echten Einsatz fehlen
mindestens:

- **Verschlüsselung.** `messageStorageMode` steht auf `DEVELOPMENT` und
  `encryptData` auf `false`, damit man im Message-Browser alles sehen kann. Mit
  echten Patientendaten: `PRODUCTION` und Verschlüsselung an.
- **Echte Zertifikate.** Mirth bringt ein selbst signiertes mit, die Skripte
  rufen `curl -k`. Im Betrieb ein eigenes Zertifikat und `--cacert`.
- **TLS zur Datenbank.** Die Verbindungen laufen mit `sslmode=disable`.
- **Datensparsamkeit.** `raw_message` speichert die vollständige Nachricht
  unbegrenzt. Echter Betrieb braucht eine Löschfrist.
- **Migrationen** statt Init-Skripte, siehe oben.
- **Mehr HL7.** Nur ADT, nur sieben Ereignisse, keine Batch-Nachrichten, keine
  Zeichensatz-Behandlung jenseits von UTF-8.
