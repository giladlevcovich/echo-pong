# 🏓 Ping-Pong DevOps Home Assignment

## Overview

This project takes the provided Go Ping-Pong application and builds a production-oriented delivery process around it.

The solution includes:

- A secure multi-stage Docker image
- Support for `linux/amd64` and `linux/arm64`
- Kubernetes deployment using Helm
- High availability and zero-downtime deployment configuration
- Horizontal autoscaling
- Security scanning that blocks releases containing HIGH or CRITICAL vulnerabilities
- Versioned binary releases
- Versioned multi-architecture container releases in GitHub Container Registry (GHCR)
- Separate CI, Release, and Deployment workflows
- Local Kubernetes validation using Kind and Traefik
- A production cloud strategy based on Amazon EKS

---

# Architecture

The implemented development and release lifecycle is:

```text
                         GitHub
                           │
                    Pull Request
                           │
                           ▼
                      CI Workflow
                 ┌─────────┴─────────┐
                 │                   │
             Go validation      Security checks
                 │                   │
                 └─────────┬─────────┘
                           │
                           ▼
                         Merge
                           │
                           ▼
                     main branch
                           │
                    Version tag
                     e.g. v1.0.0
                           │
                           ▼
                   Release Workflow
                 ┌─────────┴─────────┐
                 │                   │
           Binary Release       Container Release
          amd64 + arm64          amd64 + arm64
                 │                   │
                 ▼                   ▼
          GitHub Release             GHCR
                           │
                           ▼
                   Manual Deployment
                           │
                           ▼
                          Helm
                           │
                           ▼
                     Kubernetes
```

For the local Kind environment:

```text
Client
  │
  ▼
Traefik
  │
  ▼
Kubernetes Ingress
  │
  ▼
ClusterIP Service
  │
  ▼
Application Pods
```

For a production EKS environment:

```text
Internet
   │
   ▼
AWS Application Load Balancer
HTTPS / ACM Certificate
   │
   ▼
Kubernetes Ingress
   │
   ▼
ClusterIP Service
   │
   ▼
Application Pods
```

---

# Docker Strategy

The Docker image uses a multi-stage build.

The first stage uses a Go builder image to compile the application. The second stage contains only the compiled application binary and uses a Distroless non-root image.

This provides several advantages:

- The Go compiler is not included in the runtime image.
- The application source code is not included in the runtime image.
- The runtime image has a small attack surface.
- The application runs as a non-root user.
- There is no shell or package manager in the runtime image.
- The application can be compiled independently for `amd64` and `arm64`.
- The final binary is statically compiled using `CGO_ENABLED=0`.

The application module remains compatible with Go 1.24 as defined in `go.mod`.

During development, building with the original Go 1.24 toolchain resulted in HIGH vulnerabilities being detected in the compiled Go standard library by Trivy.

Because the assignment explicitly requires that HIGH and CRITICAL vulnerabilities must not be released, the build pipeline uses a newer patched Go toolchain while maintaining the application's Go 1.24 module compatibility.

The runtime container uses the Distroless non-root user:

```text
UID: 65532
GID: 65532
```

The root filesystem is also configured as read-only at the Kubernetes level.

---

# Kubernetes Deployment

The Kubernetes resources are packaged as a Helm chart instead of maintaining separate duplicated YAML files for each environment.

The chart contains:

- Deployment
- ClusterIP Service
- Ingress
- HorizontalPodAutoscaler
- PodDisruptionBudget

Environment-specific Helm values determine how the Ingress behaves:

```text
Kind
→ Traefik

Amazon EKS
→ AWS Load Balancer Controller / ALB
```

The application Secret is intentionally **not stored inside the Helm chart or Git repository**.

For local testing, the Secret is created separately in Kubernetes and mounted into the application Pod as a read-only file.

```text
Kubernetes Secret
      │
      ▼
/run/secrets/ping-pong-secret
      │
      ▼
SECRET_FILE_PATH
      │
      ▼
Go application
```

This matches the secret-loading mechanism already implemented by the application.

In production EKS, the same Kubernetes Secret can be automatically synchronized from AWS Secrets Manager using External Secrets Operator.

---

# Deployment Strategy

The Deployment is designed to run with a minimum of three replicas.

```yaml
replicaCount: 3
```

The rolling deployment strategy is:

