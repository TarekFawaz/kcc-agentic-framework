---
# Functional fields
description: Catalogue of widely adopted engineering standards (security, API, data, quality, operations, accessibility, supply chain, delivery) with the framework default for each, so architects and planners cite a known standard instead of leaving a decision open.
inputs: The idea brief, TechnicalDecisionBrief, specialist briefs (security, infrastructure, UX), and the selected architecture style.
outputs: ADRs, guardrails, quality gates, and plan items that name the standard they follow and the concrete library or setting that implements it.

# Obsidian metadata
title: "Standards Catalogue"
aliases:
  - standards-catalog
  - standards-catalogue
  - known-standards
tags:
  - framework/protocol
  - architecture
  - standards
created: 2026-10-15
updated: 2026-10-15
version: 1.0.0
status: active
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"
---

# Standards Catalogue

The architect and the planner start from this catalogue. When a decision follows the default listed
here, the ADR cites the standard and is **standard-backed**: it needs no human tie-break, even under
`--silent --assume` or `--fasttrack` ([[architecture-governance]] -> *ADR status under --silent
--assume and fasttrack*). Deviating from a default is allowed, but it needs its own ADR that names
the reason.

Two rules apply to every row:

1. **Name the implementation.** An ADR that adopts a standard names the concrete library, package,
   or setting and a supported version range (for example `argon2` with OWASP parameters,
   `fastify@^5`, runtime `node >=20`). "Generate OpenAPI from schemas" is not a decision until it
   names the generator.
2. **Check the current edition.** Standards are versioned. Cite the edition in force when the ADR is
   written (look it up when unsure); the parameters below are the floor, not a ceiling.

## Security

| Concern | Standard | Framework default |
|--|--|--|
| Verification baseline | OWASP ASVS (current major), OWASP Top 10 (latest edition) | ASVS level 1 for every app, level 2 when the app stores personal or financial data; Top 10 items become guardrails |
| Password storage | OWASP Password Storage Cheat Sheet; NIST SP 800-63B | Argon2id (at least m=19 MiB, t=2, p=1), else scrypt, bcrypt only for legacy; min length 8 (15 for single-factor), max >= 64, no composition rules, check against breached-password lists |
| Sessions | OWASP Session Management Cheat Sheet | server-side session id in a cookie: `HttpOnly`, `Secure`, `SameSite=Lax` (or `Strict`), rotated on login and privilege change, idle and absolute timeouts |
| CSRF | OWASP CSRF Prevention Cheat Sheet | for cookie sessions: `SameSite` plus a synchronizer token or signed double-submit cookie on every state-changing request |
| Tokens and delegated auth | OAuth 2.0 (RFC 6749) with the OAuth 2.1 profile, OpenID Connect, JWT (RFC 7519) | use an identity provider for third-party login; for first-party web apps prefer cookie sessions over browser-stored JWTs; PKCE for public clients |
| Authorization and data isolation | OWASP Authorization Cheat Sheet | deny by default; ownership enforced server-side in one place (query scoping), tested with two users |
| Input handling | OWASP Input Validation, Injection Prevention | schema validation at every boundary; parameterised queries only; output encoding in the UI |
| Rate limiting and lockout | OWASP Authentication Cheat Sheet | throttle login and sign-up per account and per IP; generic error messages |
| Secrets | OWASP Secrets Management Cheat Sheet; Twelve-Factor config | secrets from the environment or a secret store, never in the repo; `.env.example` lists names only |
| Security headers | OWASP Secure Headers Project | CSP, `X-Content-Type-Options`, `Referrer-Policy`, HSTS behind TLS |
| Logging of security events | OWASP Logging Cheat Sheet | log auth events and access failures; never log secrets, tokens, passwords, or full personal data |

## APIs

| Concern | Standard | Framework default |
|--|--|--|
| Contract | OpenAPI 3.1 ([[api-standards]]) | contract-first or code-first with a named generator; Swagger UI at `/docs`; conformance test |
| HTTP semantics | RFC 9110 | correct methods and status codes; `GET` safe, `PUT`/`DELETE` idempotent |
| Errors | RFC 9457 Problem Details | `application/problem+json` with `type`, `title`, `status`, `detail`, plus field errors |
| Pagination and links | RFC 8288 Web Linking | cursor pagination for growing collections; `Link` headers or `next` cursors |
| Retries | IETF `Idempotency-Key` header (httpapi draft) | idempotency keys on `POST` that create money-like or duplicate-sensitive records |
| Versioning | SemVer 2.0.0 for the contract | additive changes only within a major; breaking change = new major + deprecation window |
| Time and dates | RFC 3339 / ISO 8601 | timestamps in UTC with offset; dates as `YYYY-MM-DD` |

## Data

| Concern | Standard | Framework default |
|--|--|--|
| Money | ISO 4217 | integer minor units plus currency code; never binary floating point |
| CSV import and export | RFC 4180 | quoted fields, header row, explicit encoding (UTF-8), size and row limits |
| Schema change | expand / migrate / contract | forward-only, numbered migrations; reversible where data allows |
| Personal data | GDPR principles (lawfulness, minimisation, storage limitation) | collect the minimum, define retention, support export and deletion when users are people |
| Identifiers | RFC 9562 (UUID) | UUIDv7 or ULID for public ids; never expose sequential ids that leak counts when that matters |

## Quality and operations

| Concern | Standard | Framework default |
|--|--|--|
| Quality attributes | ISO/IEC 25010 | `architecture/nfrs.md` uses its characteristics (performance efficiency, reliability, security, maintainability, usability, compatibility, portability) |
| App configuration and deploy | The Twelve-Factor App | config in the environment, stateless processes, logs to stdout, dev/prod parity |
| Observability | OpenTelemetry; W3C Trace Context | structured JSON logs with a request id; health and readiness endpoints; traces when there is more than one service |
| Reliability targets | SRE practice (SLI, SLO, error budget) | one availability and one latency SLO per user-facing service in `technical-budgets.md` |
| Containers | CIS Docker Benchmark | non-root user, pinned base image digest or version, minimal image, health check, read-only filesystem where possible |
| Testing | test pyramid; [[testing-unit]], [[testing-integration]] | most tests at unit level, integration per adapter, a thin end-to-end layer; coverage floor from settings |

## Accessibility and UX

| Concern | Standard | Framework default |
|--|--|--|
| Accessibility | WCAG 2.2 level AA | keyboard reachable, visible focus, contrast >= 4.5:1, labels for inputs, automated axe checks in CI |
| Internationalisation | Unicode CLDR via the platform `Intl` APIs | locale-aware number, currency, and date formatting |

## Supply chain and delivery

| Concern | Standard | Framework default |
|--|--|--|
| Dependencies | lockfile committed; OSV database | `npm`/`pnpm`/`pip` audit or `osv-scanner` in the quality gate; no unpinned installs in CI |
| Build provenance | SLSA | build in CI from a clean checkout; record the build |
| Software bill of materials | CycloneDX or SPDX | SBOM for every deployable artifact |
| Versioning and history | SemVer 2.0.0; Conventional Commits | release tags; commit subjects per [[git-workflow]] |
| Licences | SPDX licence identifiers | record each dependency licence; flag copyleft in a commercial product |

## Related

- Architecture styles: [[architecture-styles]]
- API standards: [[api-standards]]
- Architecture governance: [[architecture-governance]]
- Toolchain preflight: [[toolchain-preflight]]
