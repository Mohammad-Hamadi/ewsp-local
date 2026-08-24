# EWSP Kubernetes infrastructure

These plain manifests define the local EWSP stack in the `ewsp` namespace. They
use internal `ClusterIP` Services only. PostgreSQL and MinIO request dynamically
provisioned storage from the cluster's default StorageClass; Redis is
intentionally non-persistent.

## Local lifecycle

The supported Docker Desktop Kubernetes workflow is:

```powershell
.\ewsp.ps1 k8s-up
.\ewsp.ps1 k8s-status
.\ewsp.ps1 k8s-stop
```

`k8s-up` requires the current context to be exactly `docker-desktop` and verifies
the reachable single-node Docker Desktop kind cluster, Ready node/container runtime,
and default `standard` local-path StorageClass. It does not require Docker Engine for application builds, switch context, or
reset the cluster. Resources are reconciled in dependency order and readiness is
observed rather than delayed with fixed sleeps.

## Current $0 public demo path

The current public demo/testing mechanism is `./ewsp.ps1 tunnel-quick`. It uses
a random `*.trycloudflare.com` hostname, requires no domain, and costs nothing.
The hostname changes between runs, so it is intentionally temporary rather than
a stable deployment. See the repository README for `tunnel-status` and
`tunnel-stop` behavior.

## Optional future permanent Cloudflare Tunnel

The permanent public path is an explicitly enabled, remotely managed named
Cloudflare Tunnel running as one `cloudflared` Pod:

```text
Cloudflare HTTPS/WSS -> cloudflared -> dashboard.ewsp.svc.cluster.local:80
                                      -> /api and /ws -> backend:8080
```

This future path requires a domain and hostname controlled through Cloudflare.
No permanent tunnel, token, or hostname is configured for the current project.
The default remains disabled, and ordinary `k8s-up` cannot expose EWSP publicly
when the explicit requirements below are absent.

Set all three values in the ignored `.env` file (never in a tracked manifest):

```dotenv
CLOUDFLARE_TUNNEL_ENABLED=true
CLOUDFLARE_TUNNEL_TOKEN=<named-tunnel connector token>
CLOUDFLARE_PUBLIC_HOSTNAME=ewsp.example.com
```

The enable flag is deliberately required. A token by itself does not deploy or
start the connector. When enabled, `k8s-up` derives the single schedulable
node's assigned Pod CIDR from `.spec.podCIDRs`/`.spec.podCIDR`, rejects missing,
multiple, non-IPv4, non-canonical, or host-bit-bearing values, and converts the
CIDR to a fully anchored Tomcat regex. It reconciles the backend to
`SERVER_FORWARD_HEADERS_STRATEGY=NATIVE` with that runtime-only regex. No Pod
IP, Service CIDR, node IP, loopback address, cluster-wide kindnet subnet, or
RFC1918 fallback is trusted. With the feature disabled, the ordinary source
manifest restores the backend's default `NONE` behavior, any existing connector
is scaled to zero, and the permanent policies are removed.

`k8s-up` creates/updates `cloudflared-tunnel-token` from `.env`, applies it from
an ACL-restricted ignored temporary artifact, and removes that artifact. The
token is never printed. The Deployment uses the pinned
`cloudflare/cloudflared:2026.8.2` image, a non-root user, a read-only root
filesystem, no service-account token, and no Linux capabilities. Kubernetes
checks cloudflared's private port 2000 `/ready` endpoint; there is no Service for
that endpoint.

Before enabling it, create a remotely managed tunnel in Cloudflare:

1. In Cloudflare, open **Networking > Tunnels**, create a Cloudflared tunnel,
   and copy the connector token from **Add a replica**.
2. Add a public hostname for the intended DNS name. Set its service/origin URL
   exactly to `http://dashboard.ewsp.svc.cluster.local:80`.
3. Put the token and hostname only in ignored `.env`, set the explicit enable
   flag, and run `./ewsp.ps1 k8s-up`.

