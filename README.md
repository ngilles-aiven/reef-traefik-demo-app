# reef-traefik-demo-app

A tiny demo container that runs **both**:

1. the exact `whoami` binary from the [`traefik/whoami`](https://github.com/traefik/whoami) image, and
2. its **own** Traefik instance reverse-proxying to it,

so you can reconfigure Traefik freely for demos without touching an external proxy.

```
             :8080 (host)                 :8081 (host)
                │                              │
        ┌───────▼──────────────────────────────▼───────┐
        │  container                                    │
        │   Traefik  :80 (web) ──▶ whoami 127.0.0.1:8000│
        │            :8080 (dashboard/API)              │
        └───────────────────────────────────────────────┘
```

## Run

```sh
make up        # build + start in the background
make logs      # follow logs
make down      # stop
```

Then:

- **whoami through Traefik:** http://localhost:8080/
- **Traefik dashboard:** http://localhost:8081/dashboard/

A request to `:8080` that comes back with `X-Forwarded-*` headers confirms it
traversed Traefik rather than hitting whoami directly:

```sh
curl -s localhost:8080/ | grep -i x-forwarded
```

## Authentication (OIDC)

Traefik can enforce OIDC login in front of whoami using the
[`lukaszraczylo/traefikoidc`](https://github.com/lukaszraczylo/traefikoidc)
plugin (declared in `traefik/traefik.yml`). Config comes from environment
variables and is rendered into Traefik's dynamic config at container startup by
`entrypoint.sh`.

```sh
cp env.example .env
# edit .env: set REEF_ISSUER, REEF_CLIENT_ID, REEF_CLIENT_SECRET
make up
```

**Register the callback** with reef as a redirect URI: `http://localhost:8080/oauth2/callback`.

Now unauthenticated requests are challenged:

```sh
curl -sI localhost:8080/          # 302 -> ${REEF_ISSUER}/authorize...
```

Open http://localhost:8080/ in a browser → reef login → back to whoami.

To demo the contrast, set `OIDC_ENABLED=false` in `.env` and `make up` again —
whoami is served directly (200, no redirect).

### Environment variables

Set in `.env` (see `env.example`); passed through by `docker-compose.yml`.

| Var | Default | Meaning |
|-----|---------|---------|
| `OIDC_ENABLED` | `true` | `false` serves whoami with no auth. |
| `REEF_ISSUER` | — | OIDC issuer URL (discovery at `…/.well-known/openid-configuration`). **Required when enabled.** |
| `REEF_CLIENT_ID` | — | OAuth client id from reef. **Required when enabled.** |
| `REEF_CLIENT_SECRET` | — | OAuth client secret from reef. **Required when enabled.** |
| `OIDC_CALLBACK_URL` | `/oauth2/callback` | Callback path Traefik handles (register the full URL with reef). |
| `OIDC_LOGOUT_URL` | `/oauth2/logout` | RP-initiated logout path. |
| `OIDC_FORCE_HTTPS` | `false` | Keep `false` for the local http:// demo. |
| `OIDC_LOG_LEVEL` | `info` | `debug` / `info` / `error`. |
| `OIDC_SCOPES` | `openid,profile,email` | Comma-separated OAuth scopes. |
| `OIDC_EXCLUDED_URLS` | — | Comma-separated paths that bypass auth. |
| `OIDC_SESSION_ENCRYPTION_KEY` | auto | Cookie key (≥32 bytes). Blank ⇒ generated once and persisted to the `oidc-session-key` volume so it survives restarts. |
| `REDIS_ENABLED` | `true`¹ | Store OIDC sessions/cache in Redis (shared across replicas, survive restarts) instead of in-memory. |
| `REDIS_ADDRESS` | `redis:6379`¹ | Redis server as `host:port`. **Required when `REDIS_ENABLED=true`.** |
| `REDIS_PASSWORD` | — | Redis auth password (blank if none). |
| `REDIS_DB` | `0` | Redis logical database number (0–15). |
| `REDIS_CACHE_MODE` | `hybrid` | `memory` / `redis` / `hybrid` (hybrid = local L1 + Redis L2). |
| `WHOAMI_PORT` | `8000` | Internal port whoami listens on. |
| `WHOAMI_NAME` | `reef-traefik-demo` | Name whoami reports. |

¹ These are the `docker-compose.yml` defaults (the bundled `redis` service).
The `entrypoint.sh` fallback is `REDIS_ENABLED=false` — i.e. Redis is opt-in
when you run the image without compose.

### Shared sessions (Redis)

By default `docker compose up` now starts a `redis` service and the OIDC plugin
stores its session/cache state there rather than in process memory. This means
sessions survive an app restart and can be shared across multiple app replicas
(and it's what the plugin recommends for IdP-initiated / multi-replica logout).

Redis data is persisted to the `redis-data` volume (append-only file); it's
wiped by `docker compose down -v`. To go back to in-memory sessions set
`REDIS_ENABLED=false` in `.env`. To point at an external Redis instead of the
bundled one, set `REDIS_ADDRESS` (and `REDIS_PASSWORD` if needed).

### Gotchas

- **Plugin download:** on first start Traefik fetches the plugin source from
  GitHub — the container needs network egress.
- **`OIDC_FORCE_HTTPS` must be `false`** for the plain-http local demo, or the
  plugin builds `https://` redirect/callback URLs that won't resolve.
- **Issuer reachability:** the browser *and* the container must reach
  `REEF_ISSUER` at the **same** URL (the token `iss` must match). If reef runs on
  your host, use `http://host.docker.internal:<port>` and set reef's issuer to
  match — plain `localhost` means different things inside vs outside the container.
- **"Critical session error" (HTTP 500):** the plugin can't decode a session
  cookie because the session key changed since the cookie was set, and it won't
  clear the bad cookie itself. To recover: **clear cookies for `localhost:8080`**
  (or use a fresh/incognito window), then reload. The key is now persisted across
  restarts (`oidc-session-key` volume) so this shouldn't recur; if you rotate it
  deliberately (change `OIDC_SESSION_ENCRYPTION_KEY`, or `docker compose down -v`),
  clear cookies again.

## Configure Traefik

- **Static** config lives in `traefik/traefik.yml` (entrypoints, dashboard, the
  plugin declaration). It's bind-mounted; edits apply after `make restart`.
- **Dynamic** config (router + service + OIDC middleware) is **generated at
  startup** by `entrypoint.sh` from the environment, so change behaviour via
  `.env` and re-run `make up`. To alter the routing structure itself, edit the
  heredoc in `entrypoint.sh`.

## How it works

`entrypoint.sh` renders `/etc/traefik/dynamic/dynamic.yml` from the environment,
starts `whoami` in the background, then `exec`s Traefik in the foreground (so
Traefik is PID 1 and shuts down cleanly on `docker stop`). The image is built by
copying the `whoami` binary onto the official `traefik` base image — see
`Dockerfile`.
