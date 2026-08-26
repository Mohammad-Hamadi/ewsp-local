# Backend Kubernetes Contract

This document describes backend-specific manifest behavior. Cluster lifecycle, image-source precedence, Secret generation, persistence, CD, and tunnel operations are authoritative in the [Kubernetes operations guide](../README.md).

## Workload and service

`deployment.yaml` defines a one-replica `Recreate` Deployment. `service.yaml` exposes an internal `ClusterIP` Service named `backend` on port `8080`. REST under `/api` and native STOMP WebSocket traffic at `/ws` share that port.

The single replica and in-process STOMP simple broker are a deliberate local/deployment baseline. Multi-replica message distribution is not implemented.

The checked-in image is a placeholder. Orchestration renders an exact private `ghcr.io/mohammad-hamadi/ewsp-backend:<full-git-sha>` ref into ignored output and uses `ghcr-pull` with `imagePullPolicy: IfNotPresent`. Do not edit the placeholder to select a deployment image; see [application image resolution](../README.md#application-image-resolution).

## Runtime configuration

The Pod loads non-secret settings from `backend-config` and references individual keys in `ewsp-infrastructure-secrets` for:

- PostgreSQL credentials;
- MinIO credentials;
- the JWT signing secret;
- SMTP/OTP delivery settings.

Pod-template fingerprints cover the complete ConfigMap data and protected mail configuration. A relevant configuration change followed by `k8s-up` replaces only the backend Pod so the new process environment is loaded.

## Mobile release metadata

`configmap.yaml` is the Kubernetes authority for the release advertised by `GET /api/mobile/version`:

```text
EWSP_MOBILE_LATEST_VERSION=1.0.2
EWSP_MOBILE_LATEST_VERSION_CODE=3
EWSP_MOBILE_UPDATE_URL=https://github.com/Mohammad-Hamadi/ewsp-mobile/releases/download/v1.0.2/ewsp-1.0.2.apk
```

These public values belong in the ConfigMap, not a Secret. For a new release:

1. Publish and verify the signed APK from `ewsp-mobile`.
2. Update all three values in `k8s/backend/configmap.yaml`.
3. Update the matching Compose defaults in `compose.yml` and `.env.example`.
4. Run `.\ewsp.ps1 k8s-up` and verify `/api/mobile/version`.

This is a runtime metadata rollout. It does not rebuild an application image or modify PostgreSQL, Redis, MinIO, PVs, or PVCs. The image-only `deploy` workflow does not independently apply ConfigMap revisions.

## Probes and shutdown

Startup, readiness, and liveness probes call `/api/health`. The endpoint is a shallow process check and does not prove PostgreSQL, Redis, or MinIO availability. Startup permits approximately 120 seconds for JVM and Flyway initialization.

Spring graceful shutdown has a 30-second phase timeout. Kubernetes allows 45 seconds before termination so in-flight HTTP and WebSocket work can finish.
