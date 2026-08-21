# EWSP Local Environment

`ewsp-local` provides the reproducible Docker Compose environment used for EWSP local and integration testing. It orchestrates the backend, dashboard, PostgreSQL, Redis, and MinIO while leaving the application source repositories independent.

This topology is for local development and integration testing. It is not the EWSP production deployment design.

## Workspace layout

Keep the repositories as siblings:

```text
EWSP/
|-- ewsp-local/
|-- ewsp-backend/
|-- ewsp-dashboard/
`-- ewsp-mobile/
```

The Docker build contexts are `../ewsp-backend` and `../ewsp-dashboard`. Each application repository owns its image construction: `ewsp-backend` owns its `Dockerfile` and `.dockerignore`, while `ewsp-dashboard` owns its `Dockerfile`, `.dockerignore`, and Nginx configuration. This repository owns workspace bootstrap, environment configuration, infrastructure, networking, volumes, runtime configuration, health coordination, and multi-service Docker Compose orchestration.

## Prerequisites

- Windows PowerShell 5.1 or PowerShell 7+
- Git
- Docker Desktop or another Docker engine with Docker Compose support
- Available host ports 3000, 5432, 6379, 8080, 9000, and 9001, unless overridden in `.env`

Java, Maven, Node, and Nginx do not need to be installed on the host for the container workflow.

Windows with Docker Desktop is the currently tested and guaranteed platform. The PowerShell orchestration detects Windows, Linux, and macOS plus OS, architecture, shell, Git, Docker CLI, Docker Engine, and Compose versions, but Linux and macOS are not yet claimed as tested support. The detector probes actual command capabilities: it selects `docker compose` when that command succeeds, otherwise tries `docker-compose`, and then uses that one selection for the complete command. It does not install major prerequisites automatically.

## Primary workflow

For a fresh or normal safely updateable workspace, clone this repository and run:

```powershell
.\ewsp.ps1 up
```

`up` performs a phased environment detection, sibling repository setup, safe repository update, local configuration, build and port preflight, application image build/reuse, Compose startup, five-service readiness wait, endpoint verification, and final status summary. On success the sibling repositories remain ordinary editable Git working trees.

Repository safety is unchanged. Missing repositories are cloned. A correct clean `main` checkout that is only behind its verified upstream may be fast-forwarded. Dirty, detached, wrong-branch, ahead, diverged, missing-upstream, fetch-failed, and unexpected-upstream states are preserved. If such a checkout already contains the required Docker assets, `up` reports the skipped update and continues safely; if an old checkout lacks a required application-owned Docker asset, `up` stops with remediation instead of resetting or replacing developer work.

`.env` is created from `.env.example` only when absent and is otherwise preserved. Required setting names, URLs, Compose configuration, application Docker assets, sibling paths, and all configured host ports are checked before image or service startup. Secret values are not printed. Ports already published by this EWSP Compose project are accepted, while an external listener on a required port is reported without stopping it.

Failures identify the phase, category, component, sanitized operation, exit code when available, detected tool versions, completed phases, skipped phases, reason, and a safe next action. Readiness failures show every service state and at most 40 recent log lines for up to three non-ready services.

Docker Desktop or another configured Docker Engine must already be running. If the CLI exists but its server is unreachable, `up` reports that state distinctly.

## Advanced commands

The individual commands remain available when you want explicit control:

```powershell
.\ewsp.ps1 setup
.\ewsp.ps1 update
.\ewsp.ps1 start
.\ewsp.ps1 status
.\ewsp.ps1 stop
```

`setup` verifies prerequisites, reuses correctly configured sibling repositories, clones only missing repositories, refuses unexpected directories, and creates `.env` when absent. It does not update repositories or build images.

`update` applies only the safe fast-forward behavior described above.

`start` verifies repository identities and required application-owned Docker assets without updating Git, resolves source-and-build-input-aware application image tags, builds only required images, starts Compose, waits for all five services, and prints URLs. If an older sibling checkout lacks its Dockerfile, `start` never falls back to an orchestration-owned recipe. Infrastructure images are obtained by Docker only when needed.

Inspect repository and Docker state:

```powershell
.\ewsp.ps1 status
```

`status` fetches remote Git metadata when possible and reports identity, branch, short commit, dirty state, ahead/behind counts, classifications, `.env` presence, and concise container health.

Safely update source repositories:

```powershell
.\ewsp.ps1 update
```

`update` fetches metadata and automatically updates only a correct, clean repository on its expected branch that is behind its upstream and neither ahead nor diverged. The update uses `git merge --ff-only`. Dirty, ahead, diverged, detached, wrong-branch, missing-upstream, missing, and identity-mismatch states are reported and left untouched.

Stop the stack while preserving data:

```powershell
.\ewsp.ps1 stop
```

Run `.\ewsp.ps1 help` for a compact command summary.

## Environment configuration

The checked-in `.env.example` contains local-only placeholder credentials. Change them when appropriate, especially on a shared machine. `.env` is ignored and must never be committed. Re-running `setup` preserves an existing `.env`.

If `BACKEND_HOST_PORT` changes, update `VITE_API_BASE_URL` to the browser-reachable backend URL before building the dashboard. `VITE_API_BASE_URL` is a Vite build-time value; changing it requires rebuilding the dashboard image.

## Image identity and builds

Clean backend and dashboard images are tagged from the application source commit plus a hash of orchestration-supplied build-time inputs. The application commit already identifies its tracked Dockerfile, `.dockerignore`, and, for the dashboard, Nginx configuration. `VITE_API_BASE_URL` remains part of dashboard image identity because Vite embeds it in generated output. An existing matching clean image is reused. A dirty source repository receives a session-specific `dirty-...` tag and is never falsely represented as its clean commit.

Each `start` with dirty backend or dashboard source intentionally creates a new session tag and rebuilds that application image. These tags are not deleted automatically, so old dirty images can accumulate in the local Docker image store. Review and remove them manually with normal Docker image tooling when disk maintenance is needed; the orchestration script never guesses which developer images are safe to delete.

The backend repository's Dockerfile uses its Maven wrapper and produces the runtime image. Its image build skips tests to keep routine builds practical; this does not replace the backend repository's normal automated test workflow.

The dashboard repository's Dockerfile uses `npm ci`, creates the Vite production build, and serves it with its own Nginx configuration. Nginx returns `index.html` for client-side application routes while retaining strict handling for real assets.

## Local URLs

| Service | URL |
|---|---|
| Dashboard | http://localhost:3000 |
| Backend health | http://localhost:8080/api/health |
| Swagger UI | http://localhost:8080/swagger-ui/index.html |
| OpenAPI | http://localhost:8080/v3/api-docs |
| MinIO API | http://localhost:9000 |
| MinIO console | http://localhost:9001 |

PostgreSQL and Redis are exposed on ports 5432 and 6379 by default.

## Networking and readiness

Compose creates one project-scoped default network. The backend connects to `postgres`, `redis`, and `minio` through Compose DNS. Browser dashboard requests use `VITE_API_BASE_URL`, normally `http://localhost:8080`; the Compose-only hostname `backend` is intentionally not embedded in the browser application.

