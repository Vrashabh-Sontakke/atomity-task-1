# Keycloak on EC2 with Traefik

> Written from real debugging experience. No fluff.

---

## Overview

This guide walks through deploying Keycloak behind Traefik on an AWS EC2 instance using Docker Compose. The common pain points — HTTPS enforcement errors, routing failures, network isolation, and security group misconfiguration — are all documented here.

> ⚠️ **Memory Requirement**: Keycloak needs more than 2 GB RAM to start reliably. A `t2.micro` (1 GB) will OOM before it finishes booting. Use at least a `t3.small` (2 GB) or `t3.medium` (4 GB).

---

## Why Traefik?

Keycloak enforces HTTPS by default when it detects it's running without TLS. Accessing it directly over HTTP on a raw EC2 instance causes it to redirect everything to HTTPS — which breaks since there's no certificate.

Traefik acts as a reverse proxy in front of Keycloak. It accepts HTTP on port 80, forwards it to Keycloak internally, and sets the `X-Forwarded-Proto` header. With `KC_PROXY: edge` set, Keycloak trusts these headers and stops enforcing HTTPS itself.

---

## Architecture

```
Internet
    |
    | :80 (HTTP)
    v
[ Traefik ] ────────────── :8081 (Dashboard)
    |
    | internal Docker network
    | :8080
    v
[ Keycloak ]
    |
    | :5432
    v
[ PostgreSQL ]
```

Keycloak's port `8080` is **not** exposed directly to the host. All external traffic goes through Traefik on port `80`.

---

## docker-compose.yml

```yaml
# Requires >2 GB RAM — Keycloak will OOM on t2.micro
services:
  postgres:
    image: postgres:16-alpine
    container_name: keycloak-postgres
    restart: unless-stopped
    environment:
      POSTGRES_DB: keycloak
      POSTGRES_USER: keycloak
      POSTGRES_PASSWORD: keycloak_db_pass
    volumes:
      - postgres_data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U keycloak"]
      interval: 10s
      timeout: 5s
      retries: 5

  traefik:
    image: traefik:v2.11
    container_name: traefik
    restart: unless-stopped
    command:
      - --api.insecure=true
      - --providers.docker=true
      - --entrypoints.web.address=:80
    ports:
      - "80:80"
      - "8081:8080"   # Traefik dashboard
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock

  keycloak:
    image: quay.io/keycloak/keycloak:latest
    container_name: keycloak
    restart: unless-stopped
    command: start-dev
    environment:
      KC_BOOTSTRAP_ADMIN_USERNAME: admin
      KC_BOOTSTRAP_ADMIN_PASSWORD: admin
      KC_DB: postgres
      KC_DB_URL: jdbc:postgresql://postgres:5432/keycloak
      KC_DB_USERNAME: keycloak
      KC_DB_PASSWORD: keycloak_db_pass
      KC_HTTP_ENABLED: "true"
      KC_HOSTNAME_STRICT: "false"
      KC_HOSTNAME_STRICT_HTTPS: "false"
      KC_PROXY: edge              # Critical: trust X-Forwarded headers from Traefik
      KC_HEALTH_ENABLED: "true"
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.keycloak.rule=PathPrefix(`/`)"
      - "traefik.http.routers.keycloak.entrypoints=web"
      - "traefik.http.services.keycloak.loadbalancer.server.port=8080"
    expose:
      - "8080"    # Internal only — Traefik handles external access
    depends_on:
      postgres:
        condition: service_healthy

volumes:
  postgres_data:
```

---

## Critical Environment Variables

| Variable | Purpose |
|---|---|
| `KC_PROXY: edge` | Tells Keycloak it's behind a reverse proxy. Trusts `X-Forwarded-*` headers. **Without this, Keycloak sees plain HTTP and complains.** |
| `KC_HTTP_ENABLED: true` | Allows Keycloak to accept HTTP internally. Required when Traefik is terminating TLS. |
| `KC_HOSTNAME_STRICT: false` | Stops Keycloak from rejecting requests that don't match a configured hostname. Useful with raw IPs. |
| `KC_HOSTNAME_STRICT_HTTPS: false` | Stops Keycloak from forcing HTTPS redirects when hostname strict mode is off. |

