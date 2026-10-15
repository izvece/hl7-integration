# ---------------------------------------------------------------------------
# HL7-Integrationsumgebung
#
# "make" allein zeigt alle Befehle mit Erklaerung.
# ---------------------------------------------------------------------------

SHELL := /bin/bash
COMPOSE := docker compose
CHANNEL_ID := 3a9f1c7e-2b4d-4e58-9a61-7c0d5e8f1b23

# Die .env wird geladen und exportiert, damit sowohl docker compose als auch
# die Skripte in deploy/ und tests/ dieselben Werte sehen.
ifneq (,$(wildcard .env))
include .env
export
endif

.DEFAULT_GOAL := hilfe

# ---------------------------------------------------------------------------
.PHONY: hilfe
hilfe:  ## Diese Uebersicht anzeigen
	@echo "HL7-Integrationsumgebung"
	@echo
	@grep -hE '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*?## "} {printf "  \033[1m%-16s\033[0m %s\n", $$1, $$2}'
	@echo
	@echo "Erster Start:  make init && make up && make deploy && make test"

# --- Einrichten -------------------------------------------------------------
.PHONY: init
init:  ## .env aus der Vorlage anlegen und Verzeichnisse erstellen
	@if [ -f .env ]; then \
	  echo ".env ist schon vorhanden - unangetastet gelassen."; \
	else \
	  cp .env.example .env; \
	  echo ".env angelegt. JETZT die Passwoerter darin aendern."; \
	fi
	@mkdir -p data/error-store && chmod 0777 data/error-store
	@echo "Verzeichnis data/error-store bereit."

# --- Stapel steuern ---------------------------------------------------------
.PHONY: up
up:  ## Alle Container starten und auf Bereitschaft warten
	@# Mirth schreibt im Container als Nutzer 1000. Auf einem Linux-Host gehoert
	@# der Ordner sonst dem eigenen Nutzer, und die Fehlerablage bleibt still leer.
	@mkdir -p data/error-store && chmod 0777 data/error-store
	@echo "Starte Container und warte auf ihre Healthchecks..."
	$(COMPOSE) up -d --build --wait
	@echo "Warte auf Mirth (das dauert beim ersten Start eine Minute)..."
	@until curl -sk --max-time 3 https://localhost:$(MIRTH_HTTPS_PORT)/api/server/version \
	        > /dev/null 2>&1; do printf '.'; sleep 3; done
	@echo " bereit."
	@$(MAKE) --no-print-directory urls

.PHONY: down
down:  ## Container stoppen, Daten behalten
	$(COMPOSE) down

