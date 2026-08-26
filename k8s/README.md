# EWSP Kubernetes Operations

This document is the authoritative operational reference for the EWSP Kubernetes baseline, its local lifecycle, application image reconciliation, secrets, persistence, deployment automation, and public-access paths. The [repository README](../README.md) remains the entry point for sibling-workspace and Compose operations.

The manifests target the single-node Docker Desktop Kubernetes cluster in context `docker-desktop`. They provide a durable local/demo deployment, not a highly available or cloud-neutral production design.

## Architecture

```text
temporary Quick Tunnel or optional named Tunnel
                       |
                       v
dashboard Service :80 (ClusterIP) / managed localhost:3000 port-forward
  |-- React SPA
  |-- /api --------------------------------+
  `-- /ws ---------------------------------+--> backend Service :8080
                                                   |-- PostgreSQL Service :5432
                                                   |-- Redis Service :6379
                                                   `-- MinIO Service :9000
```

All resources use namespace `ewsp`. No application or infrastructure Service is a `NodePort` or `LoadBalancer`.

### Resource topology

| Component | Controller | Replicas | Storage | Probe contract |
| --- | --- | ---: | --- | --- |
| PostgreSQL 16 | StatefulSet | 1 | 5 Gi `ReadWriteOnce` PVC | `pg_isready` startup/readiness |
| Redis 7 | Deployment | 1 | 128 MiB memory-backed `emptyDir`; persistence disabled | `redis-cli ping` startup/readiness/liveness |
| MinIO | StatefulSet | 1 | 10 Gi `ReadWriteOnce` PVC | MinIO live/ready HTTP endpoints |
| Backend | `Recreate` Deployment | 1 | None | `/api/health` startup/readiness/liveness |
| Dashboard | `Recreate` Deployment | 1 | None | `/index.html` readiness/liveness |
| Optional `cloudflared` | `Recreate` Deployment | 0 or 1 | None | private port `2000` `/ready` |

PostgreSQL and MinIO use the cluster's default StorageClass. Redis is deliberately ephemeral. The backend creates the MinIO bucket lazily; no bucket-initialization workload exists.

Component-specific manifest behavior is documented in the [backend contract](backend/README.md) and [dashboard contract](dashboard/README.md).

## Local lifecycle

```powershell
.\ewsp.ps1 k8s-up
.\ewsp.ps1 k8s-status
.\ewsp.ps1 k8s-stop
```

`k8s-up`:

1. Requires the current context to be exactly `docker-desktop`.
2. Verifies the reachable single-node Docker Desktop kind cluster, Ready node/runtime, and default `standard` local-path StorageClass.
3. Resolves immutable application images using the precedence below.
4. Validates local infrastructure, SMTP, GHCR, and optional tunnel configuration without printing secret values.
5. Generates ACL-restricted ignored Secret artifacts, renders application manifests under ignored `.tmp/k8s/rendered/`, and validates the complete manifest set.
6. Applies namespace/configuration, storage services, applications, proxy settings, NetworkPolicies, and optional `cloudflared` in dependency order.
7. Waits on probes and controller state rather than fixed sleeps.
8. Verifies internal DNS/services and same-origin application routes.
9. Starts or reuses the managed dashboard port-forward at `http://localhost:3000`.

The command does not switch Kubernetes context, reset the cluster, build application images, or clone application source.

`k8s-status` reports controllers, desired/ready replicas, Pod status/restarts/images/image IDs, image-source agreement, Services, PVC UIDs, dashboard access, proxy mode, tunnel state, and NetworkPolicy presence without reading Secret values.

### Managed dashboard port-forward

The dashboard port-forward is shared across the stable checkout, Actions workspaces, startup reconciliation, status, stop, and tunnel commands. Non-secret ownership state lives at:

```text
%USERPROFILE%\.ewsp\dashboard-port-forward.json
```

Reuse or stop requires the recorded PID and process start time, resolved `kubectl.exe`, exact namespace/service and `3000:80` command, listener ownership, and a healthy endpoint. A matching healthy EWSP forward may be adopted when state is missing; unrelated listeners are reported and are never adopted or stopped.

