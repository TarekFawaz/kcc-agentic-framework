---
title: Infrastructure Planner Brief Template
tags:
  - framework/agent-ref
updated: 2026-09-21
---

# Infrastructure Planner Brief Template

## InfrastructureDecisionBrief.md

```markdown
# Infrastructure Decision Brief

## Source
{links}

## Deployment Shape
{local | cloud | on-prem | hybrid | agnostic | k8s}

## Packaging
<!-- One row/block per component. Drives the pipeline build/package stages. -->
- Containerized: {yes/no} (base image, multi-stage: ...)
- Artifact type per component: {container image | binary | wheel/jar/nupkg/npm | helm chart | bundle | ...}
- Image registry: {registry + public/private}
- Versioning + tagging: {SemVer/CalVer/git-sha; image tag strategy; source->artifact mapping}
- Distribution channel(s): {internal feed | public registry | container registry | app store (deploy-stage) | ...}
- SBOM / signing / supply-chain: {SBOM format, signing, provenance, scanning needs}
- Artifact -> deploy-target mapping: {which artifact/image runs where}

## Operations Model
- Environments:
- CI/CD:
- Observability:
- Ownership:

## Reliability
- SLO:
- P50/P75/P95/P99:
- DR:
- RPO/RTO:

## Cost Notes
- ...

## Candidate Guardrails
- ...

## Candidate Quality Gates
- ...

## Open Questions
- ...

## Confidence
Confidence: NN%
```

## Packaging Question Bank

Ask or document per component:

- **Containerization**: Docker/OCI? base image, multi-stage, size/hardening; else what runtime form ships.
- **Image registry**: Docker Hub, GHCR, ECR/ACR/GAR, internal/private feed; public/private.
- **Artifact type**: binary, OS package, container image, bundle/zip, language artifact (wheel/sdist, jar/war, npm tarball, nupkg, gem, Go binary), Helm chart.
- **Versioning + tagging**: SemVer / CalVer / git-sha; image tags (`latest`, immutable digests, `vX.Y.Z`, env tags); source version -> artifact/image tag.
- **Distribution channel(s)**: internal feed, public registry (npm/PyPI/NuGet/Maven Central), container registry, app stores (deploy-stage deferred per [[deployment]]), download site, OS repos.
- **SBOM / supply-chain / signing**: SBOM (SPDX/CycloneDX), signing (cosign/Sigstore, GPG), provenance/attestation, dependency/vuln scanning.
- **Artifact -> deploy-target mapping**: which image runs on which K8s workload, which binary on which host, which package feeds which environment.
