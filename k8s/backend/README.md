# EWSP backend Kubernetes contract

The backend runs as one pod behind the internal `backend` ClusterIP Service.
REST traffic and `/ws` WebSocket traffic share port 8080. The `Recreate`
strategy avoids transiently running multiple backend instances during a local
update; multi-replica STOMP distribution is intentionally out of scope.

## Image tag

The checked-in image `ewsp-backend:replace-with-ewsp-local-tag` is an explicit
environment-independent placeholder. `k8s-up` replaces it only in ignored
rendered output with `EWSP_BACKEND_IMAGE`, which must be the private
`ghcr.io/mohammad-hamadi/ewsp-backend` image tagged by a full Git SHA.

Render the Deployment with the actual tag without editing the checked-in
manifest, then apply the rendered output when deployment is intended:

```powershell
$backendImage = 'ghcr.io/mohammad-hamadi/ewsp-backend:<full-git-sha>'
kubectl set image -f k8s/backend/deployment.yaml `
  backend=$backendImage --local -o yaml |
  kubectl apply -f -
```

`imagePullPolicy: IfNotPresent` permits cache reuse, while the `ghcr-pull`
`imagePullSecret` lets Kubernetes obtain a missing private image. `k8s-up`
creates that Secret from ignored local credentials and never builds this image.

## Health and shutdown

All probes use `/api/health`. Per the backend audit contract, this endpoint is a
shallow, dependency-independent process check: readiness does not prove that
PostgreSQL, Redis, or MinIO are usable, and liveness must remain independent of
those services. The startup probe allows approximately 120 seconds for JVM and
Flyway initialization.

Spring graceful shutdown has a 30-second shutdown-phase timeout. Kubernetes
allows 45 seconds before terminating the container, leaving time for Spring to
stop accepting requests and finish in-flight HTTP and WebSocket work.