## Application image resolution

Both application refs must be private GHCR images in the expected repository and tagged by a complete lowercase 40-character Git SHA:

```text
ghcr.io/mohammad-hamadi/ewsp-backend:<full-sha>
ghcr.io/mohammad-hamadi/ewsp-dashboard:<full-sha>
```

Moving tags such as `main` and `latest`, wrong repositories, wrong registries, and malformed refs are rejected. Checked-in manifests retain environment-independent placeholders. `k8s-up` renders exact Deployments under `.tmp/k8s/rendered/` and applies them with `imagePullPolicy: IfNotPresent` and `ghcr-pull`; it never edits the source manifests.

Image source precedence is intentionally anti-downgrade:

1. Read validated local values from ignored `.env`.
2. Read `%USERPROFILE%\.ewsp\deployment-state.json` when it exists.
3. Use state-file images only when the record status is `ALREADY_CURRENT` or `RECONCILIATION_SUCCEEDED`, both desired and deployed SHAs are valid for both applications, and each deployed SHA exactly equals its desired SHA.
4. When every condition holds, both state-file SHA refs replace the corresponding `.env` refs for `k8s-up` and `k8s-status`.
5. If the record is absent, malformed, incomplete, unsuccessful, or mismatched, use the validated `.env` refs for both applications.

This prevents a successful CD rollout from being downgraded by a later local reconciliation whose ignored `.env` still names older images. The state file contains recoverable, non-secret operational history; it is not CI approval evidence. CD discovers approved artifacts from GitHub, and Kubernetes Pod state remains authoritative for what is actually running.

## Secrets and configuration

### Local sources

| Source | Purpose |
| --- | --- |
| Ignored `.env` | Local infrastructure credentials, JWT secret, GHCR pull credentials, host port, application fallback refs, and optional permanent-tunnel settings |
| `%USERPROFILE%\.ewsp\deployment.env` | ACL-protected deployment-host GitHub/GHCR/admin credentials and SMTP delivery settings |
| `k8s/config/secrets.example.yaml` | Tracked key/Secret-name reference containing placeholders only |

`k8s-up` reads infrastructure values with the repository's constrained `.env` parser and deployment SMTP values from the protected machine file. It creates `ewsp-infrastructure-secrets` from an ACL-restricted ignored temporary artifact, applies it, and removes the artifact. The backend references individual Secret keys for PostgreSQL, MinIO, JWT, and SMTP configuration.

Deployment SMTP requires mail enabled, authentication enabled, and STARTTLS enabled. A semantic fingerprint of protected mail settings on the backend Pod template causes a backend-only restart after changes.

Private image pulls use `GHCR_USERNAME` and a `GHCR_TOKEN` with package-read access. `k8s-up` creates the separate `kubernetes.io/dockerconfigjson` Secret `ghcr-pull` and removes its temporary artifact. The credential is not placed in a ConfigMap, Pod environment, image, tracked YAML, or logs.

### Non-secret backend configuration