.PHONY: reset
reset:  ## Alles loeschen, auch die Datenbank. Danach laufen die Init-Skripte neu.
	@echo "Loescht ALLE Daten: Datenbank, Mirth-Kanaele, Metriken, Fehlerablage."
	@read -p "Wirklich? [j/N] " a; [ "$$a" = "j" ] || exit 1
	$(COMPOSE) down -v
	rm -rf data/error-store/*
	@echo "Zurueckgesetzt. Weiter mit: make up && make deploy"

.PHONY: urls
urls:  ## Die Adressen aller Oberflaechen anzeigen
	@echo
	@echo "  Mirth Connect   https://localhost:$(MIRTH_HTTPS_PORT)   ($(MIRTH_ADMIN_USER))"
	@echo "  Grafana         http://localhost:$(GRAFANA_PORT)         (admin)"
	@echo "  Prometheus      http://localhost:$(PROMETHEUS_PORT)"
	@echo "  Alertmanager    http://localhost:$(ALERTMANAGER_PORT)"
	@echo "  MLLP-Listener   localhost:$(MLLP_PORT)"
	@echo

# --- Kanal ------------------------------------------------------------------
.PHONY: build
build:  ## Kanal-XML aus channel.xml und src/*.js bauen
	./deploy/build.sh

.PHONY: deploy
deploy: build  ## Kanal bauen und auf den laufenden Mirth ausrollen
	MIRTH_URL=https://localhost:$(MIRTH_HTTPS_PORT) ./deploy/deploy.sh

# --- Tests ------------------------------------------------------------------
.PHONY: test
test: test-sql test-e2e  ## Alle Tests

.PHONY: test-sql
test-sql:  ## Die SQL-Funktionen testen (braucht nur PostgreSQL)
	@echo "==> SQL-Funktionen"
	@$(COMPOSE) exec -T postgres psql -v ON_ERROR_STOP=1 \
	    -U $(POSTGRES_USER) -d $(POSTGRES_DB) \
	    < tests/test_functions.sql

.PHONY: test-e2e
test-e2e:  ## Nachrichten durch den laufenden Kanal schicken und pruefen
	./tests/test_e2e.sh

.PHONY: send
send:  ## Alle Beispielnachrichten senden (ohne Pruefungen)
	docker run --rm --network host -v "$(PWD)/tests:/tests:ro" -w /tests \
	  public.ecr.aws/docker/library/python:3.12-alpine python send_hl7.py \
	    --host localhost --port $(MLLP_PORT) samples/*.hl7

# --- Hineinsehen ------------------------------------------------------------
.PHONY: logs
logs:  ## Logs aller Container verfolgen
	$(COMPOSE) logs -f --tail=50

.PHONY: logs-mirth
logs-mirth:  ## Nur die Mirth-Logs verfolgen
	$(COMPOSE) logs -f --tail=100 mirth

.PHONY: logs-alarme
logs-alarme:  ## Die ausgeloesten Alarme verfolgen
	$(COMPOSE) logs -f alert-sink

.PHONY: psql
psql:  ## Eine SQL-Eingabeaufforderung auf der Zieldatenbank
	$(COMPOSE) exec postgres psql -U $(POSTGRES_USER) -d $(POSTGRES_DB)

.PHONY: status
status:  ## Zustand der Pipeline in einer Tabelle
	@$(COMPOSE) exec -T postgres psql -U $(POSTGRES_USER) -d $(POSTGRES_DB) -c \
	  "SELECT * FROM hl7.v_pipeline;"
	@$(COMPOSE) exec -T postgres psql -U $(POSTGRES_USER) -d $(POSTGRES_DB) -c \
	  "SELECT status, total FROM hl7.v_status_counts ORDER BY status;"

.PHONY: fehler
fehler:  ## Die offene Fehlerablage anzeigen
	@$(COMPOSE) exec -T postgres psql -U $(POSTGRES_USER) -d $(POSTGRES_DB) -c \
	  "SELECT id, occurred_at, control_id, reason, trigger_event FROM hl7.v_error_inbox LIMIT 20;"
	@echo "Dateien in der Fehlerablage:"
	@ls -1 data/error-store/ 2>/dev/null | tail -10 || echo "  (leer)"

.PHONY: metriken
metriken:  ## Die eigenen Metriken ansehen, wie Prometheus sie sieht
	@$(COMPOSE) exec -T blackbox-exporter \
	  wget -qO- http://postgres-exporter:9187/metrics | grep '^hl7_' || \
	  echo "Keine hl7_-Metriken. Laeuft der Exporter? make logs"

# --- Alarm ausprobieren -----------------------------------------------------
.PHONY: alarm-ausloesen
alarm-ausloesen:  ## Eine haengende Nachricht vortaeuschen, damit der Alarm feuert
	@echo "Legt eine Nachricht an, die vor einer Stunde ankam und nie verarbeitet wurde."
	@$(COMPOSE) exec -T postgres psql -U $(POSTGRES_USER) -d $(POSTGRES_DB) -c \
	  "INSERT INTO hl7.message_log (control_id, sending_facility, message_type, \
	     trigger_event, raw_message, status, received_at) \
	   VALUES ('HAENGT-' || floor(random()*100000)::text, 'TESTHAUS', 'ADT', 'A01', \
	           'MSH|^~\\&|TEST|...', 'received', now() - interval '1 hour');"
	@echo
	@echo "Der Alarm HL7NachrichtenBleibenHaengen braucht 'for: 2m' - also zwei Minuten."
	@echo "Zusehen:  make logs-alarme"
	@echo "Oder:     http://localhost:$(PROMETHEUS_PORT)/alerts"
	@echo "Aufraeumen mit: make alarm-aufraeumen"

.PHONY: alarm-aufraeumen
alarm-aufraeumen:  ## Die vorgetaeuschten haengenden Nachrichten entfernen
	@$(COMPOSE) exec -T postgres psql -U $(POSTGRES_USER) -d $(POSTGRES_DB) -c \
	  "DELETE FROM hl7.message_log WHERE control_id LIKE 'HAENGT-%';"

# --- Pruefungen wie in der Pipeline -----------------------------------------
.PHONY: lint
lint:  ## Alle Konfigurationen pruefen, so wie die Pipeline es tut
	@echo "==> Shell-Skripte"
	@if command -v shellcheck > /dev/null; then \
	  shellcheck deploy/*.sh tests/*.sh db/init/*.sh; \
	else echo "  shellcheck nicht installiert, uebersprungen"; fi
	@echo "==> Kanal-XML"
	@./deploy/build.sh > /dev/null && echo "  XML wohlgeformt"
	@echo "==> Prometheus-Regeln"
	@docker run --rm -v "$(PWD)/monitoring/prometheus:/p:ro" \
	  --entrypoint promtool quay.io/prometheus/prometheus:v2.53.0 check rules /p/rules/hl7.yml
	@echo "==> Prometheus-Konfiguration"
	@docker run --rm -v "$(PWD)/monitoring/prometheus:/p:ro" \
	  --entrypoint promtool quay.io/prometheus/prometheus:v2.53.0 check config /p/prometheus.yml
	@echo "==> Alertmanager-Konfiguration"
	@docker run --rm -v "$(PWD)/monitoring/alertmanager:/a:ro" \
	  --entrypoint amtool quay.io/prometheus/alertmanager:v0.27.0 check-config /a/alertmanager.yml
	@echo "==> Grafana-Dashboard"
	@jq -e '.panels | length > 0' monitoring/grafana/dashboards/hl7-pipeline.json > /dev/null \
	  && echo "  Dashboard-JSON gueltig"