```yaml
strategy:
  type: RollingUpdate
  rollingUpdate:
    maxUnavailable: 0
    maxSurge: 1
```

`maxUnavailable: 0` prevents Kubernetes from intentionally making an existing available Pod unavailable before a replacement Pod becomes ready.

`maxSurge: 1` allows Kubernetes to temporarily create one additional Pod while an update is in progress.

A simplified rollout looks like:

```text
Before deployment

Pod 1 ✅
Pod 2 ✅
Pod 3 ✅


During deployment

Pod 1 ✅
Pod 2 ✅
Pod 3 ✅
Pod 4 starting...


Pod 4 becomes Ready ✅

One old Pod can now be terminated.
```

This configuration, together with readiness probes and multiple replicas, is designed to provide zero-downtime rolling deployments.

---

# Health Checks

The application intentionally waits approximately 10 seconds before starting its HTTP server.

For this reason, three different Kubernetes probes are configured.

## Startup Probe

The startup probe gives the application enough time to complete its startup delay.

Until the startup probe succeeds, Kubernetes does not run the liveness probe.

This prevents Kubernetes from incorrectly restarting the application during its expected startup period.

## Readiness Probe

The readiness probe determines whether a Pod is ready to receive traffic.

Only ready Pods are added to the Service endpoints.

During a rolling deployment, a new Pod therefore does not receive production traffic until it has successfully started.

## Liveness Probe

The liveness probe verifies that an already-running application is still healthy.

If the application becomes unhealthy, Kubernetes can restart the container.

All three probes use:

```text
GET /health
```

---

# Scaling Strategy

The application uses a HorizontalPodAutoscaler.

```yaml
autoscaling:
  enabled: true
  minReplicas: 3
  maxReplicas: 6
  targetCPUUtilizationPercentage: 70
```

The application therefore maintains at least three replicas.

When average CPU utilization increases above the configured target, Kubernetes can increase the number of replicas up to six.

The Pods define CPU and memory resource requests and limits:

```yaml
requests:
  cpu: 50m
  memory: 32Mi

limits:
  cpu: 250m
  memory: 128Mi
```

CPU requests are important because CPU-based HPA calculations compare actual CPU usage against the requested CPU resources.

For the assignment, the temporary Kind deployment installs Metrics Server so that HPA metrics can be validated.

In a real production environment, these values should be tuned based on monitoring and real application usage rather than relying only on initial estimated values.

---

## Cluster-Level Scaling in EKS

HPA scales the number of Pods, but additional Pods also require enough Kubernetes node capacity.

In EKS, I would combine application-level autoscaling with cluster-level scaling using either:

- Karpenter
- EKS-managed node scaling / Cluster Autoscaler

The complete scaling flow could then be:

```text
Application load increases
          │
          ▼
CPU usage increases
          │
          ▼
HPA adds Pods
          │
          ▼
Not enough node capacity?
          │
          ▼
Karpenter / Node Autoscaler
          │
          ▼
Additional EC2 worker capacity
```

This allows both Pods and infrastructure capacity to grow according to demand.

---

# PodDisruptionBudget

The application normally runs at least three replicas and has:

```yaml
pdb:
  enabled: true
  minAvailable: 2
```

This means that during voluntary Kubernetes disruptions, such as node maintenance, at least two application Pods should remain available.

The PodDisruptionBudget complements the Deployment rolling strategy:

```text
Deployment RollingUpdate
→ protects availability during application deployments

PodDisruptionBudget
→ protects availability during voluntary infrastructure disruptions
```

---

# Topology Spread

The application uses topology spread constraints based on:

```yaml
topologyKey: kubernetes.io/hostname
```

The goal is to avoid placing all application replicas on the same Kubernetes node.

For example:

```text
Preferred

Node 1        Node 2        Node 3
  │             │             │
Pod 1         Pod 2         Pod 3
```

instead of:

```text
Node 1        Node 2        Node 3
  │
Pod 1
Pod 2
Pod 3
```

The configuration uses:

```yaml
maxSkew: 1
whenUnsatisfiable: ScheduleAnyway
```

`maxSkew: 1` tries to keep the number of matching Pods between nodes balanced.

`ScheduleAnyway` means Kubernetes prefers spreading the Pods but can still schedule them when the desired distribution is impossible.

