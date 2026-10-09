"""Nimmt Alertmanager-Webhooks an und schreibt sie lesbar auf stdout.

Absichtlich ohne Abhaengigkeiten - nur die Standardbibliothek. Dieser Dienst
ist ein Platzhalter fuer den echten Empfaenger (Slack, E-Mail, Ticketsystem)
und soll nichts weiter koennen, als einen Alarm sichtbar zu machen.
"""

import json
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, HTTPServer

TRENNER = "=" * 78


def jetzt() -> str:
    return datetime.now(timezone.utc).astimezone().strftime("%Y-%m-%d %H:%M:%S")


class AlarmHandler(BaseHTTPRequestHandler):
    def do_POST(self) -> None:
        laenge = int(self.headers.get("Content-Length", 0))
        rohdaten = self.rfile.read(laenge)

        try:
            nutzlast = json.loads(rohdaten)
        except json.JSONDecodeError:
            print(f"[{jetzt()}] Unlesbarer Webhook: {rohdaten[:200]!r}")
            self.send_response(400)
            self.end_headers()
            return

        for alarm in nutzlast.get("alerts", []):
            labels = alarm.get("labels", {})
            anmerkungen = alarm.get("annotations", {})
            status = alarm.get("status", "unbekannt")

            # Behobene Alarme sind genauso wichtig wie neue: ohne sie weiss
            # niemand, ob sich das Problem erledigt hat.
            kennzeichen = "BEHOBEN " if status == "resolved" else "ALARM   "

            print(TRENNER)
            print(f"[{jetzt()}] {kennzeichen} {labels.get('alertname', '?')}"
                  f"  (severity={labels.get('severity', '?')})")

            if anmerkungen.get("summary"):
                print(f"  {anmerkungen['summary']}")
            if anmerkungen.get("description"):
                print(f"  {anmerkungen['description'].strip()}")
            if anmerkungen.get("pruefen"):
                print("  Zu pruefen:")
                for zeile in anmerkungen["pruefen"].strip().splitlines():
                    print(f"    {zeile.strip()}")
            print(TRENNER)

        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"ok")

    def do_GET(self) -> None:
        """Healthcheck."""
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"alert-sink laeuft")

    def log_message(self, *args) -> None:
        """Den Zugriffs-Log unterdruecken - sonst geht der Alarm darin unter."""


if __name__ == "__main__":
    print(f"[{jetzt()}] alert-sink hoert auf Port 8080")
    HTTPServer(("0.0.0.0", 8080), AlarmHandler).serve_forever()
