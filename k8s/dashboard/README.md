# Dashboard Kubernetes Contract

This document describes dashboard-specific manifest behavior. Cluster lifecycle, image-source precedence, Secret generation, CD, and public access are authoritative in the [Kubernetes operations guide](../README.md).

## Workload and service

`deployment.yaml` defines a one-replica `Recreate` Deployment. `service.yaml` exposes the Nginx container through an internal `ClusterIP` Service named `dashboard` on port `80`.

The checked-in image is a placeholder. Orchestration renders an exact private `ghcr.io/mohammad-hamadi/ewsp-dashboard:<full-git-sha>` ref into ignored output and uses `ghcr-pull` with `imagePullPolicy: IfNotPresent`. Do not edit the placeholder to select a deployment image; see [application image resolution](../README.md#application-image-resolution).

## Image and routing contract

The dashboard image is immutable static application output and accepts no runtime API or WebSocket environment variables. Its repository-owned Nginx configuration provides:

```text
/api/ -> http://backend:8080
/ws   -> http://backend:8080/ws  (WebSocket upgrade)
```

The Deployment therefore depends on the same-namespace `backend` Service but contains no environment-specific backend or public hostname. Browser traffic remains on the dashboard origin for the SPA, REST, and STOMP connection.

## Probes

Readiness and liveness request `/index.html`. They verify Nginx and the static bundle only; backend unavailability does not make the dashboard Pod unready or restart it. Full-stack orchestration separately verifies proxied API and WebSocket behavior.