`k8s/backend/configmap.yaml` owns database/service endpoints, local CORS, shutdown behavior, and public mobile release metadata. The [backend manifest contract](backend/README.md#mobile-release-metadata) records the currently advertised version and rollout procedure.

The backend Pod template contains a semantic fingerprint of all ConfigMap data. Updating the ConfigMap and running `k8s-up` causes a short backend `Recreate` rollout without rebuilding an image or modifying infrastructure data. Compose defaults and `.env.example` mirror the release values for local consistency; this ConfigMap is authoritative for the Kubernetes deployment.

## Persistence and stop behavior

`k8s-stop` stops the managed dashboard port-forward and scales backend, dashboard, Redis, PostgreSQL, and MinIO controllers to zero. If the optional permanent tunnel exists, it is also scaled to zero. The command preserves:

- namespace, Services, ConfigMaps, and Secrets;
- PostgreSQL and MinIO PVCs/PVs;
- container images;
- remote Cloudflare tunnel/DNS configuration;
- all Compose containers and volumes.

The next `k8s-up` reapplies one-replica source manifests and reconciles current configuration. There is no destructive Kubernetes clean command. Deleting PVCs or resetting Docker Desktop Kubernetes can destroy Kubernetes data; those PVCs are independent of Compose named volumes.

Compose and Kubernetes may coexist at the data layer, but their dashboard access paths both default to host port `3000`. Neither workflow stops the other or terminates an unrelated listener.

## Health and readiness

Controller probes establish process-level readiness:

- backend `/api/health` is deliberately shallow and dependency-independent;
- dashboard `/index.html` proves Nginx and the static bundle, not backend availability;
- PostgreSQL, Redis, and MinIO use their service-native checks.

After probes pass, orchestration separately verifies infrastructure, DNS, backend health, dashboard routes, same-origin API routing, and WebSocket upgrade behavior. Public and CD workflows add their own external and authenticated checks. Probe readiness alone is not treated as full-stack readiness.

## Seed and credential recovery

Flyway creates the schema and required lookup data, but Kubernetes startup does not create demo employees.

```powershell
.\ewsp.ps1 k8s-seed
```

`k8s-seed` is restricted to context `docker-desktop` and namespace `ewsp`. It streams the ignored sibling file `ewsp-backend/local-dev/seed-dashboard-users.sql` to the Ready PostgreSQL Pod with SQL error stopping enabled. The seed uses `ON CONFLICT DO NOTHING`: it adds missing identities and does not overwrite retained users or passwords. Neither `k8s-up` nor tunnel startup invokes it.

If a retained local admin has an older seed password hash:

```powershell
.\ewsp.ps1 k8s-reset-admin
```

The reset command verifies the exact local boundary, Ready database/PVC, expected admin identity and user counts, and the ignored seed source. It updates only the password hash in a transaction, verifies identity/state preservation, then proves the credential through the running backend. It does not delete users, storage, or unrelated fields. This is local/demo recovery, not a production account-provisioning mechanism.

## Continuous deployment reconciliation

```text
backend/dashboard main push
  -> application CI verification
  -> private GHCR full-SHA image
  -> best-effort ewsp-local workflow dispatch
  -> EWSP-PC self-hosted runner
  -> .\ewsp.ps1 deploy
  -> Docker Desktop Kubernetes
```

`deploy` does not use `.env` as approval state. For each application it:

1. Queries the private GitHub Actions API for the newest completed successful `push` run of `ci.yml` on `main`.
2. Uses that run's complete `head_sha`; PRs, failures, other branches, malformed SHAs, and missing images are ineligible.
3. Verifies the exact private GHCR tag and resolves its registry and Linux/AMD64 runtime digests.
4. Compares desired artifacts with the configured and running Deployments.
5. Updates only outdated or unhealthy application Deployments.
6. Requires Ready Pods, exact refs and image IDs, infrastructure/DNS health, `/`, `/complaints`, missing-asset behavior, `/api/health`, WebSocket upgrade, authenticated admin login, and unchanged PVC UIDs.

Both application Deployments are one-replica `Recreate`; brief downtime is expected. PostgreSQL, Redis, MinIO, Services, Secrets, ConfigMaps, and PVCs are not reapplied by an ordinary image update.

Dashboard readiness failure restores its previous immutable image. Backend failure restores its previous image only when the before/after Flyway history fingerprint is unchanged. If migration history advanced or cannot be verified, code rollback stops; database migrations are never rolled back automatically.

### Host configuration and execution

```powershell
.\ewsp.ps1 deploy-configure
# Add EWSP_ADMIN_PASSWORD directly to %USERPROFILE%\.ewsp\deployment.env.
.\ewsp.ps1 runner-setup
.\ewsp.ps1 runner-status
.\ewsp.ps1 deploy
.\ewsp.ps1 deploy-status
```

`deploy-configure` copies only approved setting names into the user/SYSTEM ACL-protected machine file. `runner-setup` validates the existing interactive runner under `C:\actions-runner` and creates current-user Scheduled Tasks for the runner at logon and bounded startup reconciliation two minutes later. It does not register the runner or install a Windows service. Interactive logon is required because Docker Desktop belongs to that user session.

`.github/workflows/deploy.yml` accepts manual, application-dispatch, and twice-hourly catch-up events on `[self-hosted, Windows, X64]`. GitHub concurrency allows one active and one newest pending reconciliation without cancelling an active mutation. A machine-local exclusive lock also prevents overlap with startup reconciliation.

Long outages do not depend on a queued dispatch: scheduled GitHub catch-up and logon reconciliation rediscover the newest approved artifacts. Temporary Docker/Kubernetes/GitHub/GHCR startup unavailability uses finite retry; unsafe context/storage, invalid configuration, authentication failure, and deployment failure stop immediately.

`%USERPROFILE%\.ewsp\deployment-state.json` records non-secret desired/deployed SHAs and digests, result, timestamps, trigger, changed components, and PVC UIDs. Successful complete records also drive the `k8s-up` anti-downgrade precedence described above.

## Public access

### Temporary Quick Tunnel

The current $0 demo path uses a locally installed `cloudflared` process and a random `https://<name>.trycloudflare.com` origin:

```powershell
.\ewsp.ps1 tunnel-quick
.\ewsp.ps1 tunnel-status
.\ewsp.ps1 tunnel-stop
```

It requires a Ready backend/dashboard and the managed `localhost:3000` forward. Startup derives a literal trusted-proxy regular expression from the dashboard Pod address, temporarily enables native forwarded-header handling, and permits only the local dashboard and generated public origin. It verifies public application routes, API health, WebSocket upgrade, and upload-size proxy behavior.

After public checks pass, the command uses an isolated temporary checkout under the deployment lock to publish the current origin to `public/mobile-bootstrap.json` on `ewsp-local/main`, then verifies the stable raw URL. The document is public and contains only:

```json
{
  "apiBaseUrl": "https://example.trycloudflare.com"
}
```

The value is an HTTPS origin without `/api`; mobile derives `/api` and `/ws`. The configured fine-grained `EWSP_GITHUB_READ_TOKEN` retains its historical setting name but requires `ewsp-local` Contents read/write for this publication step, plus the private Actions read grants used by deployment discovery.

Rerunning `tunnel-quick` re-verifies and republishes a healthy existing tunnel. If publication fails after the public checks, the tunnel remains running but mobile discovery is reported unavailable. `tunnel-stop` validates process identity, stops only the managed process, restores the exact previous backend proxy/CORS settings, and leaves Kubernetes workloads, PVCs, Services, and the dashboard forward running. The last published bootstrap origin is retained and may be offline; it is discovery metadata, not an availability guarantee.

### Optional named Cloudflare Tunnel

The stable-hostname path is implemented but disabled by default. It requires a Cloudflare-managed domain/hostname and explicit ignored `.env` configuration:

```dotenv
CLOUDFLARE_TUNNEL_ENABLED=true
CLOUDFLARE_TUNNEL_TOKEN=<connector-token>
CLOUDFLARE_PUBLIC_HOSTNAME=ewsp.example.com
```

The token alone does not enable the connector. Configure the remotely managed public hostname origin exactly as `http://dashboard.ewsp.svc.cluster.local:80`.

When enabled, `k8s-up`:

- creates `cloudflared-tunnel-token` from a temporary protected artifact;
- derives the single node's canonical IPv4 Pod CIDR and converts it to an anchored Tomcat trusted-proxy expression;
- runs pinned `cloudflare/cloudflared:2026.8.2` as non-root with a read-only filesystem, no capabilities, and no service-account token;
- applies NetworkPolicies allowing only `cloudflared -> dashboard:80` and `dashboard -> backend:8080`.

No `cloudflared` Service, Ingress, NodePort, or LoadBalancer is created. `k8s-stop` scales the connector down but does not delete its Secret or remote tunnel/DNS route. Disabling the feature and rerunning `k8s-up` restores backend forwarded-header defaults, scales any connector to zero, and removes the permanent-tunnel NetworkPolicies.

NetworkPolicy object presence is not proof of CNI enforcement; node-origin probe and port-forward behavior must be checked against the installed Docker Desktop CNI when policy behavior changes.
