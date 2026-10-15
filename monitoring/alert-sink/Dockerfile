# Minimaler Empfaenger fuer Alarme in der lokalen Umgebung.
# Nimmt die Webhooks des Alertmanagers an und schreibt sie lesbar ins Log,
# damit man einen Alarm mit "docker compose logs -f alert-sink" sieht, ohne
# erst Slack oder einen Mailserver anzubinden.
# Aus der ECR-Spiegelung statt von Docker Hub - siehe Kommentar in
# docker-compose.yml zum Pull-Limit. Die Pipeline setzt BASE_IMAGE auf die
# Spiegelung in der GitHub Container Registry (docker-compose.ci.yml).
ARG BASE_IMAGE=public.ecr.aws/docker/library/python:3.12-alpine
FROM ${BASE_IMAGE}

COPY sink.py /app/sink.py
WORKDIR /app

EXPOSE 8080
CMD ["python", "-u", "sink.py"]
