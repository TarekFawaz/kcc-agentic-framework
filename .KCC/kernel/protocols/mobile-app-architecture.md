---
# Functional fields
description: Architecture protocol for user-facing mobile deliverables (iOS, Android, and hybrid stacks) - the native-vs-hybrid decision, layering and state, offline and sync, device security, release pipeline, the mobile test pyramid, and the verifier conformance check.
inputs: An idea or spec whose deliverable runs on a phone or tablet, the TechnicalDecisionBrief, UXDecisionBrief and SecurityDecisionBrief, and the selected mobile dialect.
outputs: An ADR for native vs hybrid, mobile rows in guardrails, quality gates, technical budgets and NFRs, and a verifier conformance check wired into the quality gates.

# Obsidian metadata
title: "Mobile App Architecture Protocol"
aliases:
  - mobile-app-architecture
  - mobile-architecture
tags:
  - framework/protocol
  - architecture
  - mobile
  - standards
created: 2026-10-16
updated: 2026-10-16
version: 1.0.0
status: active
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"
---

# Mobile App Architecture

Selected from context, never always-on. The technical interrogator names this protocol in the brief
when the deliverable is a mobile app; the architect applies it, the planner carries its rows into
`## Standards coverage`, and the verifier runs the check below. It sits on top of
[[standards-catalog]] (security, data and supply-chain rows still apply) and the mobile dialects
[[mobile-flutter]], [[mobile-kotlin]] and [[mobile-swift]], which hold the per-stack idioms.

## When it applies

| Applies | Does not apply |
|--|--|
| Any user-facing deliverable installed on a phone or tablet: native iOS or Android, Flutter, React Native, Kotlin Multiplatform (KMP), Capacitor or Ionic | A responsive web app with no store listing (the UX brief and web dialects govern it) |
| A mobile client of a larger system, even when the backend is the main work | A backend that happens to serve mobile clients (apply [[api-standards]] there) |
| A store-published PWA wrapper or kiosk app | A CLI, desktop, or embedded firmware deliverable |

## Native or hybrid

Decide once, early, and record it as an ADR (`ADR-000N-mobile-platform`) naming the stack, its
version range, and the rejected alternatives. When nothing below forces a choice, the default is one
hybrid codebase (Flutter or React Native) for both platforms; native wins when the table says so.

| Factor | Prefer native (Swift / Kotlin) | Prefer hybrid (Flutter, React Native, KMP, Capacitor) |
|--|--|--|
| Team | existing iOS and Android teams, or one platform only | one team, web or Dart skills, both platforms wanted |
| Platform features | deep OS integration: widgets, watch, CarPlay or Android Auto, ARKit or ML Kit, background audio, Bluetooth LE, accessibility services | mostly screens over an API; platform features reachable through maintained plugins |
| Performance | 60-120 fps animation, camera or audio pipelines, heavy list rendering | CRUD, forms, dashboards, content; render budget met in a spike on a low-end device |
| Timeline and budget | time allows two codebases, or one platform ships first | one codebase must reach both stores in the same release |
| Longevity | platform-first product with a long maintenance horizon | shared web code (Capacitor) or shared business logic (KMP) is the asset |
| Middle paths | KMP: shared domain and data layers in Kotlin, native UI per platform | Capacitor: an existing web app that needs a store presence; not a default for new products |

## Layering and state

| Concern | Rule | Framework default |
|--|--|--|
| Layers | presentation, domain, data; dependencies point inward; the domain layer has no platform or UI imports | feature-first folders, each with the three layers |
| Presentation pattern | MVVM or MVI with unidirectional data flow: state flows down, events flow up; no business logic in widgets or views | MVVM for Swift and Kotlin, MVI or BLoC for Flutter, reducer pattern for React Native |
| State management | one documented mechanism per app, chosen in the ADR; ephemeral UI state stays local | Riverpod or BLoC (Flutter), ViewModel + StateFlow (Kotlin), Observation or TCA (Swift), Redux Toolkit or Zustand (React Native) |
| Navigation | typed routes declared in one place; deep links and universal or app links resolve to the same routes; back-stack behaviour defined per flow | GoRouter, Jetpack Navigation, NavigationStack, React Navigation |
| Dependency injection | constructor injection; platform singletons behind interfaces so the domain layer is testable | Riverpod or get_it, Hilt, a composition root, container |

