# EWSP Local Environment

`ewsp-local` provides the reproducible Docker Compose environment used for EWSP local and integration testing, together with the published Kubernetes deployment baseline under `k8s/`. It orchestrates the backend, dashboard, PostgreSQL, Redis, and MinIO while leaving the application source repositories independent.

This topology is for local development and integration testing. It is not the EWSP production deployment design.

New here? The quickest way to discover the CLI is:

```powershell
.\ewsp.ps1 help
```

The built-in help covers commands, categories, search, and common workflows without requiring Docker, Kubernetes, `.env`, or any sibling repository. This README remains the detailed architecture and operational reference.

## Workspace layout

Keep the repositories as siblings:

```text
EWSP/
|-- ewsp-local/
|-- ewsp-backend/
|-- ewsp-dashboard/
`-- ewsp-mobile/
```

The Docker build contexts are `../ewsp-backend` and `../ewsp-dashboard`. Each application repository owns its image construction: `ewsp-backend` owns its `Dockerfile` and `.dockerignore`, while `ewsp-dashboard` owns its `Dockerfile`, `.dockerignore`, and Nginx configuration. This repository does not own application Dockerfiles. It owns sibling-workspace bootstrap and safe repository setup/update, environment configuration, infrastructure, networking, volumes, runtime configuration, application image identity/reuse coordination, health/status diagnostics, multi-service Docker Compose orchestration, and the Kubernetes manifests under `k8s/`.

## Prerequisites

- Windows PowerShell 5.1 or PowerShell 7+
- Git
- Docker Desktop or another Docker engine with Docker Compose support
- Available host ports 3000, 5432, 6379, 8080, 9000, and 9001, unless overridden in `.env`
- For the Kubernetes baseline, `kubectl` and Docker Desktop Kubernetes; the verified target is Docker Desktop kind Kubernetes

Java, Maven, Node, and Nginx do not need to be installed on the host for the container workflow.

Windows with Docker Desktop is the currently tested and guaranteed platform. The PowerShell orchestration detects Windows, Linux, and macOS plus OS, architecture, shell, Git, Docker CLI, Docker Engine, and Compose versions, but Linux and macOS are not yet claimed as tested support. The detector probes actual command capabilities: it selects `docker compose` when that command succeeds, otherwise tries `docker-compose`, and then uses that one selection for the complete command. It does not install major prerequisites automatically.

## Primary workflow

For a fresh or normal safely updateable workspace, clone this repository and run:

```powershell
.\ewsp.ps1 up
```

`up` performs a phased environment detection, sibling repository setup, safe repository update, local configuration, build and port preflight, application image build/reuse, Compose startup, five-service readiness wait, endpoint verification, and final status summary. On success the sibling repositories remain ordinary editable Git working trees.

Repository safety is unchanged. Missing repositories are cloned. A correct clean `main` checkout that is only behind its verified upstream may be fast-forwarded. Dirty, detached, wrong-branch, ahead, diverged, missing-upstream, fetch-failed, and unexpected-upstream states are preserved. If such a checkout already contains the required Docker assets, `up` reports the skipped update and continues safely; if an old checkout lacks a required application-owned Docker asset, `up` stops with remediation instead of resetting or replacing developer work.

`.env` is created from `.env.example` only when absent and is otherwise preserved. Required setting names, Compose configuration, application Docker assets, sibling paths, and all configured host ports are checked before image or service startup. Secret values are not printed. Ports already published by this EWSP Compose project are accepted, while an external listener on a required port is reported without stopping it.

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

Run `.\ewsp.ps1 help` for command discovery, searchable topics, and workflow guides.

## Environment configuration

The checked-in `.env.example` contains local-only placeholder credentials. Change them when appropriate, especially on a shared machine. `.env` is ignored and must never be committed. Re-running `setup` preserves an existing `.env`.

The dashboard uses same-origin API and WebSocket paths. Its image does not accept or embed backend URLs, so changing `BACKEND_HOST_PORT` does not require rebuilding the dashboard. The backend host port remains available for direct development, Swagger, OpenAPI, mobile, and debugging access.

## Image identity and builds

The image flows are intentionally separate:

- CI: application source -> tests -> private GHCR image tagged with the full Git SHA.
- Kubernetes: configured immutable GHCR SHA image -> `ghcr-pull` -> Pod.
- Compose: sibling application source -> repository-owned Dockerfile -> local image -> local container.

Clean backend and dashboard images are tagged from the application source commit plus a hash of any orchestration-supplied build-time inputs. Neither application currently has such an input, so API and WebSocket URLs do not affect dashboard image identity. The dashboard application commit identifies its tracked Dockerfile, `.dockerignore`, and Nginx proxy configuration. An existing matching clean image is reused. A dirty source repository receives a session-specific `dirty-...` tag and is never falsely represented as its clean commit.

Each `start` with dirty backend or dashboard source intentionally creates a new session tag and rebuilds that application image. These tags are not deleted automatically, so old dirty images can accumulate in the local Docker image store. Review and remove them manually with normal Docker image tooling when disk maintenance is needed; the orchestration script never guesses which developer images are safe to delete.

The backend repository's Dockerfile uses its Maven wrapper and produces the runtime image. Its image build skips tests to keep routine builds practical; this does not replace the backend repository's normal automated test workflow.

The dashboard repository's Dockerfile uses `npm ci`, creates the Vite production build, and serves it with its own Nginx configuration. Nginx returns `index.html` for client-side application routes, retains strict handling for real assets, proxies same-origin `/api` requests to `http://backend:8080`, and upgrades `/ws` connections to the backend WebSocket endpoint.