This is useful for a small local Kind environment where strict anti-affinity could leave Pods in a Pending state.

---

## Multi-AZ EKS Distribution

In production EKS, I would additionally spread application Pods across AWS Availability Zones using:

```text
topology.kubernetes.io/zone
```

For example:

```text
AZ-A                  AZ-B                  AZ-C
 │                     │                     │
Node                   Node                  Node
 │                     │                     │
Pod 1                  Pod 2                 Pod 3
```

This provides better resilience against both individual node failure and Availability Zone failure.

---

# ARM64 Node Affinity

The assignment states that ARM64 should be preferred.

For this reason, the Deployment contains preferred node affinity for:

```text
kubernetes.io/arch=arm64
```

This means:

```text
ARM64 node available
        ↓
Prefer ARM64

ARM64 unavailable
        ↓
amd64 is still allowed
```

ARM64 is deliberately configured as a preference rather than a hard requirement.

This allows the same Helm chart to work in an amd64 local Kind cluster.

In AWS, I would use ARM64-based AWS Graviton worker nodes where appropriate because the application already provides an ARM64 container image.

The same application can still run on amd64 nodes when required.

---

# Network Exposure

The application itself is **not directly exposed using a Kubernetes NodePort or LoadBalancer Service**.

The application Service remains:

```yaml
type: ClusterIP
```

This means application Pods can only be reached internally through the Kubernetes Service.

External access is provided through an Ingress Controller.

---

## Local Kind Networking

For local testing, Traefik is used.

```text
Windows :80
     │
     ▼
Kind
     │
     ▼
Traefik
     │
     ▼
Ingress
     │
     ▼
ClusterIP Service
     │
     ▼
Application Pods
```

The application can be accessed locally at:

```text
http://ping-pong.localhost
```

Traefik is used for the local development environment only.

---

## Production EKS Networking

In production EKS, I would use the **AWS Load Balancer Controller** instead of Traefik.

The production path would be:

```text
Internet
   │
   ▼
AWS Application Load Balancer
   │
   ▼
Kubernetes Ingress
   │
   ▼
ClusterIP Service
   │
   ▼
Application Pods
```

The AWS Load Balancer Controller watches Kubernetes Ingress resources and creates/manages the required AWS Application Load Balancer.

The Helm chart can therefore use:

```yaml
ingress:
  className: alb
```

instead of:

```yaml
ingress:
  className: traefik
```

used locally.

---

# HTTPS and AWS Certificate Manager

Production application traffic should use HTTPS.

The TLS certificate would be created and managed using **AWS Certificate Manager (ACM)**.

The EKS Ingress would contain AWS Load Balancer Controller annotations similar to:

```yaml
annotations:
  alb.ingress.kubernetes.io/scheme: internet-facing
  alb.ingress.kubernetes.io/target-type: ip
  alb.ingress.kubernetes.io/listen-ports: '[{"HTTP":80},{"HTTPS":443}]'
  alb.ingress.kubernetes.io/ssl-redirect: "443"
  alb.ingress.kubernetes.io/certificate-arn: <ACM_CERTIFICATE_ARN>
```

The architecture becomes:

```text
Client
  │
  │ HTTP :80
  ▼
Application Load Balancer
  │
  └────── redirect
             │
             ▼
          HTTPS :443
             │
             ▼
      ACM TLS Certificate
             │
             ▼
      Kubernetes Service
             │
             ▼
      Application Pods
```

TLS termination happens at the Application Load Balancer.

The application therefore does not need to store or manage TLS certificate private keys.

ACM handles certificate management and renewal.

DNS could be managed through Route 53 and point the application hostname to the Application Load Balancer.

---

# Security Measures

Security is implemented at several different layers.

---

## Container Security

The runtime container:

- Uses Distroless.
- Does not contain the Go compiler.
- Does not contain application source code.
- Does not contain a shell.
- Does not contain a package manager.
- Runs as non-root UID/GID `65532`.
- Uses a statically compiled binary.

Using a minimal runtime image reduces the number of unnecessary packages and therefore reduces the attack surface.

---

## Kubernetes Security Context

The Pod/container security configuration includes:

```yaml
runAsNonRoot: true
runAsUser: 65532
runAsGroup: 65532
readOnlyRootFilesystem: true
allowPrivilegeEscalation: false
```