## Offline-first and sync

| Concern | Rule |
|--|--|
| Local store | the app renders from a local database (SQLite, Room, Core Data, Drift, Realm) and treats the network as a sync channel; read paths never block on the network |
| Writes | queued mutations with idempotency keys ([[api-standards]] and the catalogue's *Retries* row); the queue survives restarts |
| Conflicts | strategy per entity recorded in the ADR: last-writer-wins with server timestamps, server-authoritative, or merge; never silent data loss |
| Sync triggers | app foreground, connectivity change, push, and a bounded periodic job; backoff with jitter |
| Freshness | each screen states what it shows when offline (stale with timestamp, empty with reason); never a spinner that never ends |
| Online-only by decision | payments or live data may be online-only; the ADR says so and the app still degrades gracefully: cached last view plus a clear offline state |

## Security on the device

| Concern | Rule |
|--|--|
| Secure storage | tokens, keys and anything secret go in Keychain (iOS) or Android Keystore-backed EncryptedSharedPreferences or DataStore; never `UserDefaults`, plain `SharedPreferences`, files, or logs |
| Networking | TLS only; ATS and `networkSecurityConfig` left strict; certificate pinning only with a rotation plan and a remote kill switch, otherwise rely on platform trust |
| Auth | OAuth 2.1 with PKCE through the system browser (ASWebAuthenticationSession, Custom Tabs); short-lived access tokens, refresh token in secure storage; biometrics unlock the local secret, not the server session |
| Permissions | request at the moment of use with a pre-prompt that states the reason; every usage string, the iOS privacy manifest (`PrivacyInfo.xcprivacy`) and the Play Data safety form match actual behaviour |
| Data on device | encrypt the local database when it holds personal data; clear caches on sign-out; block screenshots on sensitive screens where a regulator expects it |
| Supply chain | lockfiles committed (`Podfile.lock`, `Package.resolved`, `pubspec.lock`, Gradle lockfiles); SBOM per release per [[standards-catalog]] |
| Regions | personal data on the device or in sync follows [[privacy-and-cybersecurity-regions]]: consent before analytics, retention on device, DSAR covers cached data |

## Background work and push

| Concern | Rule |
|--|--|
| Background tasks | platform schedulers only (WorkManager, BGTaskScheduler); assume the OS may defer, batch or kill the work; every job is idempotent and resumable |
| Push | token registration tied to the signed-in user and revoked on sign-out; payloads carry ids, not personal data; notification permission requested in context |
| Battery and data | no polling loops; background network budgeted and listed in `technical-budgets.md` |

## Budgets, accessibility, observability

| Concern | Rule | Framework default |
|--|--|--|
| App size | download-size budget in `architecture/technical-budgets.md`, checked per release | <= 50 MB download for a content app; App Bundles and App Thinning on; assets on demand beyond that |
| Startup | cold start to first interactive frame measured on a low-end reference device | <= 2 s cold, <= 500 ms warm |
| Rendering | dropped-frame rate on the reference device for the main lists | < 1% janky frames |
| Accessibility | WCAG 2.2 AA mapped to the platform: labels on every control, dynamic type and font scaling, 44x44 pt or 48x48 dp targets, screen-reader order, reduced motion honoured | Accessibility Scanner, Xcode Accessibility Inspector, or Flutter semantics tests in CI |
| Crash reporting | crash and ANR reporting on from the first release, symbol files uploaded, crash-free sessions as an SLI | crash-free sessions >= 99.5% in `technical-budgets.md` |
| Analytics | event schema versioned and documented; collection starts only after consent where [[privacy-and-cybersecurity-regions]] requires it; no personal data in event properties | opt-in by default in EU and GCC scope |
| Logging | structured, levelled, stripped of personal data and tokens; verbose logs off in release builds | |

## Release pipeline

| Concern | Rule |
|--|--|
| Signing | certificates, provisioning profiles, keystores and store API keys live in the CI secret store or a signing service (fastlane match, Play App Signing), never in the repo; `.gitignore` covers `.jks`, `.p12`, `.mobileprovision`, `key.properties` |
| Build | reproducible CI build from a clean checkout with pinned toolchains (Xcode, Android SDK, Flutter or Node) in the `## Toolchain` table |
| Versioning | SemVer marketing version plus a monotonically increasing build number, both set by the pipeline |
| Tracks | internal -> beta (TestFlight, Play internal or closed testing) -> staged rollout (1%, 10%, 50%, 100%) with a halt criterion on crash-free sessions |
| Store review | App Store Review Guidelines and Play policy items as a checklist in the plan: in-app account deletion when accounts exist, in-app purchase for digital goods, privacy labels and Data safety form, Sign in with Apple when third-party sign-in is offered, declared background modes |
| Rollback | feature flags or remote config for risky features; a server-side kill switch for a bad client version; minimum supported client version enforced by the API |

## Testing pyramid for mobile

| Level | Scope | Where it runs |
|--|--|--|
| Unit | domain and data layers, view models and reducers, mappers; most tests live here | host machine, every push ([[testing-unit]]) |
| Widget / UI component | one screen or component with faked dependencies; accessibility semantics asserted | host machine or simulator, every push |
| Golden / snapshot | reference renders of key screens per theme, locale (including RTL) and font scale; diffs reviewed, never auto-approved | CI with a pinned renderer |
| Device / integration | critical journeys (sign-in, core flow, offline-to-online sync, payment) on real or emulated devices, both platforms | per wave on a device farm or emulator matrix ([[testing-integration]]) |
| Manual release pass | permissions, push, deep links, store checklist on the oldest supported OS | before each store submission |
| Performance | the startup and frame budgets above, as `performance` rows in `plan.md`; every atomic test case names its level from this table | per wave on the reference device |

## Verifier conformance check

When the plan's `## Standards coverage` names this protocol, the verifier runs these rows and
reports PASS/FAIL for each; any FAIL is **CHANGES_NEEDED** citing the file and the rule.

| # | Check | Evidence |
|--|--|--|
| 1 | Platform ADR present: native vs hybrid decided with stack, version range, rejected alternatives | `architecture/adrs/ADR-*-mobile-platform.md` or a `## Decisions` row under fasttrack |
| 2 | Layering holds: no platform or UI imports in the domain layer; one state mechanism | import scan of the domain folder; the ADR names the mechanism |
| 3 | Secrets never in plain storage or the repo | grep for token writes to `UserDefaults` or `SharedPreferences`, keystore or certificate files, hard-coded keys |
| 4 | Permissions and privacy manifests match behaviour | `Info.plist` usage strings, `PrivacyInfo.xcprivacy`, `AndroidManifest.xml` permissions compared with the code that uses them |
| 5 | Offline behaviour implemented as the ADR states, or an online-only ADR exists with a degraded state | integration Test IDs for offline-to-online sync |
| 6 | Budgets measured: size, cold start, crash-free target recorded with the measurement command | `technical-budgets.md` rows plus a run in `## Evidence` |
| 7 | Accessibility checks present in CI and semantics asserted in widget tests | CI config and Test IDs |
| 8 | Release pipeline signs from the secret store, pins toolchains, and carries a store-review checklist | pipeline file, `## Toolchain`, plan checklist |
| 9 | Test pyramid present: unit, widget or UI, golden or snapshot, and at least one device or integration journey per platform | Test IDs mapped to levels |
| 10 | Crash reporting wired and analytics gated on consent where a region requires it | initialisation code and a consent Test ID |

The architect adds `QG-MOBILE-CONFORMANCE` to `architecture/quality-gates.md` when this protocol
applies, so the planner and the verifier both see it.

## Related

- Standards catalogue: [[standards-catalog]]
- API standards (the backend the app talks to): [[api-standards]]
- Regional privacy and cybersecurity: [[privacy-and-cybersecurity-regions]]
- Mobile dialects: [[mobile-flutter]], [[mobile-kotlin]], [[mobile-swift]]
- Architecture governance: [[architecture-governance]]
- Testing dialects: [[testing-unit]], [[testing-integration]]