## Local URLs

| Service | URL |
|---|---|
| Dashboard | http://localhost:3000 |
| Dashboard-proxied backend health | http://localhost:3000/api/health |
| Backend health | http://localhost:8080/api/health |
| Swagger UI | http://localhost:8080/swagger-ui/index.html |
| OpenAPI | http://localhost:8080/v3/api-docs |
| MinIO API | http://localhost:9000 |
| MinIO console | http://localhost:9001 |

PostgreSQL and Redis are exposed on ports 5432 and 6379 by default.

## Networking and readiness

Compose creates one project-scoped default network shared by dashboard and backend. The backend connects to `postgres`, `redis`, and `minio` through Compose DNS. Browser dashboard requests remain on the dashboard origin; dashboard Nginx resolves the Compose service name `backend` and forwards `/api` and `/ws` internally to port 8080. The host-published backend port is not required for dashboard operation and remains available for direct development and debugging.

PostgreSQL, Redis, and MinIO have health checks. Backend startup waits for all three to become healthy. The backend itself is checked through its public `/api/health` endpoint, and dashboard startup waits for that check.

## Kubernetes deployment baseline

Docker Compose remains the convenient local development and full-stack path driven by `.\ewsp.ps1 up` and the advanced commands above. The published plain Kubernetes manifests live under `k8s/`, use the `ewsp` namespace, and now have a separate safe local lifecycle:

```powershell
.\ewsp.ps1 k8s-up
.\ewsp.ps1 k8s-status
.\ewsp.ps1 k8s-stop
```

`k8s-up` requires Docker Desktop Kubernetes, refuses any context other than `docker-desktop`, verifies the single Ready Docker Desktop kind node and default local-path StorageClass, and reconciles resources without deleting persistent data. It applies resources in dependency order, waits for infrastructure before applications, verifies all five workloads and their internal DNS/service contracts, then starts or reuses an EWSP-managed dashboard port-forward. Browser access is through `http://localhost:3000`; dashboard Nginx keeps `/api` and `/ws` on that same origin and forwards them to `backend:8080`. If port 3000 belongs to an external process, Kubernetes startup reports the conflict and does not stop that process.

Kubernetes never builds the backend or dashboard locally. It requires `EWSP_BACKEND_IMAGE` and `EWSP_DASHBOARD_IMAGE` in ignored `.env`; each must use its expected `ghcr.io/mohammad-hamadi/...` repository and a full 40-character Git SHA tag. `main`, `latest`, malformed refs, and wrong repositories are refused rather than rewritten. Checked-in placeholders remain environment-independent while the exact refs are rendered under ignored `.tmp/k8s/rendered/` files with `imagePullPolicy: IfNotPresent`.

Both GHCR packages are private. Put `GHCR_USERNAME` and `GHCR_TOKEN` directly in ignored `.env`; the token needs package-read permission only and does not need repository write permission. Never use a GitHub Actions `GITHUB_TOKEN` locally or paste the token into chat. `k8s-up` creates/reconciles the `kubernetes.io/dockerconfigjson` Secret `ghcr-pull`, applies it without printing values, and removes its ACL-restricted ignored temporary artifact. The backend and dashboard Pod specs reference that Secret through `imagePullSecrets`.

`k8s-up` therefore does not require the backend or dashboard sibling checkout merely to deploy. Repository discovery remains part of Compose/setup/update/status. `k8s-seed` intentionally still requires the sibling backend repository for its ignored local seed SQL file.

The real `ewsp-infrastructure-secrets` Secret is generated from the current ignored `.env`, applied without displaying its values, and its temporary ignored file is removed after application. `k8s/config/secrets.example.yaml` remains placeholder-only and is never applied by the command.

The baseline contains:

- PostgreSQL as a one-replica StatefulSet with a 5 Gi PVC.
- Redis as a one-replica Deployment with ephemeral memory-backed storage and no PVC.
- MinIO as a one-replica StatefulSet with a 10 Gi PVC.
- The backend and dashboard as one-replica Deployments with no PVCs.

All five Services are internal `ClusterIP` Services. Only the managed dashboard port-forward occupies a Windows port; backend, PostgreSQL, Redis, and MinIO are not exposed by the Kubernetes workflow.

### Explicit local Kubernetes user seed

Kubernetes PostgreSQL starts with its own PVC. Flyway applies the database schema and required lookup rows automatically, but no demo or local dashboard users are created automatically. Local user seeding is always an explicit operation:

```powershell
.\ewsp.ps1 k8s-seed
```

`k8s-seed` is local-development/demo tooling restricted permanently to the exact `docker-desktop` context and `ewsp` namespace. It requires the existing sibling `ewsp-backend/local-dev/seed-dashboard-users.sql` file to be present, untracked, and ignored through the backend repository's local Git exclusions. The command streams that file directly to `psql` in the Ready `postgres-0` Pod with SQL error stopping enabled; it does not copy SQL into a Pod, ConfigMap, Secret, image, or tracked manifest. Output contains only safe user counts and identity/role/status/verification fields. It creates missing seed-defined users with `ON CONFLICT DO NOTHING`; rerunning it deliberately does not overwrite any existing user.

If the persistent local database contains an older password hash for the seeded admin, reconcile that one credential explicitly:

```powershell
.\ewsp.ps1 k8s-reset-admin
```

`k8s-reset-admin` is local/demo recovery tooling, not production password management. It has no force bypass: it requires the exact Docker Desktop context, namespace `ewsp`, a Ready PostgreSQL StatefulSet/Pod and Bound PVC, and the same untracked ignored backend seed file. It verifies the one existing active, verified ADMIN employee and expected local user counts, updates only `password_hash` in a transaction, verifies UUID/state/count preservation and seed-hash equality without displaying hashes, then proves the credential through the running application. Those real logins create the backend's normal login audit/session records, but returned tokens are discarded without being printed or persisted by the CLI. The command never deletes or reinserts the user and never deletes storage. Invocation is always explicit; neither `k8s-up` nor `k8s-seed` performs this reconciliation.

The existing seed is idempotent and uses `ON CONFLICT DO NOTHING`, so rerunning the command adds missing local identities without duplicates. It does not reset passwords or overwrite any other existing user row in a preserved PostgreSQL PVC. Persisted users can therefore retain credentials or other values that differ from the current ignored seed file. The seed is not invoked by `k8s-up` or `tunnel-quick`, has no context override, and must never be converted into a production Flyway migration. Production deployments must provision real employee accounts through an explicitly controlled operational process and must not receive local/demo users or credentials.

`k8s-status` reports configured and running image refs, Pod image IDs/digests, agreement, controllers, readiness, restarts, expected Services, PVC UIDs, and dashboard access without exposing secrets. `k8s-stop` stops only the managed dashboard port-forward and scales EWSP Deployments and StatefulSets to zero. It preserves the namespace, Services, ConfigMaps, Secrets, PVCs, PVs, cached images, and all Compose resources; the next `k8s-up` restores every workload to one replica with the same configured GHCR refs.

The guaranteed target is the PC-dependent, single-node Docker Desktop kind cluster (verified with Kubernetes v1.36.1). Do not run Compose and Kubernetes simultaneously when both would need dashboard host port 3000; neither workflow automatically stops the other.

### Temporary/current $0 Cloudflare Quick Tunnel

The current public demo/testing path remains free: `tunnel-quick` starts the
locally installed `cloudflared` against the existing EWSP-managed
`localhost:3000` dashboard port-forward and receives a random
`https://<random>.trycloudflare.com` hostname. It needs neither a Cloudflare
account nor a domain. The hostname changes between runs, so this path is for
temporary demos and testing, not stable publication. The workflow does not
install `cloudflared`, create Kubernetes tunnel resources, or store Cloudflare
credentials or tokens.

```powershell
.\ewsp.ps1 tunnel-quick
.\ewsp.ps1 tunnel-status
.\ewsp.ps1 tunnel-stop
```

`tunnel-quick` requires the verified `docker-desktop` context, namespace `ewsp`, one Ready backend replica, exactly one Ready dashboard Pod, and the managed dashboard forward on `localhost:3000` (which it safely starts or reuses). It derives a literal trusted-proxy regex from the current dashboard Pod IPv4 address, temporarily sets backend forwarded-header handling to `NATIVE`, and allows only `http://localhost:3000` plus the exact generated Quick Tunnel origin. The random hostname and pre-run backend settings are recorded only under ignored `.tmp/` runtime state; no Pod IP or public hostname is written to tracked manifests.

