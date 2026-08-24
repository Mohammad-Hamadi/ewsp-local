# EWSP dashboard Kubernetes contract

The dashboard runs as one Nginx pod behind the internal `dashboard` ClusterIP
Service. The image is immutable application output: the manifests provide no
runtime API or WebSocket environment variables.

The image's Nginx configuration preserves the same-origin contract:

- `/api` proxies to `http://backend:8080`.
- `/ws` proxies to `http://backend:8080/ws` with WebSocket upgrades.

This requires the same-namespace `backend` Service on port 8080, which is
defined by `k8s/backend/service.yaml`. No environment-specific domain is part of
the dashboard Deployment.

## Image tag

The checked-in image `ewsp-dashboard:replace-with-ewsp-local-tag` is an explicit
environment-independent placeholder. `k8s-up` replaces it only in ignored
rendered output with `EWSP_DASHBOARD_IMAGE`, which must be the private
`ghcr.io/mohammad-hamadi/ewsp-dashboard` image tagged by a full Git SHA.

Render the Deployment with the selected immutable local tag without editing the
checked-in manifest:

```powershell
$dashboardImage = 'ghcr.io/mohammad-hamadi/ewsp-dashboard:<full-git-sha>'
kubectl set image -f k8s/dashboard/deployment.yaml `
  dashboard=$dashboardImage --local -o yaml |
  kubectl apply -f -
```

`imagePullPolicy: IfNotPresent` permits cache reuse, while the `ghcr-pull`
`imagePullSecret` lets Kubernetes obtain a missing private image. `k8s-up`
creates that Secret from ignored local credentials and never builds this image.

## Health checks

Readiness and liveness request `/index.html` from Nginx. They check only the
dashboard process and static bundle, so backend availability cannot make the
dashboard pod unready or trigger a restart. Nginx startup is sufficiently fast
that a separate startup probe is unnecessary.