All Linux capabilities are dropped:

```yaml
capabilities:
  drop:
    - ALL
```

The Pod also uses:

```yaml
seccompProfile:
  type: RuntimeDefault
```

Together these settings reduce what an attacker could do if the application process were compromised.

---

## Kubernetes API Access

The application does not need to communicate with the Kubernetes API.

For that reason, no application-specific RBAC permissions are created.

Automatic ServiceAccount token mounting is also disabled:

```yaml
automountServiceAccountToken: false
```

This follows the principle of least privilege and avoids unnecessarily exposing Kubernetes API credentials inside the application container.

---

# Secret Management

No application secret is:

- Committed to Git
- Stored in Helm values
- Included in the Docker image
- Hardcoded into the application

---

## Local Secret Management

For local Kind testing, the Kubernetes Secret is created separately.

For example:

```bash
kubectl create secret generic ping-pong-secret \
  --namespace ping-pong \
  --from-literal=token="<secret>"
```

The Secret is mounted read-only:

```text
Kubernetes Secret
      │
      ▼
/run/secrets/ping-pong-secret
      │
      ▼
SECRET_FILE_PATH
      │
      ▼
Application
```

---

# Production Secret Management with External Secrets

For production EKS, I would use:

- AWS Secrets Manager
- External Secrets Operator
- EKS Pod Identity or IAM-based workload authentication

The secret value would be stored in AWS Secrets Manager rather than being manually maintained inside Kubernetes.

For example:

```text
/prod/ping-pong/token
```

The flow becomes:

```text
AWS Secrets Manager
        │
        ▼
External Secrets Operator
        │
        ▼
Kubernetes Secret
        │
        ▼
Mounted read-only volume
        │
        ▼
/run/secrets/ping-pong-secret
        │
        ▼
Ping-Pong application
```

An `ExternalSecret` resource would reference the secret stored in AWS.

Conceptually:

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret

metadata:
  name: ping-pong-secret

spec:
  refreshInterval: 1h

  secretStoreRef:
    name: aws-secrets-manager
    kind: ClusterSecretStore

  target:
    name: ping-pong-secret

  data:
    - secretKey: token
      remoteRef:
        key: /prod/ping-pong/token
```

External Secrets Operator would create and maintain the Kubernetes Secret:

```text
ping-pong-secret
```

The existing application Deployment does not need to change.

It continues mounting:

```text
/run/secrets/ping-pong-secret
```

This is useful because the application does not need to know whether the secret originated from a manually-created Kubernetes Secret or from AWS Secrets Manager.

---

## AWS Authentication for External Secrets

External Secrets Operator should not use static AWS access keys.

Instead, I would use an AWS workload identity solution such as **EKS Pod Identity**.

The flow would be:

```text
External Secrets Operator
          │
          ▼
    EKS Pod Identity
          │
          ▼
       IAM Role
          │
          ▼
AWS Secrets Manager
          │
          ▼
 /prod/ping-pong/token
```

The IAM role would receive only the permissions required to retrieve the required application secret.

For example, access would be limited to:

```text
secretsmanager:GetSecretValue
```

for the specific Ping-Pong secret.

This follows least privilege.

It also means that:

- No AWS access keys are committed to Git.
- No AWS credentials exist inside the Docker image.
- Application secrets are centrally managed in AWS.
- Secret rotation does not require rebuilding the Docker image.
- Access to secrets is controlled through IAM.

---

# Security Scanning

Trivy is used at several points in the CI/CD process.

It scans:

- Repository secrets
- Kubernetes configuration
- amd64 container image
- arm64 container image

The workflow is configured to fail when HIGH or CRITICAL vulnerabilities are found.

```text
Build image
    │
    ▼
Trivy scan
    │
    ▼
HIGH / CRITICAL found?
   /             \
 YES             NO
  │               │
 FAIL           Continue
  │               │
  X             Release
```

A release cannot proceed unless both architecture images pass the security gate.

The pipeline deliberately does **not** suppress HIGH or CRITICAL vulnerabilities just to make a release succeed.

The release workflow also publishes the **same image artifacts that were scanned**, instead of rebuilding different container images after security validation.

This ensures that the image being released is the image that passed the vulnerability scan.

---

# CI/CD Pipeline

The pipeline is separated into three workflows:

```text
CI
Release
Deploy
```

Each workflow has a different responsibility.

```text
CI
→ Is the code safe and valid to merge?

