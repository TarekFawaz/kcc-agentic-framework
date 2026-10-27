---
# Functional fields
description: Protocol for data pipelines, warehouses and lakes, analytics, and ML or AI features - data contracts, batch versus streaming, ELT layering, idempotent orchestrated jobs, quality gates in CI, PII minimisation, notebook promotion, model evaluation and registry, reproducibility, cost controls, and the verifier conformance check.
inputs: An idea or spec that moves, stores, transforms, analyses or learns from data; the TechnicalDecisionBrief and SecurityDecisionBrief; the selected data or ML dialect.
outputs: Data contracts under the idea workspace, ADR rows for batch versus streaming and layering, quality tests wired into CI, a PII inventory, an evaluation report per model, and a verifier conformance check in the quality gates.

# Obsidian metadata
title: "Data Engineering and Science Protocol"
aliases:
  - data-engineering-and-science
  - data-engineering
  - ml-engineering
tags:
  - framework/protocol
  - data
  - machine-learning
  - standards
created: 2026-10-16
updated: 2026-10-16
version: 1.0.0
status: active
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"
---

# Data Engineering and Science

Selected from context, never always-on. The technical interrogator names this protocol in the brief
when the idea has a pipeline, a warehouse or lake, analytics, or an ML or AI feature; the architect
applies it, the planner carries its rows into `## Standards coverage`, and the verifier runs the
check below. [[standards-catalog]] (Data, Security, Supply chain rows) still applies underneath.

## When it applies

