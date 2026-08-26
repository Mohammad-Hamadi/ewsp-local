# EWSP Local Environment

`ewsp-local` is the orchestration repository for the EWSP sibling workspace. It owns repository bootstrap/update safeguards, full-stack Docker Compose, the local Docker Desktop Kubernetes baseline, deployment-host reconciliation, and temporary or optional public access. Application source and container recipes remain in their component repositories.

This environment supports development, integration, demonstrations, and the current single-PC deployment model. It does not claim high availability or general-purpose production hosting.

## Documentation map

| Subject | Authoritative document |
| --- | --- |
| Workspace setup, Compose, and command entry points | This README and `.\ewsp.ps1 help` |
| Kubernetes topology, lifecycle, secrets, image reconciliation, CD, persistence, and tunnels | [Kubernetes operations](k8s/README.md) |
| Backend Kubernetes manifest/runtime details | [Backend Kubernetes contract](k8s/backend/README.md) |
| Dashboard Kubernetes manifest/runtime details | [Dashboard Kubernetes contract](k8s/dashboard/README.md) |
| Backend development and API | [`ewsp-backend` README](https://github.com/Mohammad-Hamadi/ewsp-backend) and [runbook](https://github.com/Mohammad-Hamadi/ewsp-backend/blob/main/BACKEND_RUNBOOK.md) |
| Dashboard development and production image | [`ewsp-dashboard` README](https://github.com/Mohammad-Hamadi/ewsp-dashboard) |
| Mobile development, discovery, signing, and releases | [`ewsp-mobile` README](https://github.com/Mohammad-Hamadi/ewsp-mobile) |

## Workspace layout

Keep the repositories as siblings:

```text
EWSP/
|-- ewsp-backend/
|-- ewsp-dashboard/
|-- ewsp-mobile/
`-- ewsp-local/
```

`ewsp-local` uses `../ewsp-backend` and `../ewsp-dashboard` as Compose build contexts. The mobile application runs separately on an emulator or device.

## Command discovery

The PowerShell CLI provides command-specific and workflow help without requiring Docker or Kubernetes:

```powershell
.\ewsp.ps1 help
.\ewsp.ps1 help commands
.\ewsp.ps1 help <command>
.\ewsp.ps1 help find <term>
.\ewsp.ps1 help workflow local
.\ewsp.ps1 help workflow kubernetes
.\ewsp.ps1 help workflow cd
.\ewsp.ps1 help workflow public-demo
```

The built-in help is authoritative for current command syntax. This README explains the system-level workflows and ownership boundaries.

## Prerequisites

- Windows PowerShell 5.1 or PowerShell 7+
- Git
- Docker Desktop or another Docker Engine with Compose support
- For Kubernetes: `kubectl` and Docker Desktop Kubernetes using context `docker-desktop`

Windows with Docker Desktop is the verified platform. The CLI detects other operating systems and Compose implementations but does not claim them as tested targets. Java, Maven, Node, and Nginx are contained within the application image builds for the Compose workflow.

## Compose workflow

For a normal workspace bootstrap/update and full-stack start:

```powershell
.\ewsp.ps1 up
.\ewsp.ps1 status
.\ewsp.ps1 stop
```

`up` detects the environment, clones missing expected siblings, safely fast-forwards only clean behind-`main` repositories with verified upstreams, creates `.env` only when absent, validates ports and build inputs, builds or reuses source-identified application images, starts five services, waits for readiness, and verifies endpoints.

Dirty, ahead, diverged, detached, wrong-branch, missing-upstream, identity-mismatched, and unexpected directories are preserved. If required application-owned Docker assets are unavailable, startup stops instead of replacing source or using an orchestration-owned fallback.

Individual phases are available when explicit control is useful:

| Command | Purpose |
| --- | --- |
| `.\ewsp.ps1 setup` | Validate prerequisites, clone missing siblings, and create `.env` if absent |
| `.\ewsp.ps1 update` | Fetch and fast-forward only safe repository states |
| `.\ewsp.ps1 start` | Resolve/build images and start Compose without changing Git |
| `.\ewsp.ps1 status` | Report repository, environment, container, and health state |
| `.\ewsp.ps1 stop` | Stop Compose while preserving its named volumes |

### Compose topology

| Service | Role | Default host endpoint | Persistence |
| --- | --- | --- | --- |
| `dashboard` | Nginx-served React UI and same-origin proxy | `http://localhost:3000` | None |
| `backend` | Spring Boot API and STOMP endpoint | `http://localhost:8080` | None |
| `postgres` | Primary database | `localhost:5432` | Named volume |
| `redis` | Temporary verification/rate-limit state | `localhost:6379` | Memory-backed, non-persistent |
| `minio` | Evidence object storage and console | `http://localhost:9000`, `http://localhost:9001` | Named volume |

The dashboard proxies same-origin `/api` and `/ws` to `backend:8080`. The browser does not need an embedded backend hostname. Backend Swagger is available at `http://localhost:8080/swagger-ui/index.html`.

Compose images are built from sibling source using each application's own Dockerfile. Clean images are reusable and identify the source commit plus declared build inputs; dirty source receives a session-specific non-reusable tag. This image flow is separate from the immutable private GHCR images used by Kubernetes.

### Compose configuration and persistence

`setup` copies `.env.example` to ignored `.env` only when `.env` is absent. Host ports, local infrastructure credentials, JWT configuration, SMTP settings, mobile release metadata, Kubernetes image refs, and optional tunnel settings are defined there.

Ordinary `.\ewsp.ps1 stop` preserves PostgreSQL and MinIO volumes. A direct `docker compose down -v` deletes those Compose data volumes. Compose data is independent of Kubernetes PVCs.

## Kubernetes overview

The local Kubernetes workflow targets the single-node Docker Desktop cluster and never builds application source:

```powershell
.\ewsp.ps1 k8s-up
.\ewsp.ps1 k8s-seed       # explicit local/demo users when needed
.\ewsp.ps1 k8s-status
.\ewsp.ps1 k8s-stop
```

It deploys PostgreSQL, Redis, MinIO, backend, and dashboard in namespace `ewsp`, with only an EWSP-managed dashboard port-forward on `localhost:3000`. Backend and dashboard use private GHCR images tagged by full Git SHA. `k8s-stop` scales workloads to zero and preserves Services, ConfigMaps, Secrets, PVCs, and images.

Image selection is state-aware: after a complete successful automatic deployment, matching desired/deployed SHAs from `%USERPROFILE%\.ewsp\deployment-state.json` override older `.env` application refs so a later `k8s-up` does not downgrade the applications. If that record is unusable or incomplete, validated `EWSP_BACKEND_IMAGE` and `EWSP_DASHBOARD_IMAGE` values from `.env` are used. The full contract is in [Kubernetes image resolution](k8s/README.md#application-image-resolution).

## Continuous deployment overview

Backend and dashboard CI verify source and publish immutable private GHCR images. Their successful `main` workflows send a best-effort dispatch to `ewsp-local`; a self-hosted Windows runner on EWSP-PC performs deployment reconciliation against Docker Desktop Kubernetes.

```powershell
.\ewsp.ps1 deploy-configure
# Add EWSP_ADMIN_PASSWORD directly to %USERPROFILE%\.ewsp\deployment.env.
.\ewsp.ps1 runner-setup
.\ewsp.ps1 deploy
.\ewsp.ps1 deploy-status
```

`deploy` independently discovers the newest successful `push` run of each application `ci.yml` on `main`, verifies the exact SHA-tagged GHCR artifacts and Linux/AMD64 digests, updates only changed/unhealthy application Deployments, and verifies routes, `/api`, `/ws`, admin login, image digests, and unchanged PVC UIDs. Infrastructure is not reapplied during an ordinary application deployment. Rollback is image-only; backend rollback stops if Flyway history changed or cannot be verified, and database migrations are never reversed automatically.

See [continuous deployment reconciliation](k8s/README.md#continuous-deployment-reconciliation) for host state, concurrency, recovery, and rollback semantics.

## Public demo overview

The current public path is a temporary Cloudflare Quick Tunnel:

```powershell
.\ewsp.ps1 k8s-up
.\ewsp.ps1 tunnel-quick
.\ewsp.ps1 tunnel-status
.\ewsp.ps1 tunnel-stop
```

It exposes the managed dashboard port-forward at a random `*.trycloudflare.com` HTTPS origin and publishes that origin to `public/mobile-bootstrap.json`. The hostname changes between runs and is not permanent hosting.

An optional remotely managed named Cloudflare Tunnel is implemented but disabled unless explicitly configured with a domain, hostname, enable flag, and connector token. Kubernetes-specific proxy trust, NetworkPolicy, Secret, verification, and restoration behavior is documented under [public access](k8s/README.md#public-access).

## Mobile development

Flutter is not part of Compose. For a standard Android emulator, use the backend origin without `/api`:

```powershell
flutter run --dart-define=EWSP_DEV_API_ORIGIN=http://10.0.2.2:8080
```

The mobile repository is authoritative for `EWSP_DEV_API_ORIGIN`, release `EWSP_BOOTSTRAP_URL`, signing, and update behavior. See the [`ewsp-mobile` runtime configuration](https://github.com/Mohammad-Hamadi/ewsp-mobile#runtime-configuration).

## Troubleshooting entry points

- Run `.\ewsp.ps1 help diagnostics` and the relevant `status`, `k8s-status`, `deploy-status`, or `tunnel-status` command.
- If Docker CLI detection succeeds but the Engine is unreachable, start Docker Desktop/Engine and retry.
- Resolve reported Git states in the owning repository; orchestration does not reset or overwrite them.
- Resolve external host-port conflicts or change the corresponding ignored `.env` value; the CLI does not stop unrelated listeners.
- Readiness failures include bounded service state and logs. For direct Compose inspection, use the Compose implementation printed by `up` with `-f compose.yml logs <service>`.
- Kubernetes-specific recovery and persistence behavior is in [the Kubernetes guide](k8s/README.md).
