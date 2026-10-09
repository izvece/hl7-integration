# Minimaler Empfaenger fuer Alarme in der lokalen Umgebung.
# Nimmt die Webhooks des Alertmanagers an und schreibt sie lesbar ins Log,
# damit man einen Alarm mit "docker compose logs -f alert-sink" sieht, ohne
# erst Slack oder einen Mailserver anzubinden.
FROM python:3.12-alpine

COPY sink.py /app/sink.py
WORKDIR /app

EXPOSE 8080
CMD ["python", "-u", "sink.py"]