> ℹ️ **Host() rule vs PathPrefix() with raw IPs**: Traefik's `Host(`your-ip`)` rule matches the HTTP Host header. This can fail with raw EC2 IPs. Use `PathPrefix(`/`)` as a catch-all instead. If you have a domain, switch to `Host(`yourdomain.com`)`.

---

## EC2 Security Group (Most Common Gotcha)

This is the most common reason Keycloak works internally but is unreachable from the browser. The security group acts as a firewall at the AWS level — even if Docker and Traefik are configured correctly, traffic is dropped if inbound rules are missing.

| Type | Port | Source | Notes |
|---|---|---|---|
| HTTP | 80 | 0.0.0.0/0 | Keycloak via Traefik |
| Custom TCP | 8081 | Your IP only | Traefik dashboard |
| ~~Custom TCP~~ | ~~8080~~ | ~~BLOCK~~ | Do not expose directly |

---

## Accessing Keycloak

```bash
# Start everything
docker compose up -d

# Watch Keycloak boot (takes 30–60s)
docker compose logs keycloak -f
# Wait for: Listening on: http://0.0.0.0:8080
```

| | URL |
|---|---|
| Keycloak Admin | `http://<ec2-public-ip>/admin` |
| Traefik Dashboard | `http://<ec2-public-ip>:8081` |
| Default credentials | `admin` / `admin` |

---

## Debugging Checklist

Run these in order:

**1. Are all containers running?**
```bash
docker compose ps
```

**2. Is Keycloak fully started?**
```bash
docker compose logs keycloak --tail=50
# Look for: Listening on: http://0.0.0.0:8080
```

**3. Can Traefik reach Keycloak internally?**
```bash
docker exec traefik wget -qO- http://keycloak:8080
```

**4. Is Keycloak reachable from the EC2 host?**
```bash
curl -v http://localhost:8080
```

**5. Is Traefik routing configured correctly?**

Open `http://<ec2-ip>:8081` → HTTP → Routers. The `keycloak` router should show as green/matched. If it's missing, the labels on the keycloak service aren't being picked up.

**6. Check the EC2 security group**

AWS Console → EC2 → Your Instance → Security → Security Groups → Inbound Rules. Port `80` must be open. **This is the most common cause of external inaccessibility when everything else looks fine.**

**7. Host firewall (if still blocked)**
```bash
sudo ufw status
sudo ufw allow 80/tcp   # if ufw is active
sudo iptables -L -n | grep -E '80|8080'
```

---

## Common Mistakes

### ⚠️ YAML nesting error
The `traefik` service must be at the top level of the `services` block — **not nested inside `keycloak`'s `environment` section**. YAML indentation errors are silent. Validate with:
```bash
docker compose config
```

### ⚠️ Applying env changes with `restart`
`docker compose restart` does **not** re-read environment variables. After any change to the compose file:
```bash
docker compose down && docker compose up -d
```

### ⚠️ Exposing port 8080 directly
Using `ports: "8080:8080"` on the Keycloak service lets anyone bypass Traefik entirely. Use `expose` instead — it makes the port available only on the internal Docker network.

### ⚠️ `Host()` rule with raw IP
`Host(`<ip>`)` can fail to match when accessing via a raw EC2 IP. Use `PathPrefix(`/`)` as a catch-all, or point a real domain at the instance and use `Host(`yourdomain.com`)`.

---

## Production Notes

> ⚠️ `start-dev` disables many Keycloak security hardening features. For production, use `start` with `KC_HOSTNAME` set to your real domain and TLS configured at the Traefik level with Let's Encrypt.

- Change the default `admin` / `admin` credentials before exposing to the internet
- Use a strong `KC_DB_PASSWORD` — the example value is for local testing only
- Restrict the Traefik dashboard (port `8081`) to your IP only in the security group
- Add HTTPS via [Traefik Let's Encrypt integration](https://doc.traefik.io/traefik/https/acme/) for production
- Monitor memory — Keycloak under load needs more than the 2 GB minimum