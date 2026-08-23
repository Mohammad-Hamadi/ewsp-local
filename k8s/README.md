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
the reachable single-node Docker Desktop kind cluster, Ready node, Docker Engine,
and default `standard` local-path StorageClass. It does not switch context or
reset the cluster. Resources are reconciled in dependency order and readiness is
observed rather than delayed with fixed sleeps.

Backend and dashboard image tags use the existing source-aware EWSP image
identity. An exact clean image already in Docker Desktop is reused; a missing
image is built from the application repository's own Dockerfile; dirty source
gets a unique session tag. The checked-in non-`latest` image placeholders are
never rewritten. Exact Deployments are rendered under ignored
`.tmp/k8s/rendered/`, validated, and applied with `imagePullPolicy:
IfNotPresent`. Docker Desktop's local image mirror supplies the images to the
kind node; the workflow does not push them.

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

Bucket initialization is deliberately omitted: the application retains its
existing lazy bucket-creation behavior.

## Persistence and coexistence

Kubernetes PostgreSQL and MinIO PVCs are independent of the Compose named
volumes. `k8s-stop` preserves both environments, but deleting PVCs or resetting
Docker Desktop Kubernetes can destroy Kubernetes data. Kubernetes infrastructure
does not consume host ports; only dashboard port-forwarding can conflict with a
running Compose dashboard on port 3000. Use `.\ewsp.ps1 up`, `status`, and `stop`
for Compose, and the `k8s-*` commands above for Kubernetes.
