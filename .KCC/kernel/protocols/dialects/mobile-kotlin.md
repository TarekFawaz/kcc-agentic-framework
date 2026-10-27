---
title: Mobile Kotlin Dialect
tags: [kcc/kernel, dialects, mobile, kotlin, android]
created: 2026-10-16
updated: 2026-10-16
version: 0.6.0
status: active
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"
---

# Mobile Kotlin Dialect

Use for native Android applications and libraries written in Kotlin. Architecture follows [[mobile-app-architecture]].

## Coding
- Kotlin only for new code; Java interop is allowed for legacy modules and recorded in the plan.
- UI with Jetpack Compose (Material 3); XML views only in existing screens being maintained. Unidirectional data flow: state down, events up, one `ViewModel` per screen.
- Concurrency with coroutines and `Flow`; structured concurrency only (`viewModelScope`, `lifecycleScope`, injected dispatchers), no `GlobalScope`.
- Dependency injection with Hilt; constructor injection, no service locators.
- Persistence with Room (migrations committed and tested); preferences with DataStore.
- Networking with Retrofit + OkHttp or Ktor client; serialization with `kotlinx.serialization` or Moshi; models immutable `data class`es.
- Gradle with Kotlin DSL and a version catalog (`gradle/libs.versions.toml`); Gradle wrapper committed; dependencies locked for release builds.
- No secrets, keystores, or `google-services.json` with production keys in the repo; signing config from CI secrets or `local.properties`.
- Permissions requested at point of use with rationale; follow current target SDK and Play policy (data safety form, background location, foreground service types).

## Review
- Check lifecycle handling, Compose recomposition and stability, coroutine cancellation and dispatcher use, state hoisting, Room migrations, ProGuard/R8 keep rules, accessibility (`contentDescription`, touch targets), and configuration changes.
- Check `libs.versions.toml` diffs: new dependencies justified, versions pinned, no snapshot builds.

## Bug Fix
- Reproduce with a unit, Turbine, or Compose UI test; patch the narrowest ViewModel, use case, or composable; run `./gradlew detekt ktlintCheck test` and the relevant instrumented tests on an emulator.

## Testing
- JUnit 5 for unit tests, Turbine for `Flow` assertions, MockK for doubles, Compose testing (`createComposeRule`) for UI, Espresso or instrumented tests for integration, Robolectric where a JVM-only run is enough.
- Coverage with Kover or JaCoCo; threshold from the quality gate.

## Docs
- README must include JDK and Android Gradle Plugin versions, min/target SDK, build variants and flavors, setup (Android Studio, SDK components), run/test commands, and release steps.

## Toolchain
- JDK (version pinned in the catalog or `toolchain {}` block), Android SDK and command-line tools, Gradle via wrapper, Android Studio stable.
- Lint: `detekt` and `ktlint` (or `ktfmt`) with committed configs; Android Lint in CI.
- CI runs `./gradlew ktlintCheck detekt lint testDebugUnitTest assembleDebug`; instrumented tests on an emulator matrix for critical flows.

## Kotlin Multiplatform
- When shared logic across Android and iOS is required, use Kotlin Multiplatform for domain and data layers (`commonMain`, `androidMain`, `iosMain`) with Compose Multiplatform only after an ADR; keep the iOS UI in SwiftUI per [[mobile-swift]] unless the ADR says otherwise.

## Project Structure
- Modules by layer and feature: `:app`, `:core:<name>`, `:feature:<name>`, `:data:<name>`, `:domain`; each module owns its tests under `src/test` and `src/androidTest`.
- For greenfield KCC projects the Android project lives under `src/` unless an existing layout already exists.

## API & Architecture defaults
- When the app owns a backend, that backend follows [[api-standards]] and its own dialect; the Android client consumes the OpenAPI document (generated clients acceptable when recorded in an ADR).
- Architecture style follows [[mobile-app-architecture]] (layered, feature modules, offline-first where required); opt down only for trivial apps with an ADR per [[architecture-styles]].

## Complexity
- low: junior-safe composable, string, or resource change.
- medium: mid-level screen with ViewModel, repository, and tests.
- high: senior background work (WorkManager), Room migrations, offline sync, or performance tuning.
- extra-high: principal-expert multi-module architecture, Multiplatform, or custom rendering.

## Escalate
- Escalate to the architect for module boundaries, Multiplatform adoption, data-model migrations, or DI graph changes; escalate to a human for Play policy, signing, or privacy-disclosure questions.