The token-only remotely managed model does not use `cert.pem`, an account API
key/token, or a tunnel credentials JSON file at runtime. The Cloudflare-side
public-hostname rule supplies the origin route. `k8s-stop` scales cloudflared
with the other workloads but preserves its Kubernetes Secret and never deletes
the remote tunnel or DNS route. `k8s-status` reports desired/ready replicas,
Pod status/restarts/image, backend proxy mode, node-Pod-CIDR boundary source,
policy-object presence, and the safe configured hostname; it never reads or
prints the Secret value.

Two ingress NetworkPolicies enforce the application path: only dashboard Pods
may reach backend TCP 8080, and only cloudflared Pods may reach dashboard TCP
80. Kubernetes node-origin probe and port-forward behavior must be confirmed
empirically on the installed CNI after policy changes; policy-object presence
alone is not reported as proof of enforcement.

Backend and dashboard images come only from explicit `EWSP_BACKEND_IMAGE` and
`EWSP_DASHBOARD_IMAGE` values in ignored `.env`. Each ref must name its expected
private GHCR repository with a full 40-character Git SHA tag. `main`, `latest`,
wrong repositories, and malformed refs fail before apply. The checked-in image
placeholders are never rewritten. Exact Deployments are rendered under ignored
`.tmp/k8s/rendered/`, validated, and applied with `imagePullPolicy:
IfNotPresent`. Kubernetes pulls a missing artifact from GHCR; `k8s-up` does not
inspect sibling source or invoke a local application build.

On success, an EWSP-managed `kubectl port-forward` exposes only the dashboard at
`http://localhost:3000`. Its state is recorded under ignored `.tmp/k8s/` so a
later run can reuse it and `k8s-stop` can stop only that process. An unrelated
listener on the configured dashboard port is reported and never killed. The
dashboard keeps `/api` and `/ws` same-origin and proxies them to the internal
`backend:8080` Service.

`k8s-stop` scales the three Deployments and two StatefulSets to zero and stops
the managed dashboard port-forward. It preserves Services, ConfigMaps, the real
Secret, PVCs, PVs, Docker images, and Compose resources. The next `k8s-up`
reapplies the one-replica manifests. There is intentionally no destructive
Kubernetes clean command.

## Local secrets

`config/secrets.example.yaml` documents the required Secret name and keys. It
contains placeholders only and is safe to validate, but must not be used as the
real Secret.

`k8s-up` reads the required values through ewsp-local's safe `.env` parser,
creates a restrictive ignored temporary Secret artifact, applies
`ewsp-infrastructure-secrets`, and removes the temporary secret material after
application. Values are not printed. The required keys are `POSTGRES_USER`,
`POSTGRES_PASSWORD`, `MINIO_ROOT_USER`, `MINIO_ROOT_PASSWORD`, and `JWT_SECRET`.

Private application pulls use `GHCR_USERNAME` plus a local `GHCR_TOKEN` with
package-read permission only. `k8s-up` generates a separate ACL-restricted,
ignored `kubernetes.io/dockerconfigjson` artifact, reconciles Secret `ghcr-pull`,
and removes the artifact after apply. The credential is never stored in tracked
YAML, a ConfigMap, application environment, container image, or logs. Do not use
the Actions `GITHUB_TOKEN` locally.

Bucket initialization is deliberately omitted: the application retains its
existing lazy bucket-creation behavior.

## Explicit local user seed

`./ewsp.ps1 k8s-seed` is an explicit local-development command restricted to
the exact `docker-desktop` context and `ewsp` namespace. Neither `k8s-up` nor
the tunnel workflows invoke it automatically. The ignored sibling backend seed
is idempotent and uses `ON CONFLICT DO NOTHING`: it adds missing local users but
does not reset passwords or overwrite any other existing user row in a
preserved PostgreSQL PVC. Existing persisted users may therefore retain
credentials or other values that differ from the current ignored seed file.

## Persistence and coexistence

Kubernetes PostgreSQL and MinIO PVCs are independent of the Compose named
volumes. `k8s-stop` preserves both environments, but deleting PVCs or resetting
Docker Desktop Kubernetes can destroy Kubernetes data. Kubernetes infrastructure
does not consume host ports; only dashboard port-forwarding can conflict with a
running Compose dashboard on port 3000. Use `.\ewsp.ps1 up`, `status`, and `stop`
for Compose, and the `k8s-*` commands above for Kubernetes.
