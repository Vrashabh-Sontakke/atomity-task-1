# Keycloak on EC2 with Traefik

> This doc is generated with the help of AI but verified by me from real debugging experience. No fluff.

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
      KC_HOSTNAME: "<keycloak-ec2-public-ip>"   # Must match what the browser sees
      KC_HOSTNAME_STRICT: "false"
      KC_HOSTNAME_STRICT_HTTPS: "false"
      KC_PROXY: edge              # Critical: trust X-Forwarded headers from Traefik
      KC_HEALTH_ENABLED: "true"
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.keycloak.rule=PathPrefix(`/`)"   # Use PathPrefix, not Host() with raw IPs
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
| `KC_HOSTNAME` | Sets the public-facing hostname. **Without this, Keycloak uses its internal/private IP in OIDC discovery endpoints — browsers can't reach those URLs.** |
| `KC_HTTP_ENABLED: true` | Allows Keycloak to accept HTTP internally. Required when Traefik is terminating TLS. |
| `KC_HOSTNAME_STRICT: false` | Stops Keycloak from rejecting requests that don't match a configured hostname. |
| `KC_HOSTNAME_STRICT_HTTPS: false` | Stops Keycloak from forcing HTTPS redirects. |

> ℹ️ **`Host()` rule vs `PathPrefix()` with raw IPs**: Traefik's `Host(`your-ip`)` rule can fail with raw EC2 IPs. Use `PathPrefix(`/`)` as a catch-all. Switch to `Host(`yourdomain.com`)` if you have a domain.

---

## EC2 Security Group

| Type | Port | Source | Notes |
|---|---|---|---|
| HTTP | 80 | 0.0.0.0/0 | Keycloak via Traefik |
| Custom TCP | 8081 | Your IP only | Traefik dashboard |
| ~~Custom TCP~~ | ~~8080~~ | ~~BLOCK~~ | Do not expose directly |

> ⚠️ **Port 80 is the most commonly missed rule.** The Traefik dashboard on 8081 may work while Keycloak on 80 is silently blocked by the security group.

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
| Keycloak Admin | `http://<keycloak-public-ip>/admin` |
| Traefik Dashboard | `http://<keycloak-public-ip>:8081` |
| Default credentials | `admin` / `admin` |

---

## Setting Up a Realm and Client (for OIDC integrations)

### 1. Create the Realm

1. Open `/admin` and log in
2. Top-left dropdown → **Create Realm**
3. Set **Realm name** (e.g. `wireguard`) → **Create**

### 2. Create the Client

1. Left sidebar → **Clients** → **Create client**
2. **Client type**: `OpenID Connect`, **Client ID**: your app name (e.g. `wg-portal`)
3. **Next** → Capability config:
   - **Client authentication**: `ON` (required for client secret)
   - **Standard flow**: `ON`
4. **Next** → Login settings:
   - **Valid redirect URIs**: `http://<your-app-public-ip>:<port>/*`
   - **Web origins**: `http://<your-app-public-ip>:<port>`
5. **Save**
6. Go to **Credentials** tab → copy the **Client secret**

> ⚠️ **Double-check the redirect URI carefully.** A single character typo (e.g. `3.127.x.x` vs `13.127.x.x`) causes Keycloak to reject the login with `Invalid parameter: redirect_uri`.

### 3. Create Users

1. Left sidebar → **Users** → **Create new user**
2. Fill **Username**, **Email**, **First name**, **Last name**
3. **Email verified**: `ON`
4. **Create** → **Credentials** tab → **Set password** → **Temporary**: `OFF`

---

## Verifying OIDC Discovery

After setting `KC_HOSTNAME`, verify all endpoints advertise the public IP:

```bash
curl -s http://localhost/realms/<realm>/.well-known/openid-configuration \
  | python3 -m json.tool | grep issuer
# Should show: "issuer": "http://<public-ip>/realms/<realm>"
```

If the issuer still shows a private IP, `KC_HOSTNAME` wasn't picked up — run `docker compose down && docker compose up -d`.

---

## Debugging Checklist

**1. Are all containers running?**
```bash
docker compose ps
```

**2. Is Keycloak fully started?**
```bash
docker compose logs keycloak --tail=50
# Look for: Listening on: http://0.0.0.0:8080
```

**3. Can Traefik reach Keycloak?**
```bash
docker exec traefik wget -qO- http://keycloak:8080
```

**4. Is Keycloak reachable from the host?**
```bash
curl -v http://localhost
```

**5. Is Traefik routing configured?**

Open `http://<ec2-ip>:8081` → HTTP → Routers. The `keycloak` router should show as green/matched.

**6. Check the EC2 security group**

Port `80` inbound must be open. This is the most common cause of external inaccessibility when everything else looks fine.

**7. Host firewall**
```bash
sudo ufw status
sudo ufw allow 80/tcp
```

---

## Common Mistakes

### ⚠️ YAML nesting error
The `traefik` service must be at the top level of `services` — not nested inside `keycloak`'s `environment` block. Validate with:
```bash
docker compose config
```

### ⚠️ `KC_HOSTNAME` not set
Without it, Keycloak uses its internal/private IP as the issuer. OIDC clients get redirected to a private IP the browser can't reach — the login just spins forever.

### ⚠️ Applying env changes with `restart`
`docker compose restart` does **not** re-read environment variables:
```bash
docker compose down && docker compose up -d
```

### ⚠️ Exposing port 8080 directly
Use `expose` not `ports` for Keycloak — `ports` lets anyone bypass Traefik entirely.

### ⚠️ `Host()` rule with raw IP
Use `PathPrefix(`/`)` instead of `Host(`<ip>`)` when working with raw EC2 IPs.

---

## Production Notes

> ⚠️ `start-dev` disables many security hardening features. For production, use `start` with a real domain and TLS via Traefik Let's Encrypt.

- Change default `admin` / `admin` credentials immediately
- Use a strong `KC_DB_PASSWORD`
- Restrict Traefik dashboard (port `8081`) to your IP only
- Add HTTPS via [Traefik Let's Encrypt](https://doc.traefik.io/traefik/https/acme/)
- Monitor memory — Keycloak under load needs more than the 2 GB minimum