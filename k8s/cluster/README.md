# Local Kubernetes Cluster

This directory contains the configuration for the local `echo-pong` Kind
cluster and its Traefik ingress controller.

The cluster has one control-plane node and two worker nodes. Traefik runs two
replicas with required pod anti-affinity, so the replicas are scheduled on
different workers.

## Prerequisites

Install and start the following tools before creating the cluster:

- Docker Desktop using the Linux container engine
- Kind
- `kubectl`
- Helm

Verify that they are available:

```powershell
docker version
kind version
kubectl version --client
helm version
```

Run all commands below from the repository root.

## 1. Create the Kind cluster

```powershell
kind create cluster `
  --config k8s/cluster/kind-config.yaml `
  --wait 240s
```

Kind sets the active kubectl context to `kind-echo-pong`. Verify the cluster
and its three nodes:

```powershell
kubectl config current-context
kubectl get nodes -o wide
kubectl cluster-info --context kind-echo-pong
```

Expected nodes:

- `echo-pong-control-plane`
- `echo-pong-worker`
- `echo-pong-worker2`

## 2. Install Traefik

Add and update the official Traefik Helm repository:

```powershell
helm repo add traefik https://traefik.github.io/charts --force-update
helm repo update traefik
```

Install the pinned chart version with this repository's values:

```powershell
helm upgrade --install traefik traefik/traefik `
  --version 41.2.0 `
  --namespace traefik `
  --create-namespace `
  --values k8s/cluster/traefik-values.yaml `
  --wait `
  --rollback-on-failure `
  --timeout 5m
```

The pinned chart installs Traefik `v3.7.10`.

## 3. Verify Traefik

```powershell
helm status traefik --namespace traefik
kubectl get pods --namespace traefik -o wide
kubectl get service traefik --namespace traefik
kubectl get poddisruptionbudget traefik --namespace traefik
kubectl get ingressclass traefik
```

There should be two ready Traefik pods, with one pod on each worker. The
service should expose these NodePorts:

| Traffic | Host address | Kind NodePort |
|---|---|---:|
| HTTP | `http://127.0.0.1:8080` | `30080` |
| HTTPS | `https://127.0.0.1:8443` | `30443` |

Test that the controller is reachable from Windows:

```powershell
curl.exe -i http://127.0.0.1:8080/
```

An HTTP `404` response is expected until an application `Ingress` resource is
deployed. Application ingresses must set:

```yaml
spec:
  ingressClassName: traefik
```

## Recreate the cluster

Kind cluster topology is immutable. After changing `kind-config.yaml`, delete
and recreate the cluster, then reinstall Traefik:

```powershell
kind delete cluster --name echo-pong
kind create cluster --config k8s/cluster/kind-config.yaml --wait 240s
```

Then repeat the Helm installation command from step 2.

## Cleanup

To remove only Traefik:

```powershell
helm uninstall traefik --namespace traefik
```

To remove the complete local cluster:

```powershell
kind delete cluster --name echo-pong
```