Release
→ Create immutable release artifacts.

Deploy
→ Select a released version and deploy it.
```

---

# 1. CI Workflow

The CI workflow runs for Pull Requests targeting `main`.

Trigger:

```yaml
on:
  pull_request:
    branches:
      - main
```

It automatically runs when:

- A Pull Request is opened.
- New commits are pushed to the Pull Request branch.
- The Pull Request is updated.

The CI workflow performs:

```text
Pull Request
      │
      ▼
gofmt
      │
      ▼
go vet
      │
      ▼
go test
      │
      ▼
go build
      │
      ▼
Helm lint
      │
      ▼
Helm template
      │
      ▼
Kubernetes config scan
      │
      ▼
Repository secret scan
      │
      ▼
amd64 image build + Trivy
      │
      ▼
arm64 image build + Trivy
```

The `main` branch uses GitHub branch rules so required CI checks must pass before the Pull Request can be merged.

Therefore:

```text
CI Pending / Failed
        ↓
Merge blocked

CI Passed
        ↓
Merge allowed
```

No application release occurs during the CI stage.

---

# 2. Release Workflow

Merging to `main` does **not** automatically release the application.

A release is an explicit decision.

Semantic version tags are used.

Example:

```bash
git tag v1.0.0
git push origin v1.0.0
```

The Release workflow is triggered by:

```yaml
on:
  push:
    tags:
      - "v*.*.*"
```

Before publishing anything, the release candidate is validated again.

The workflow then produces two types of releases.

---

## Container Release

The container is published to GitHub Container Registry:

```text
ghcr.io/<owner>/<repository>:v1.0.0
```

The version tag contains a multi-architecture image index:

```text
v1.0.0
   │
   ├── linux/amd64
   └── linux/arm64
```

A SHA-based image tag is also created to provide direct traceability to the Git commit.

---

## Binary Release

The workflow also creates GitHub Release assets:

```text
ping-pong-app-linux-amd64.tar.gz
ping-pong-app-linux-arm64.tar.gz
SHA256SUMS
```

This satisfies the requirement to provide both binary and container releases.

---

# 3. Deployment Workflow

Deployment is manually triggered.

The user selects which released version should be deployed.

For example:

```text
version = v1.0.0
```

The deployment flow is:

```text
Manual Deploy
      │
      ▼
Choose release
      │
      ▼
v1.0.0
      │
      ▼
Helm deployment
```

This keeps deployment separate from release creation.

A new release can therefore exist without automatically being placed into production.

---

## Assignment Deployment Validation

For this assignment, there is no permanent production Kubernetes environment.

The Deploy workflow therefore creates a temporary Kind cluster on a GitHub-hosted runner.

The workflow:

1. Resolves the selected GitHub Release.
2. Checks out the matching Git tag.
3. Creates a temporary Kind cluster.
4. Installs the required Kubernetes dependencies.
5. Installs Metrics Server for HPA validation.
6. Creates a temporary application Secret.
7. Deploys the selected released image using Helm.
8. Waits for the rollout to complete.
9. Verifies Kubernetes resources.
10. Verifies the HPA and resource metrics.
11. Runs application smoke tests.
12. Deletes the temporary Kind cluster.

Cleanup uses:

```yaml
if: always()
```

so the temporary cluster is removed whether deployment validation succeeds or fails.

---

## Smoke Tests

The deployment workflow verifies:

```text
GET /health
→ healthy

GET /ping without authentication
→ HTTP 401

GET /ping with valid authentication
→ pong

GET /pong with valid authentication
→ ping
```

This verifies both application health and authentication behavior.

The temporary Kind cluster is only used to validate the deployment.

A real production Deploy workflow would instead target Amazon EKS.

---

# Complete CI/CD Lifecycle

```text
Developer
   │
   ▼
Feature / development branch
   │
   ▼
Pull Request → main
   │
   ▼
CI Workflow
   │
   ├── Go validation
   ├── Helm validation
   ├── Secret scan
   ├── Kubernetes scan
   ├── amd64 build + vulnerability scan
   └── arm64 build + vulnerability scan
   │
   ▼
All required checks pass
   │
   ▼
