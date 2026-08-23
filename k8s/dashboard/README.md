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
placeholder and must be replaced before deployment. `ewsp-local` tags clean
dashboard builds as `ewsp-dashboard:<commit12>-<build-input-hash12>` and dirty
builds as `ewsp-dashboard:dirty-<commit>-<session>`. This avoids pinning a stale
commit or using `latest`.

Render the Deployment with the selected immutable local tag without editing the
checked-in manifest:

```powershell
$dashboardImage = 'ewsp-dashboard:<actual-ewsp-local-tag>'
kubectl set image -f k8s/dashboard/deployment.yaml `
  dashboard=$dashboardImage --local -o yaml |
  kubectl apply -f -
```

The selected image must be visible through Docker Desktop's shared local image
store or local registry mirror. `imagePullPolicy: IfNotPresent` then uses that
local image without requiring a public registry.

## Health checks

Readiness and liveness request `/index.html` from Nginx. They check only the
dashboard process and static bundle, so backend availability cannot make the
dashboard pod unready or trigger a restart. Nginx startup is sufficiently fast
that a separate startup probe is unnecessary.