PostgreSQL, Redis, and MinIO have health checks. Backend startup waits for all three to become healthy. The backend itself is checked through its public `/api/health` endpoint, and dashboard startup waits for that check.

## Stop and persistence

```powershell
.\ewsp.ps1 stop
```

PostgreSQL and MinIO use project-scoped named volumes and survive an ordinary `docker compose down` followed by `docker compose up -d`. Redis persistence is intentionally disabled and its image-declared `/data` path is replaced with tmpfs, so Redis does not leave anonymous data volumes behind. Do not use `docker compose down -v` unless you intend to delete this local project's PostgreSQL and MinIO data.

The project name defaults to `ewsp-local`, so these resources do not reuse the older backend repository's Compose volumes or containers.

## Flutter mobile app

Flutter is not containerized. Run `ewsp-mobile` on an emulator or device. Its default Android emulator API base is:

```text
http://10.0.2.2:8080/api
```

For another host address, run Flutter with:

```text
--dart-define=EWSP_API_BASE_URL=<URL>
```

For a physical device, replace the emulator-only `10.0.2.2` address with the development computer's LAN address, keep the `/api` suffix, and ensure the host firewall and Wi-Fi network allow the device to reach the configured backend port. For example: `flutter run --dart-define=EWSP_API_BASE_URL=http://192.168.1.20:8080/api`.

The current mobile repository targets modern Android versions, which may block cleartext HTTP unless its Android development network-security policy explicitly permits it. If the emulator or device reports a cleartext-policy error, that policy must be addressed in `ewsp-mobile`; this orchestration repository deliberately does not modify the mobile application. Flutter remains outside Compose because emulator/device selection, hot reload, signing, and platform tooling belong to the mobile development workflow.

## Direct Compose troubleshooting

The PowerShell entry point is the normal workflow because it resolves application image tags and the supported Compose invocation safely. `up` prints whether it selected `docker compose` or `docker-compose`. Direct commands remain useful for logs and troubleshooting; pass `-f compose.yml` explicitly for portability between implementations. A direct build/start uses the fallback `ewsp-backend:local` and `ewsp-dashboard:local` tags rather than the source-aware tags selected by `ewsp.ps1`.

Common failures:

- If `up`, `setup`, or `start` reports that the Docker CLI exists but its Engine is unreachable, start Docker Desktop/Engine and retry.
- If setup refuses an existing sibling directory, inspect its Git remote and move or rename it yourself; setup never overwrites an unexpected directory.
- Dirty, ahead, diverged, detached, wrong-branch, missing-upstream, fetch-failed, and unexpected-upstream repositories are reported without automatic Git changes. Resolve them explicitly in the source repository, then rerun `update`.
- An external host-port conflict requires stopping/reconfiguring that listener or changing the corresponding value in `.env`. When changing the backend port, also set the browser-reachable `VITE_API_BASE_URL` and matching `EWSP_CORS_ALLOWED_ORIGINS` before starting. The script never kills the listener.
- Readiness failures automatically show bounded logs. For more detail, use the Compose invocation printed by `up`, add `-f compose.yml`, and run `logs <service>`. Ordinary Compose shutdown preserves data; do not add `-v` unless deleting this project's PostgreSQL and MinIO data is intentional.