Startup verifies public `/`, `/complaints`, `/api/health`, WebSocket `/ws`, and a safe unauthenticated request larger than 1 MiB that must not receive the former Nginx `413` response. `tunnel-status` reports the installed `cloudflared` version/path, managed process and URL, dashboard forward, backend proxy mode/boundary, and backend/dashboard readiness without printing secrets.

The current production application exposes no safe request diagnostic for backend `getRemoteAddr`, resolved scheme, or `isSecure`, and its ordinary logs do not contain those fields. The workflow therefore reports that empirical limitation instead of adding a public diagnostic endpoint or claiming forged `X-Forwarded-For` normalization was observed. Dashboard access logs can establish the local cloudflared-to-Nginx TCP peer (`127.0.0.1`); exact Cloudflare header and visitor IPv4/IPv6 observations require bounded test instrumentation in the application repository and are deliberately not implemented here.

`tunnel-stop` validates the recorded process identity before stopping it, so unrelated `cloudflared` processes are never killed. It restores the exact pre-run backend environment overrides (therefore returning to the normal ConfigMap/application defaults such as forwarded-header strategy `NONE` and local CORS origin), waits for backend readiness, removes Quick Tunnel runtime files, and leaves all Kubernetes workloads, PVCs, Services, and the dashboard port-forward running.

If `cloudflared` is unavailable, install it explicitly (on Windows, `winget install --id Cloudflare.cloudflared`), open a new PowerShell, and verify `cloudflared --version`; the orchestration never installs it silently. Quick Tunnel process logs are bounded in diagnostics and remain under ignored `.tmp/k8s/` only while needed for the managed lifecycle.

### Optional future permanent named Cloudflare Tunnel

The permanent design is separate from `tunnel-quick`. It runs the pinned
`cloudflare/cloudflared:2026.8.2` connector as a hardened, one-replica
Deployment in namespace `ewsp`. Cloudflare is the only public traffic path:
the remotely managed hostname routes to
`http://dashboard.ewsp.svc.cluster.local:80`; dashboard serves React and proxies
`/api` and `/ws` to the internal backend. Backend, PostgreSQL, Redis, and MinIO
remain ClusterIP-only. No NodePort, LoadBalancer, Kubernetes Ingress, or
cloudflared Service is created.

This optional path requires a domain and public hostname controlled through
Cloudflare. No permanent tunnel, token, or hostname is currently configured for
EWSP; the project remains on the $0 Quick Tunnel path. Normal `k8s-up` cannot
publish EWSP accidentally because permanent publication remains disabled unless
all explicit local requirements below are supplied.

Permanent publication requires an explicit opt-in in ignored `.env`:

```dotenv
CLOUDFLARE_TUNNEL_ENABLED=true
CLOUDFLARE_TUNNEL_TOKEN=<named-tunnel connector token>
CLOUDFLARE_PUBLIC_HOSTNAME=ewsp.example.com
```

The token alone never enables the connector. `k8s-up` safely creates the
`cloudflared-tunnel-token` Secret without displaying it, derives the current
node-assigned Pod CIDR (not the kindnet or Service subnet), converts it to an
anchored Tomcat regex, and sets the backend to native forwarded-header handling.
Targeted NetworkPolicies then allow only `cloudflared -> dashboard:80` and
`dashboard -> backend:8080`; this isolation is what makes trusting the node Pod
CIDR safe against unrelated in-cluster Pods forging forwarding headers.

If no named tunnel exists yet, create one under Cloudflare **Networking >
Tunnels**, copy its **Add a replica** connector token, and configure its public
hostname service exactly as
`http://dashboard.ewsp.svc.cluster.local:80`. No `cert.pem`, account-wide key,
API token, or credentials JSON is needed by the running Pod. See
`k8s/README.md` for lifecycle, security, status, and stop/restoration details.

Kubernetes PostgreSQL and MinIO PVCs are separate from the Docker Compose named volumes and do not migrate or reuse their data. Deleting the Kubernetes PVCs or resetting the cluster can destroy Kubernetes data; neither action affects the preserved Compose volumes unless those volumes are separately removed.

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
- An external host-port conflict requires stopping/reconfiguring that listener or changing the corresponding value in `.env`. Changing `BACKEND_HOST_PORT` affects direct host access but not the dashboard's internal `backend:8080` proxy target. Keep `EWSP_CORS_ALLOWED_ORIGINS` aligned with any browser origins that access the backend directly. The script never kills the listener.
- Readiness failures automatically show bounded logs. For more detail, use the Compose invocation printed by `up`, add `-f compose.yml`, and run `logs <service>`. Ordinary Compose shutdown preserves data; do not add `-v` unless deleting this project's PostgreSQL and MinIO data is intentional.
