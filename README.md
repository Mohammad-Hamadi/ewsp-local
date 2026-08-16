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

The Docker build contexts are `../ewsp-backend` and `../ewsp-dashboard`. The Dockerfiles remain in this repository. Dockerfile-specific ignore files prevent Git metadata, existing build output, dependencies, logs, and IDE files from entering those build contexts without modifying the source repositories. The dashboard also receives this small repository as a named BuildKit context so its Nginx configuration can be copied into the image; the root `.dockerignore` excludes local Git and environment data from that context.

## Prerequisites

- Windows PowerShell 5.1 or newer
- Git
- Docker Desktop or another Docker engine with Docker Compose support
- Available host ports 3000, 5432, 6379, 8080, 9000, and 9001, unless overridden in `.env`

Java, Maven, Node, and Nginx do not need to be installed on the host for the container workflow.

## Primary workflow

From `ewsp-local`, prepare the sibling workspace and local configuration:

```powershell
.\ewsp.ps1 setup
```

`setup` verifies PowerShell, Git, Docker, and Docker Compose. It reuses correctly configured sibling repositories, clones only missing repositories, refuses to overwrite an unexpected directory, and creates `.env` from `.env.example` only when `.env` is absent. It does not update repositories or build images.

Start EWSP:

```powershell
.\ewsp.ps1 start
```

`start` verifies repository identities without updating Git, resolves source-and-recipe-aware application image tags, builds only the images that are required, starts Compose, waits for all five services to become healthy, and prints the configured local URLs. Infrastructure images are not proactively pulled; Docker obtains one only when it is missing.

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

Clean backend and dashboard images are tagged from the source commit plus a hash of the relevant Docker recipe and build-time inputs. An existing matching clean image is reused. A dirty source repository receives a session-specific `dirty-...` tag and is never falsely represented as its clean commit.

Each `start` with dirty backend or dashboard source intentionally creates a new session tag and rebuilds that application image. These tags are not deleted automatically, so old dirty images can accumulate in the local Docker image store. Review and remove them manually with normal Docker image tooling when disk maintenance is needed; the orchestration script never guesses which developer images are safe to delete.

The backend image uses the repository Maven wrapper and runs `clean package -DskipTests`. Skipping tests keeps routine image builds practical; it does not replace the backend repository's normal automated test workflow.

The dashboard image uses `npm ci`, creates the Vite production build, and serves it with Nginx. Nginx returns `index.html` for client-side application routes while retaining strict handling for real assets.

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

The PowerShell entry point is the normal workflow because it resolves application image tags safely. Direct `docker compose` commands remain useful for logs and troubleshooting, but a direct build/start uses the fallback `ewsp-backend:local` and `ewsp-dashboard:local` tags rather than the source-aware tags selected by `ewsp.ps1`.

Common failures:

- If setup or start says Docker Desktop is unavailable, start the Docker engine and retry.
- If setup refuses an existing sibling directory, inspect its Git remote and move or rename it yourself; setup never overwrites an unexpected directory.
- Dirty, ahead, diverged, detached, wrong-branch, missing-upstream, fetch-failed, and unexpected-upstream repositories are reported without automatic Git changes. Resolve them explicitly in the source repository, then rerun `update`.
- A host-port conflict requires changing the corresponding value in `.env`. When changing the backend port, also set the browser-reachable `VITE_API_BASE_URL` and the matching `EWSP_CORS_ALLOWED_ORIGINS` value before starting.
- Use `docker compose logs <service>` for a failed health check. `docker compose down` preserves data; do not add `-v` unless deleting this project's PostgreSQL and MinIO data is intentional.
