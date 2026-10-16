---
title: Mobile Flutter Dialect
tags: [kcc/kernel, dialects, mobile, flutter, dart]
created: 2026-10-16
updated: 2026-10-16
version: 0.6.0
status: active
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"
---

# Mobile Flutter Dialect

Use for Flutter/Dart applications targeting iOS, Android, web, and desktop from one codebase. Architecture follows [[mobile-app-architecture]].

## Coding
- Null-safe Dart only. Prefer `const` constructors, small widgets, and immutable state objects.
- Separate presentation (widgets), state (providers/blocs), domain (entities, use cases), and data (repositories, DTOs) per [[mobile-app-architecture]].
- Feature-first layout under `lib/`: `lib/features/<feature>/{presentation,application,domain,data}/`, shared code in `lib/core/`, app shell in `lib/app/`.
- No platform-specific code outside `lib/core/platform/`; platform channels only when no maintained plugin exists.
- Never commit signing material, keystores, API keys, or service account files; load secrets with `--dart-define` or a platform secret store.

## Packages
- Prefer first-party (`dart.dev`, `flutter.dev`, `fluttercommunity.dev`) and Flutter Favorite packages; check pub.dev score, maintenance, and license before adding anything.
- Pin dependencies in `pubspec.yaml` with caret ranges (`^x.y.z`); commit `pubspec.lock` for apps (not for published packages).
- Run `flutter pub outdated` and a dependency-audit check (for example `dart pub audit`-style tooling or an SCA scanner in CI) at least once per spec; upgrade with `flutter pub upgrade --major-versions` only in a dedicated enabler.
- Avoid packages without null safety, without a release in the last 12 months, or that pull in a native plugin with no maintainer.
- State management is recorded in an ADR: Riverpod or Bloc are the defaults; Provider is acceptable for small apps.
- Navigation: `go_router` (declarative routes, deep links, guards).
- Networking: `dio` or `http`; models with `json_serializable` and `freezed` (immutable unions, `copyWith`).
- Local storage by use: `drift` (relational, typed queries), `sqflite` (raw SQLite), `hive` or `shared_preferences` (key-value); secrets in `flutter_secure_storage`.
- Dependency injection: Riverpod providers or `get_it` (with `injectable` when the graph is large).
- Testing: `flutter_test`, `mocktail`, `integration_test`, golden tests (`matchesGoldenFile`, optional `golden_toolkit`).
- Lint: `flutter_lints` baseline or `very_good_analysis` for stricter projects; `analysis_options.yaml` is committed and CI runs `dart analyze --fatal-infos`.
- Any native plugin (method channel, FFI, or a package that bundles native code) needs an ADR row naming the platform scope, the maintainer, and the fallback.

## Review
- Check widget rebuild scope, state ownership, disposal of controllers and streams, navigation guards, error and loading states, accessibility semantics, text scaling, and platform parity.
- Check `pubspec.yaml` diffs: new packages justified, versions caret-pinned, lock file updated, no abandoned packages.

## Bug Fix
- Reproduce in a widget or integration test, patch the narrowest widget, provider, or repository, run `flutter analyze` and `flutter test`, then a device or emulator smoke check on at least one target platform.

## Testing
- Unit tests for domain and application code; widget tests for presentation; golden tests for visual components; `integration_test` for critical flows on emulator or device.
- Mock boundaries with `mocktail`; never hit real network in unit or widget tests.
- Coverage via `flutter test --coverage`; the threshold comes from the quality gate.

## Docs
- README must include Flutter channel and version (`flutter --version`), supported platforms, setup per platform (Xcode, Android SDK), run/test/build commands, flavors and `--dart-define` variables, and store release steps.

## Toolchain
- Flutter SDK on the `stable` channel (pinned in `.fvmrc` or documented), Dart from the bundled SDK, Xcode for iOS/macOS, Android SDK and JDK for Android, CocoaPods only where the iOS build still requires it.
- CI runs `flutter pub get`, `dart format --set-exit-if-changed .`, `flutter analyze`, `flutter test`, and a build per target platform.

## Project Structure
- `lib/app/` (entry, router, theme), `lib/core/` (shared utilities, platform, networking base), `lib/features/<feature>/...`, `test/` mirroring `lib/`, `integration_test/`, `assets/`, `analysis_options.yaml`, `pubspec.yaml`, `pubspec.lock`.
- For greenfield KCC projects the Flutter project lives under `src/` unless an existing layout already exists.

## API & Architecture defaults
- When the app owns a backend, that backend follows [[api-standards]] and its own dialect; the Flutter client consumes the OpenAPI document (generated clients are acceptable when recorded in an ADR).
- Architecture style follows [[mobile-app-architecture]] (layered, feature-first, offline-first where required); opt down only for trivial apps with an ADR per [[architecture-styles]].

## Complexity
- low: junior-safe widget, style, or copy change.
- medium: mid-level feature with state, navigation, and a repository.
- high: senior offline sync, background work, platform channels, or performance tuning.
- extra-high: principal-expert multi-platform architecture, custom rendering, or plugin development.

## Escalate
- Escalate to the architect for state-management changes, new native plugins, data-model migrations, or platform-scope changes; escalate to a human for store policy, signing, or privacy-disclosure questions.
