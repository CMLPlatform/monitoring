# Cloudflare edge for the monitoring stack: the tunnel, its ingress rules,
# and DNS. This is the only part of the stack that otherwise lives as
# click-ops in the Zero Trust dashboard.
#
# Bootstrap (owner-run, once):
#   cp terraform.tfvars.example terraform.tfvars   # then fill it in
#   export CLOUDFLARE_API_TOKEN=...   # needs Tunnel:Edit, DNS:Edit, Access:Edit
#   cd infra && tofu init
#   ./generate-imports.sh > imports.tf   # the edge already exists: adopt it first
#   tofu plan                            # expect "0 to add" — see the script's header
#   tofu apply && rm imports.tf
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
  description = "Apex domain, e.g. example.org → grafana.example.org, otel.example.org."
}

variable "grafana_allowed_emails" {
  type        = list(string)
  description = "Email addresses allowed through Cloudflare Access to Grafana (one-time PIN)."
  validation {
    condition     = length(var.grafana_allowed_emails) > 0
    error_message = "Set at least one email, or Cloudflare Access locks everyone out of Grafana."
  }
}

resource "cloudflare_zero_trust_tunnel_cloudflared" "monitoring" {
  account_id = var.account_id
  # Must match the live tunnel's name: this root adopts it rather than creating it
  # (see generate-imports.sh), and a different name here renames it on apply.
  name       = "cml-monitoring"
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
        hostname = "otel.${var.domain}"
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
  # Provider v5 requires the full hostname (terraform-provider-cloudflare#5620).
  name    = "grafana.${var.domain}"
  type    = "CNAME"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.monitoring.id}.cfargotunnel.com"
  proxied = true
  ttl     = 1
}

# Renamed from `otlp` (2026-09). There is no `moved` block because nothing was ever
# in state under the old name: the live record is adopted straight into this address
# by ./generate-imports.sh, and the apply then renames it in place.
resource "cloudflare_dns_record" "otel" {
  zone_id = var.zone_id
  name    = "otel.${var.domain}"
  type    = "CNAME"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.monitoring.id}.cfargotunnel.com"
  proxied = true
  ttl     = 1
}

# Cloudflare Access in front of Grafana: email one-time-PIN at the edge, so
# the public hostname never reaches Grafana's login page unauthenticated.
# The ingestion hostname is NOT behind Access — machines authenticate with the
# bearer token instead.
resource "cloudflare_zero_trust_access_application" "grafana" {
  account_id       = var.account_id
  name             = "Grafana (monitoring)"
  domain           = "grafana.${var.domain}"
  type             = "self_hosted"
  session_duration = "24h"

  policies = [{
    id         = cloudflare_zero_trust_access_policy.grafana_emails.id
    precedence = 1
  }]
}

resource "cloudflare_zero_trust_access_policy" "grafana_emails" {
  account_id = var.account_id
  name       = "monitoring: allowed emails"
  decision   = "allow"

  include = [for email in var.grafana_allowed_emails : {
    email = { email = email }
  }]
}

data "cloudflare_zero_trust_tunnel_cloudflared_token" "monitoring" {
  account_id = var.account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.monitoring.id
}

output "grafana_access_aud" {
  description = "Set as CF_ACCESS_AUD in ../.env so Grafana rejects tokens minted for other Access apps."
  value       = cloudflare_zero_trust_access_application.grafana.aud
}

output "tunnel_token" {
  description = "Set as CLOUDFLARE_TUNNEL_TOKEN in ../.env for the tunnel overlay."
  value       = data.cloudflare_zero_trust_tunnel_cloudflared_token.monitoring.token
  sensitive   = true
}
