set dotenv-load

default:
    @just --list

up:
    docker compose up -d

down:
    docker compose down

logs service="":
    docker compose logs -f {{service}}

ps:
    docker compose ps

restart service:
    docker compose restart {{service}}

pull:
    docker compose pull

# Tail a service's logs as JSON, decoded. Useful before Grafana is set up.
tail service:
    docker compose logs -f --no-log-prefix {{service}} | jq -R 'fromjson? // .'