Merge to main
   │
   ▼
Create semantic version tag
   │
   ▼
v1.0.0
   │
   ▼
Release Workflow
   │
   ├── Validate again
   ├── Build binaries
   ├── Build container images
   ├── Security scan
   ├── Publish GitHub Release
   └── Publish GHCR multi-architecture image
   │
   ▼
Manual Deploy Workflow
   │
   ▼
Choose version
   │
   ▼
Helm deploy
   │
   ▼
Kubernetes
```

---

# Multi-Architecture Builds

Both the binary and container image support:

```text
linux/amd64
linux/arm64
```

The Dockerfile uses BuildKit target variables:

```text
TARGETOS
TARGETARCH
```

The Go build uses:

```text
GOOS
GOARCH
```

Because the application is written in Go and compiled using:

```text
CGO_ENABLED=0
```

it can be cross-compiled without requiring native compilation on both CPU architectures.

---

## Multi-Architecture Container Release

The workflow builds and scans the two architectures independently:

```text
amd64 build
    │
    ▼
Trivy
    │
    └── must pass

arm64 build
    │
    ▼
Trivy
    │
    └── must pass
```

Only after both pass does the workflow create the final multi-platform image.

```text
ghcr.io/<owner>/<repo>:v1.0.0
               │
        ┌──────┴──────┐
        ▼             ▼
 linux/amd64      linux/arm64
```

When the image is pulled, the container runtime automatically selects the appropriate image for the host architecture.

For example:

```text
amd64 Kubernetes node
→ pulls amd64 image

ARM64 Kubernetes node
→ pulls arm64 image
```

---

# Versioning and Tagging Strategy

The project uses Semantic Versioning:

```text
vMAJOR.MINOR.PATCH
```

Examples:

```text
v1.0.0
v1.0.1
v1.1.0
v2.0.0
```

The semantic version is used as the human-readable application release identifier.

The release workflow also publishes a SHA-based tag:

```text
sha-<git-commit>
```

The two tag types provide different benefits:

```text
v1.0.0
→ human-readable release version

sha-abc123...
→ exact Git source traceability
```

Production deployments should use an explicit version rather than relying on:

```text
latest
```

This makes both deployment and rollback predictable.

---

# Rollback Strategy

Because releases are immutable and versioned, rollback does not require rebuilding the application.

For example:

```text
v1.0.0 ✅
v1.1.0 ✅
v1.2.0 ❌
```

If `v1.2.0` introduces a problem, the operator can run the Deploy workflow again and select:

```text
v1.1.0
```

The previous already-built and already-scanned artifact is deployed.

```text
Problem with v1.2.0
       │
       ▼
Deploy workflow
       │
       ▼
version = v1.1.0
       │
       ▼
Helm upgrade
       │
       ▼
Rollback
```

This is safer than rebuilding old source code during an incident.

---

# Going to AWS / Amazon EKS

For production, I would reuse the same Helm chart on Amazon EKS instead of creating a completely different deployment solution.

The main differences would be infrastructure and environment-specific Helm configuration.

A production architecture could look like:

```text
                       Internet
                          │
                          ▼
                       Route 53
                          │
                          ▼
              Application Load Balancer
                    HTTP / HTTPS
                          │
                    ACM Certificate
                          │
                          ▼
               Kubernetes Ingress
                          │
                          ▼
                ClusterIP Service
                          │
             ┌────────────┼────────────┐
             ▼            ▼            ▼
           Pod 1        Pod 2        Pod 3
            │             │             │
           AZ-A          AZ-B          AZ-C
```

---

# EKS Infrastructure

I would provision:

- Amazon EKS across multiple Availability Zones
- Managed Node Groups and/or Karpenter
- ARM64 AWS Graviton worker nodes as preferred capacity
- amd64 capacity where required
- AWS Load Balancer Controller
- AWS Certificate Manager
- Route 53 for DNS
- External Secrets Operator
- AWS Secrets Manager
- Metrics Server / monitoring components
- Appropriate IAM roles and EKS Pod Identity associations

The existing Helm deployment logic can remain mostly unchanged.

---

# AWS Load Balancer Controller

The local Kind environment uses Traefik.

The production EKS environment would instead use the **AWS Load Balancer Controller**.

The controller watches Kubernetes Ingress resources and provisions an AWS Application Load Balancer.

Environment-specific Helm values could look like:

## Kind

```yaml
ingress:
  enabled: true
  className: traefik
