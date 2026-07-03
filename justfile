set dotenv-load

default:
    @just --list

# Core stack (no tunnel; Grafana at http://localhost:3000)
up:
    docker compose up -d

# Core stack + Cloudflare Tunnel (production; needs CLOUDFLARE_TUNNEL_TOKEN)
up-tunnel:
    docker compose -f compose.yml -f compose.tunnel.yml up -d

down:
    docker compose down --remove-orphans

# Core stack + a demo telemetry source (see compose.demo.yml), then look at
# Grafana: http://localhost:3000
demo:
    docker compose -f compose.yml -f compose.demo.yml up -d --build

demo-down:
    docker compose -f compose.yml -f compose.demo.yml down

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

