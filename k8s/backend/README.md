# EWSP backend Kubernetes contract

The backend runs as one pod behind the internal `backend` ClusterIP Service.
REST traffic and `/ws` WebSocket traffic share port 8080. The `Recreate`
strategy avoids transiently running multiple backend instances during a local
update; multi-replica STOMP distribution is intentionally out of scope.

## Image tag

The checked-in image `ewsp-backend:replace-with-ewsp-local-tag` is an explicit
placeholder and must be replaced before deployment. `ewsp-local` tags clean
backend builds as `ewsp-backend:<commit12>-<build-input-hash12>` and dirty builds
as `ewsp-backend:dirty-<commit>-<session>`, so a static manifest cannot safely
name the current locally built image.

Render the Deployment with the actual tag without editing the checked-in
manifest, then apply the rendered output when deployment is intended:

```powershell
$backendImage = 'ewsp-backend:<actual-ewsp-local-tag>'
kubectl set image -f k8s/backend/deployment.yaml `
  backend=$backendImage --local -o yaml |
  kubectl apply -f -
```

Apply `configmap.yaml` and `service.yaml` separately. The image must exist in the
Docker Desktop image store because `imagePullPolicy` is `IfNotPresent`.

## Health and shutdown

All probes use `/api/health`. Per the backend audit contract, this endpoint is a
shallow, dependency-independent process check: readiness does not prove that
PostgreSQL, Redis, or MinIO are usable, and liveness must remain independent of
those services. The startup probe allows approximately 120 seconds for JVM and
Flyway initialization.

Spring graceful shutdown has a 30-second shutdown-phase timeout. Kubernetes
allows 45 seconds before terminating the container, leaving time for Spring to
stop accepting requests and finish in-flight HTTP and WebSocket work.