```

## EKS

```yaml
ingress:
  enabled: true
  className: alb
```

This allows the same application chart to work in both environments.

---

# Production HTTPS with ACM

AWS Certificate Manager would manage the public TLS certificate.

The EKS Ingress would reference the certificate ARN.

Example:

```yaml
annotations:
  alb.ingress.kubernetes.io/scheme: internet-facing
  alb.ingress.kubernetes.io/target-type: ip
  alb.ingress.kubernetes.io/listen-ports: '[{"HTTP":80},{"HTTPS":443}]'
  alb.ingress.kubernetes.io/ssl-redirect: "443"
  alb.ingress.kubernetes.io/certificate-arn: <ACM_CERTIFICATE_ARN>
```

The request flow would be:

```text
User
 │
 ▼
Route 53
 │
 ▼
ALB :80 / :443
 │
 ├── HTTP → redirect to HTTPS
 │
 ▼
HTTPS
 │
 ▼
ACM Certificate
 │
 ▼
Kubernetes Ingress
 │
 ▼
ClusterIP Service
 │
 ▼
Application Pods
```

TLS terminates at the ALB.

The application itself therefore does not need to manage TLS certificates or private keys.

---

# Deploying from GitHub Actions to EKS

For production, GitHub Actions should authenticate to AWS using **OIDC** rather than permanent AWS access keys stored as GitHub Secrets.

The flow would be:

```text
GitHub Actions
      │
      ▼
GitHub OIDC
      │
      ▼
AWS IAM Role
      │
      ▼
Temporary AWS credentials
      │
      ▼
aws eks update-kubeconfig
      │
      ▼
Helm upgrade --install
      │
      ▼
Amazon EKS
```

The deployment IAM role should follow least privilege and contain only the permissions required for deployment.

The workflow would still require an explicit released version:

```text
Deploy
  │
  ▼
v1.0.0
  │
  ▼
EKS
```

This keeps the same release/deploy separation used in the assignment.

---

# Global Container Distribution

The assignment requires released container images to be stored in GitHub Container Registry, so GHCR remains the release source of truth.

```text
GitHub Release
      │
      ▼
GHCR
```

For geographically distributed AWS environments, pulling every image from a single remote registry may introduce unnecessary latency.

I would therefore use Amazon ECR closer to the workloads.

---

## ECR Pull Through Cache

One option is to configure Amazon ECR Pull Through Cache with GHCR as an upstream registry.

Conceptually:

```text
                        GHCR
                         │
             ┌───────────┼───────────┐
             │           │           │
             ▼           ▼           ▼
        ECR Europe     ECR US     ECR Asia
             │           │           │
             ▼           ▼           ▼
          EU EKS       US EKS      Asia EKS
```

The first pull retrieves the image from the upstream registry.

Subsequent pulls can use the cached image from the AWS Region closer to the workload.

This reduces repeated long-distance image downloads.

---

## ECR Cross-Region Replication

Another option would be to mirror approved production releases into ECR and configure cross-Region replication.

For example:

```text
GHCR
 │
 ▼
ECR eu-west-1
 │
 ├──────────────► ECR us-east-1
 │
 └──────────────► ECR ap-southeast-1
```

Regional EKS clusters can then pull from their nearest AWS ECR registry.

---

# Managing Older and Stale Versions

Old images should not all be deleted immediately because previous versions are needed for rollback.

I would separate application images into two categories.

---

## Stable Release Versions

Examples:

```text
v1.0.0
v1.0.1
v1.1.0
```

Stable versions should follow a defined retention policy.

For example:

- Keep the current production release.
- Keep several previous stable releases for rollback.
- Keep releases still used by any active environment.
- Remove releases only after they are outside the defined support/rollback window.

---

## Temporary and Technical Versions

Examples:

```text
sha-abc123
v1.0.0-amd64
v1.0.0-arm64
untagged manifests
```

These can have a shorter retention period.

I would create a scheduled cleanup workflow that:

1. Lists GHCR package versions.
2. Identifies the currently deployed versions.
3. Protects recent stable releases.
4. Protects versions required for rollback.
5. Deletes old temporary or untagged versions.
6. Deletes old technical architecture tags when they are no longer required.

The rule should never blindly delete images based only on age.

The currently deployed release and rollback candidates must always be protected.

---

## ECR Cleanup

If images are mirrored into Amazon ECR, I would also configure ECR lifecycle policies.

For example:

```text
Stable semantic versions
→ keep according to release policy

