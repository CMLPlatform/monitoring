# Cloudflare edge for the monitoring stack: the tunnel, its ingress rules,
# and DNS. This is the only part of the stack that otherwise lives as
# click-ops in the Zero Trust dashboard.
#
# Bootstrap (owner-run, once):
#   export CLOUDFLARE_API_TOKEN=...   # needs Tunnel:Edit, DNS:Edit
#   cd infra && tofu init && tofu apply
#   tofu output -raw tunnel_token     # → CLOUDFLARE_TUNNEL_TOKEN in ../.env
#
# State is local (infra/terraform.tfstate, gitignored) — one host, one
# operator; move it to R2 the day a second operator exists.

terraform {
  required_version = ">= 1.8"
  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.0"
    }
  }
}

provider "cloudflare" {
  # Auth via the CLOUDFLARE_API_TOKEN environment variable.
}

variable "account_id" {
  type        = string
  description = "Cloudflare account ID (dash.cloudflare.com → overview sidebar)."
}

variable "zone_id" {
  type        = string
  description = "Zone ID of the domain the hostnames live under."
}

variable "domain" {
  type        = string
  description = "Apex domain, e.g. example.org → grafana.example.org, otlp.example.org."
}

resource "cloudflare_zero_trust_tunnel_cloudflared" "monitoring" {
  account_id = var.account_id
  name       = "monitoring"
  config_src = "cloudflare"
}

resource "cloudflare_zero_trust_tunnel_cloudflared_config" "monitoring" {
  account_id = var.account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.monitoring.id

  config = {
    ingress = [
      {
        hostname = "grafana.${var.domain}"
        service  = "http://grafana:3000"
      },
      {
        # OTLP HTTP ingestion; the collector enforces bearer-token auth.
        hostname = "otlp.${var.domain}"
        service  = "http://otel-collector:4318"
      },
      {
        service = "http_status:404"
      },
    ]
  }
}

resource "cloudflare_dns_record" "grafana" {
  zone_id = var.zone_id
  name    = "grafana"
  type    = "CNAME"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.monitoring.id}.cfargotunnel.com"
  proxied = true
  ttl     = 1
}

resource "cloudflare_dns_record" "otlp" {
  zone_id = var.zone_id
  name    = "otlp"
  type    = "CNAME"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.monitoring.id}.cfargotunnel.com"
  proxied = true
  ttl     = 1
}

data "cloudflare_zero_trust_tunnel_cloudflared_token" "monitoring" {
  account_id = var.account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.monitoring.id
}

output "tunnel_token" {
  description = "Set as CLOUDFLARE_TUNNEL_TOKEN in ../.env for just up-tunnel."
  value       = data.cloudflare_zero_trust_tunnel_cloudflared_token.monitoring.token
  sensitive   = true
}
