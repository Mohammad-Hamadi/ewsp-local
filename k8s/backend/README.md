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

## Mobile release metadata

`backend-config` supplies the three public runtime properties required by the
mobile version endpoint through the Deployment's existing `envFrom` reference:

```text
EWSP_MOBILE_LATEST_VERSION=1.0.1
EWSP_MOBILE_LATEST_VERSION_CODE=2
EWSP_MOBILE_UPDATE_URL=https://github.com/Mohammad-Hamadi/ewsp-mobile/releases/download/v1.0.1/ewsp-1.0.1.apk
```

They are release metadata, not credentials, and therefore remain in the
ConfigMap rather than a Secret. `k8s-up` places a semantic SHA-256 fingerprint
of all `backend-config` data on the backend Pod template. A ConfigMap data
change therefore causes the existing `Recreate` Deployment to replace the
backend Pod so its process receives the new environment. It does not rebuild
the backend image or mutate PostgreSQL, Redis, MinIO, PVs, or PVCs.

For a future release, update only these three ConfigMap values, update the same
Compose defaults and `.env.example`, then run:

```powershell
.\ewsp.ps1 k8s-up
```

Commit the declarative metadata change normally. The image-only `deploy` and
startup reconciliation workflows remain unchanged; they do not build images
or independently apply runtime ConfigMap revisions.

## SMTP OTP delivery

The backend's SMTP settings come from Secret key references in
`ewsp-infrastructure-secrets`. Real values live only in the ACL-protected
`%USERPROFILE%\.ewsp\deployment.env`; `k8s-up` validates that mail, SMTP
authentication, and STARTTLS are enabled before generating and applying its
ignored temporary Secret artifact. The tracked example contains placeholders
only, and the SMTP password is never placed in `backend-config`.

The rendered Pod template carries a SHA-256 fingerprint of the protected mail
configuration. Changing any SMTP setting and rerunning `k8s-up` therefore
replaces only the backend Pod so Spring receives the new process environment;
PostgreSQL, Redis, MinIO, dashboard, PVs, and PVCs remain unchanged.

## Health and shutdown

All probes use `/api/health`. Per the backend audit contract, this endpoint is a
shallow, dependency-independent process check: readiness does not prove that
PostgreSQL, Redis, or MinIO are usable, and liveness must remain independent of
those services. The startup probe allows approximately 120 seconds for JVM and
Flyway initialization.

Spring graceful shutdown has a 30-second shutdown-phase timeout. Kubernetes
allows 45 seconds before terminating the container, leaving time for Spring to
stop accepting requests and finish in-flight HTTP and WebSocket work.