Old untagged images
→ expire automatically

Temporary image tags
→ shorter retention

Currently deployed releases
→ protected
```

This prevents uncontrolled registry growth while preserving safe rollback options.

---

# Local Testing

Kind is used as the local Kubernetes environment.

Traefik is used as the local Ingress Controller.

The local architecture is:

```text
Windows :80
     │
     ▼
Kind
     │
     ▼
Traefik
     │
     ▼
Ingress
     │
     ▼
ClusterIP Service
     │
     ▼
3 application Pods
```

The local container image can be loaded into Kind using:

```bash
kind load docker-image ping-pong:local --name kind
```

The namespace and local application Secret are created before deploying the application.

The application is then installed through Helm.

Example:

```bash
helm upgrade --install ping-pong ./k8s/helm/ping-pong \
  --namespace ping-pong \
  --create-namespace \
  --set-string image.repository=ping-pong \
  --set-string image.tag=local \
  --set image.pullPolicy=IfNotPresent \
  --wait \
  --timeout 5m
```

The application can be tested through Traefik at:

```text
http://ping-pong.localhost/health
```

Protected endpoints require:

```text
Authorization: Bearer <token>
```

For example:

```text
GET /ping
Authorization: Bearer <token>

→ pong
```

---

# Local vs Production Architecture

The Helm chart is intended to stay reusable between environments.

The infrastructure surrounding it changes.

```text
LOCAL / KIND
────────────────────────

Kind
Traefik
HTTP localhost
Manual Kubernetes Secret
Local Docker image


PRODUCTION / AWS
────────────────────────

Amazon EKS
AWS Load Balancer Controller
Application Load Balancer
HTTPS
AWS Certificate Manager
Route 53
External Secrets Operator
AWS Secrets Manager
EKS Pod Identity / IAM
GHCR / regional ECR
Graviton ARM64 nodes
Multi-AZ deployment
```

This keeps the application deployment portable while using cloud-native AWS services in production.

---

# Summary

The solution focuses on four main goals.

## Reliability

- Three minimum application replicas
- RollingUpdate strategy
- `maxUnavailable: 0`
- `maxSurge: 1`
- Startup probe
- Readiness probe
- Liveness probe
- PodDisruptionBudget
- Node topology spreading
- Multi-AZ topology spreading in EKS
- HorizontalPodAutoscaler
- Cluster-level scaling strategy

---

## Security

- Distroless runtime image
- Non-root container
- Read-only root filesystem
- No privilege escalation
- All Linux capabilities dropped
- RuntimeDefault seccomp profile
- No unnecessary Kubernetes API credentials
- No application secrets committed to Git
- No secrets inside the Docker image
- External Secrets Operator + AWS Secrets Manager in production
- IAM-based AWS authentication
- HTTPS through ALB
- ACM-managed certificates
- Trivy repository scanning
- Trivy Kubernetes configuration scanning
- Trivy image scanning
- HIGH/CRITICAL vulnerability release gate

---

## Release Management

- Separate CI, Release and Deployment workflows
- Pull Request CI protection
- Semantic versioning
- Immutable release versions
- Binary releases
- Multi-architecture container releases
- amd64 support
- arm64 support
- Commit SHA traceability
- Explicit deployment version selection
- Simple rollback to previous releases
- Registry retention and stale-image cleanup strategy

---

## Cloud Readiness

- Same Helm chart can be reused on Amazon EKS
- Environment-specific Helm values
- AWS Load Balancer Controller
- Application Load Balancer
- HTTPS using AWS Certificate Manager
- Route 53 DNS
- ClusterIP-only application Service
- ARM64 / AWS Graviton support
- Multi-AZ deployment
- HPA + Karpenter / node scaling
- GitHub Actions authentication to AWS using OIDC
- External Secrets Operator
- AWS Secrets Manager
- EKS Pod Identity / least-privilege IAM
- GHCR as the release registry
- Regional ECR caching or replication for global workloads
- Lifecycle policies for stale image cleanup