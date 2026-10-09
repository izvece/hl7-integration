#!/usr/bin/env python3
"""Schickt HL7-v2-Nachrichten per MLLP an den Integrationsserver.

Steht absichtlich nur auf der Standardbibliothek: das Skript laeuft damit in
jedem python:3-Container, ohne dass irgendwo Abhaengigkeiten installiert werden
muessen - lokal wie in der Pipeline.

Aufruf:
    python3 send_hl7.py --host localhost --port 6661 samples/*.hl7
    python3 send_hl7.py --host localhost --port 6661 --wiederholen 3 samples/01_*.hl7
"""

from __future__ import annotations

import argparse
import socket
import sys
from pathlib import Path

# Der MLLP-Rahmen. Ohne ihn weiss der Empfaenger nicht, wo eine Nachricht
# anfaengt und aufhoert - TCP allein kennt keine Nachrichtengrenzen.
START_BLOCK = b"\x0b"
END_BLOCK = b"\x1c"
CARRIAGE_RETURN = b"\x0d"


def rahmen(nachricht: bytes) -> bytes:
    return START_BLOCK + nachricht + END_BLOCK + CARRIAGE_RETURN


def entrahmen(rohdaten: bytes) -> bytes:
    return rohdaten.strip(START_BLOCK + END_BLOCK + CARRIAGE_RETURN)


def ack_auswerten(ack: bytes) -> tuple[str, str]:
    """Liest Quittungscode und Begruendung aus dem MSA-Segment.

    Rueckgabe: (code, text). Code ist AA (angenommen), AE (inhaltlich
    abgelehnt), AR (abgewiesen) oder '?' wenn sich nichts lesen laesst.
    """
    text = ack.decode("utf-8", errors="replace")
    for segment in text.replace("\n", "\r").split("\r"):
        if segment.startswith("MSA"):
            felder = segment.split("|")
            code = felder[1] if len(felder) > 1 else "?"
            begruendung = felder[3] if len(felder) > 3 else ""
            return code, begruendung
    return "?", "kein MSA-Segment in der Quittung"


def senden(host: str, port: int, nachricht: bytes, timeout: float) -> bytes:
    with socket.create_connection((host, port), timeout=timeout) as verbindung:
        verbindung.sendall(rahmen(nachricht))

        # Bis zum Ende-Zeichen lesen. Ein einzelnes recv() reicht nicht:
        # TCP darf die Antwort in beliebig viele Pakete zerlegen.
        puffer = bytearray()
        while END_BLOCK not in puffer:
            haeppchen = verbindung.recv(4096)
            if not haeppchen:
                break
            puffer.extend(haeppchen)
        return entrahmen(bytes(puffer))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("dateien", nargs="+", type=Path)
    parser.add_argument("--host", default="localhost")
    parser.add_argument("--port", type=int, default=6661)
    parser.add_argument("--timeout", type=float, default=15.0)
    parser.add_argument("--wiederholen", type=int, default=1,
                        help="jede Nachricht n-mal senden, um die "
                             "Dublettenerkennung zu pruefen")
    argumente = parser.parse_args()

    ergebnisse: list[tuple[str, str, str]] = []

    for durchlauf in range(argumente.wiederholen):
        for datei in argumente.dateien:
            if not datei.is_file():
                print(f"uebersprungen (nicht gefunden): {datei}", file=sys.stderr)
                continue

            # HL7 verlangt Carriage Return als Segmenttrenner. Ein mit einem
            # Editor bearbeitete Datei hat oft \n - das hier korrigiert es,
            # statt den Empfaenger an einer Nachricht mit einem Segment
            # verzweifeln zu lassen.
            rohdaten = datei.read_bytes().replace(b"\r\n", b"\r").replace(b"\n", b"\r")

            try:
                ack = senden(argumente.host, argumente.port, rohdaten, argumente.timeout)
            except OSError as fehler:
                print(f"FEHLGESCHLAGEN {datei.name}: {fehler}", file=sys.stderr)
                ergebnisse.append((datei.name, "--", str(fehler)))
                continue

            code, begruendung = ack_auswerten(ack)
            kennzeichen = {"AA": "angenommen", "AE": "abgelehnt", "AR": "abgewiesen"}.get(code, code)
            zusatz = f" ({durchlauf + 1}. Versuch)" if argumente.wiederholen > 1 else ""

            print(f"{code}  {datei.name}{zusatz}  -> {kennzeichen}"
                  + (f": {begruendung}" if begruendung else ""))
            ergebnisse.append((datei.name, code, begruendung))

    print()
    angenommen = sum(1 for _, code, _ in ergebnisse if code == "AA")
    abgelehnt = sum(1 for _, code, _ in ergebnisse if code in ("AE", "AR"))
    ohne = len(ergebnisse) - angenommen - abgelehnt
    print(f"{len(ergebnisse)} gesendet: {angenommen} angenommen, "
          f"{abgelehnt} abgelehnt, {ohne} ohne Quittung")

    # Abgelehnte Nachrichten sind KEIN Fehlschlag des Skripts - genau das soll
    # der Kanal mit fehlerhaften Nachrichten tun. Nur eine ausgebliebene
    # Quittung ist ein Problem.
    return 1 if ohne else 0


if __name__ == "__main__":
    sys.exit(main())