| Applies | Does not apply |
|--|--|
| Batch or streaming pipelines that move data between systems | An application database read and written only by its own service (the catalogue's Data rows suffice) |
| A warehouse, lakehouse, or mart layer that others query | A one-off script a human runs once and deletes |
| Dashboards, reports, or metrics that decisions depend on | Logging and tracing of the app itself (Observability rows) |
| Any ML or AI feature: trained models, calls to a hosted model with retrieval or fine-tuning, recommendation or scoring | A UI that displays numbers an existing API already computes |

Scope is per section: a pipeline-only spec skips the model sections and says so in the plan.

## Data contracts and schema evolution

| Concern | Rule | Framework default |
|--|--|--|
| Contract | every dataset that crosses a team or system boundary has a checked-in contract: schema, types, nullability, keys, freshness SLA, owner, classification | `src/IDEA-{ID}-{slug}/data/contracts/<dataset>.yaml` (JSON Schema, Avro, Protobuf, or dbt `schema.yml` with `contract: enforced`) |
| Evolution | additive changes only within a major; renames and type narrowing are a new major with a deprecation window; consumers pin a major | SemVer on the contract; a schema registry when streaming |
| Compatibility check | contract diff runs in CI and fails on a breaking change | `buf breaking`, registry compatibility mode, or a dbt contract test |
| Time | event time and processing time both recorded; timestamps UTC per RFC 3339 | |

## Batch or streaming

Decide per data flow and record it as an ADR row; "streaming because it is modern" is not a reason.

| Factor | Batch (scheduled jobs) | Streaming (event processing) |
|--|--|--|
| Freshness need | minutes to a day is fine | seconds matter to the consumer (fraud, alerts, live operations) |
| Volume shape | bounded, periodic, replayable from source | unbounded, continuous, source keeps no history |
| Complexity budget | small team, simple failure handling (rerun the day) | team can run brokers, exactly-once semantics, late data, watermarks |
| Cost | compute only while running | always-on infrastructure |
| Default | **micro-batch** (5-15 min) covers most "real-time" dashboards | Kafka, Pulsar, Kinesis or Pub/Sub with Flink, Spark Structured Streaming or Beam |

## Layering, idempotency, orchestration

| Concern | Rule | Framework default |
|--|--|--|
| ELT layering | raw (immutable, as received) -> staging (typed, deduplicated, renamed) -> marts (business entities and metrics); or medallion bronze/silver/gold; nothing reads raw except staging | dbt or SQLMesh models, one folder per layer |
| Idempotency | every job reruns for the same partition and produces the same result: partition overwrite or merge on keys, never blind append; side effects keyed by run id | partitioned by event date; `MERGE` or `INSERT OVERWRITE` |
| Backfill | a job accepts a date range and runs the same code as the daily run | orchestrator parameters, not a second script |
| Orchestration | DAGs declared in code and versioned with the pipeline; retries with backoff; alerts on SLA miss; no cron entries on a host | Airflow, Dagster, or Prefect; Dagster assets for new work |
| Lineage | table- or column-level lineage emitted by the tool and browsable | OpenLineage with Marquez, dbt docs, or the platform catalogue |
| Metrics layer | a metric is defined once (semantic layer or metrics model), not per dashboard | dbt semantic layer or Cube |

## Data quality gates

| Concern | Rule | Framework default |
|--|--|--|
| Tests | not-null, unique, accepted values, referential integrity, freshness and volume checks on every staging and mart model | dbt tests, Great Expectations, Soda, or Pandera for DataFrames |
| CI gate | quality tests run in CI against a sample or a dev target on every change; a failing test blocks merge | `QG-DATA-QUALITY` in `architecture/quality-gates.md` |
| Runtime gate | the same checks run inside the pipeline; a failed check quarantines the partition and alerts instead of publishing bad data | a circuit breaker before the marts layer |
| Reconciliation | row counts and control sums compared against the source for each load | one reconciliation test per source |

## PII and minimisation

| Concern | Rule |
|--|--|
| Inventory | `src/IDEA-{ID}-{slug}/data/pii-inventory.md`: each column that holds personal data, its classification, lawful basis, retention, and the region rules from [[privacy-and-cybersecurity-regions]] |
| Minimisation | collect and copy only the columns a consumer needs; raw keeps PII only when the contract says why; marts use pseudonymous keys |
| Protection | hashing or tokenisation at staging; column-level encryption or masking policies for the rest; access by role and logged |
| Deletion and DSAR | deletion propagates through every layer and derived artifact (features, training sets); a DSAR export query exists per subject key |
| Training data | personal data in training or evaluation sets needs the same lawful basis as the product; the model card documents it |

## Notebooks are not production

A notebook is where an idea is explored, not where it runs. The promotion path:

1. Exploration in a notebook under `notebooks/` with a pinned kernel and a data snapshot reference.
2. Logic extracted into tested modules under `src/IDEA-{ID}-{slug}/`; the notebook imports them.
3. A job or model pipeline calls the modules from the orchestrator; the notebook stays as
   documentation or is deleted.

Nothing scheduled, deployed, or cited by a Test ID executes a notebook. `nbstripout` or an
equivalent keeps outputs out of git.

## Models: tracking, evaluation, serving

| Concern | Rule | Framework default |
|--|--|--|
| Experiment tracking | every training run logs parameters, data version, metrics, and artifacts | MLflow or Weights & Biases |
| Model registry | a model moves staging -> production through the registry with a recorded approval; serving loads by registry version, never by file path | MLflow registry or the platform registry |
| Evaluation gate | offline metrics on a held-out set against a threshold in the plan; comparison with the current production model and a simple baseline; the report is checked in | `src/IDEA-{ID}-{slug}/models/<model>/eval-report.md` behind `QG-MODEL-EVAL` |
| Bias and fairness | metrics sliced by the protected or business-relevant groups the SecurityDecisionBrief names; disparities above the threshold block promotion | Fairlearn, AIF360, or explicit slices |
| Hosted or generative models | prompt and model version pinned; an evaluation set with graded expected outputs; guardrails for injection and data exfiltration; cost per call budgeted | an eval harness with a pass-rate threshold |
| Drift monitoring | input and prediction distributions compared with the training baseline; alert and retrain policy recorded | Evidently or platform monitoring |
| Feature store | only when more than one model shares features or online/offline skew is a real problem; otherwise a versioned feature table | Feast, justified by an ADR |
| Model card | purpose, data, metrics, limitations, owner, retraining cadence | one `MODEL-CARD.md` per model |

## Reproducibility and cost

| Concern | Rule |
|--|--|
| Environments | pinned dependency lockfile and container image per pipeline and per model; the same image trains and serves |
| Seeds and data versions | random seeds fixed and logged; training data referenced by an immutable version (DVC, lakeFS, a Delta or Iceberg snapshot id, or a dated partition) |
| Re-run proof | a fresh run from the recorded inputs reproduces the reported metrics within a stated tolerance |
| Cost controls | warehouse queries carry a per-job budget and timeout; tables partitioned and clustered on the access pattern; retention tiers (hot, warm, cold); GPU jobs sized and time-boxed; spend per pipeline in `technical-budgets.md` |
| Secrets | credentials from the secret store; one least-privilege service account per pipeline |

## Verifier conformance check

When the plan's `## Standards coverage` names this protocol, the verifier runs the rows the plan
marks in scope and reports PASS/FAIL; any FAIL is **CHANGES_NEEDED** citing the file and the rule.

| # | Check | Evidence |
|--|--|--|
| 1 | A contract exists for every dataset that crosses a boundary and a breaking-change check runs in CI | `data/contracts/`, CI config |
| 2 | Batch-vs-streaming and layering recorded as ADR or `## Decisions` rows | architecture files |
| 3 | Jobs are idempotent and backfillable: rerunning one partition yields the same result | a Test ID that runs a job twice and diffs |
| 4 | Quality tests exist on staging and marts and run in CI; a failing test blocks | test files, CI run in `## Evidence` |
| 5 | Orchestration in code with retries and SLA alerts; no host cron | DAG files |
| 6 | PII inventory present and deletion propagates through every layer | `pii-inventory.md`, a deletion Test ID |
| 7 | No notebook is scheduled, deployed, or cited by a Test ID; outputs stripped | repo scan |
| 8 | For any model: tracking configured, registry used, eval report with thresholds and slices checked in, model card present | `eval-report.md`, `MODEL-CARD.md`, registry reference in serving code |
| 9 | Pinned environment, seeds, and data version recorded for the reported run | lockfile, run metadata |
| 10 | Cost budgets and retention tiers recorded | `technical-budgets.md` |

The architect adds `QG-DATA-QUALITY` (and `QG-MODEL-EVAL` when a model exists) to
`architecture/quality-gates.md` when this protocol applies.

## Related

- Standards catalogue: [[standards-catalog]]
- Regional privacy and cybersecurity: [[privacy-and-cybersecurity-regions]]
- API standards (serving endpoints): [[api-standards]]
- Architecture governance: [[architecture-governance]]
- Testing dialects: [[testing-unit]], [[testing-integration]]
