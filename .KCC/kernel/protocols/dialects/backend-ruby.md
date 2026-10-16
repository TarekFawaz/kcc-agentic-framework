---
title: Backend Ruby Dialect
tags: [kcc/kernel, dialects, backend, ruby, rails]
created: 2026-10-16
updated: 2026-10-16
version: 0.6.0
status: active
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"
---

# Backend Ruby Dialect

Use for Ruby services: Rails applications and APIs, Sinatra or Rack services, plain Ruby libraries, CLIs, and background workers.

## Coding
- Ruby version pinned in `.ruby-version` and `Gemfile`; dependencies managed with Bundler, `Gemfile.lock` committed for apps and services (not for published gems).
- Frozen string literals, keyword arguments for options, small objects with one responsibility, no monkey patching of core or third-party classes outside an explicit `lib/core_ext/` recorded in the plan.
- Rails: follow Rails conventions (REST resources, strong parameters, concerns kept small, migrations reversible, `config/credentials` for secrets, no secrets in `.env` committed files). Keep controllers thin; business logic in service or use-case objects under `app/services/` or `app/use_cases/`.
- Sinatra/Rack: one `config.ru`, modular apps (`Sinatra::Base`), explicit middleware stack.
- Background jobs with Active Job + Sidekiq or Solid Queue; idempotent jobs, retries with backoff.
- Put application code under `src/` for greenfield KCC non-Rails projects; Rails keeps its own layout (`app/`, `config/`, `db/`, `lib/`, `spec/` or `test/`).

## Review
- Check N+1 queries, missing indexes, unscoped queries, mass assignment, SQL built from strings, transaction boundaries, callbacks that hide behaviour, thread safety under Puma, and error handling (no bare `rescue`).
- Check `Gemfile` diffs: new gems justified and maintained, versions constrained (`~>`), lock file updated, Brakeman and bundler-audit clean.

## Bug Fix
- Reproduce with a failing RSpec or Minitest case, patch the narrowest model, service, or controller, run `bundle exec rubocop`, the test suite, `bundle exec brakeman -q` (Rails), and `bundle exec bundler-audit check --update`.

## Testing
- RSpec (default) or Minitest (acceptable, recorded in the plan); FactoryBot for fixtures, request specs for HTTP, system specs (Capybara) only for critical flows, WebMock/VCR for external HTTP.
- Coverage with SimpleCov; threshold from the quality gate.

## Docs
- README must include Ruby version, Bundler setup, database setup and migration commands, environment variables and credentials approach, run/test/lint commands, and job runner instructions.

## Toolchain
- Ruby (via `rbenv`, `asdf`, or `mise`), Bundler, the database client libraries the Gemfile needs, Node only when the asset pipeline requires it.
- Lint and security: RuboCop (with `rubocop-rails`, `rubocop-rspec`, `rubocop-performance` as applicable) with a committed `.rubocop.yml`, Brakeman for Rails static analysis, bundler-audit for vulnerable gems; all three run in CI.

## Rails conventions and Clean Architecture
- Rails is convention-first; the framework default of Clean Architecture + DDD per [[architecture-styles]] is applied inside those conventions: domain logic in plain Ruby objects (`app/domain/` or `lib/<app>/domain/`), use cases in service objects, Active Record models as persistence adapters with validations and associations only. Do not fight Rails with repositories for every model; record the chosen depth of layering in an ADR.
- Plain Ruby and Sinatra services follow the full layering (domain, application, infrastructure, interface) under `lib/` or `src/`.

## API & Architecture defaults
- When this dialect exposes an HTTP/REST API, follow [[api-standards]]: ship an OpenAPI 3.x document (for example `rswag` or `openapi-rails`) + served Swagger UI (default `/docs`) + verifier-checked route conformance. Waivable only with an ADR.
- Default architecture style is Clean Architecture + DDD per [[architecture-styles]], applied as described above; opt down only for trivial work with an ADR.

## Complexity
- low: junior-safe view, helper, or validation change.
- medium: mid-level resource, service object, migration, and specs.
- high: senior concurrency, background processing, multi-tenant data, or API design.
- extra-high: principal-expert distributed system, upgrade of a major Rails version, or performance-critical path.

## Escalate
- Escalate to the architect for layering depth, new gems with native extensions, data-model migrations with downtime risk, or job infrastructure changes; escalate to a human for credential rotation, data deletion, or production migration windows.
