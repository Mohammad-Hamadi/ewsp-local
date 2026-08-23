# EWSP Kubernetes infrastructure

These plain manifests define the local EWSP infrastructure in the `ewsp`
namespace. They use internal `ClusterIP` services only. PostgreSQL and MinIO
request dynamically provisioned storage from the cluster's default StorageClass;
Redis is intentionally non-persistent.

## Local secrets

`config/secrets.example.yaml` documents the required Secret name and keys. It
contains placeholders only and is safe to validate, but must not be used as the
real Secret.

For local use, copy the example to the ignored `.tmp` directory, replace every
placeholder, and apply that local file before starting the workloads:

```powershell
Copy-Item k8s/config/secrets.example.yaml .tmp/secrets.local.yaml
# Edit .tmp/secrets.local.yaml without committing it.
kubectl apply -f k8s/namespace.yaml
kubectl apply -f .tmp/secrets.local.yaml
```

Apply the non-secret configuration and workloads only after the real Secret
exists. Bucket initialization is deliberately omitted: the application retains
its existing lazy bucket-creation behavior.
