---
title: Mobile Swift Dialect
tags: [kcc/kernel, dialects, mobile, swift, ios, macos]
created: 2026-10-16
updated: 2026-10-16
version: 0.6.0
status: active
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"
---

# Mobile Swift Dialect

Use for native iOS, iPadOS, macOS, watchOS, and visionOS applications written in Swift. Architecture follows [[mobile-app-architecture]].

## Coding
- SwiftUI first; UIKit or AppKit only through `UIViewRepresentable` / `NSViewRepresentable` for controls SwiftUI lacks, or in existing screens being maintained.
- Swift concurrency (`async`/`await`, actors, `@MainActor`, structured task groups); no new Combine or GCD code without a reason in the plan. Strict concurrency checking enabled.
- State with `@Observable` (or `ObservableObject` on older targets), value types for models, one observable model per screen; unidirectional flow.
- Persistence with SwiftData on current targets, Core Data where the deployment target or feature set requires it; migrations versioned and tested.
- Networking with `URLSession` and `Codable`; third-party HTTP clients need an ADR row.
- Dependencies through Swift Package Manager (`Package.swift` or Xcode package references with `Package.resolved` committed); CocoaPods or Carthage only for a dependency that has no SPM distribution, recorded in an ADR.
- Signing certificates, provisioning profiles, API keys, and `.p8`/`.p12` files never enter the repo; signing is managed by Xcode Cloud, fastlane match, or CI secrets.
- App Store basics: privacy manifest (`PrivacyInfo.xcprivacy`) with required-reason APIs and tracking domains declared, App Tracking Transparency where applicable, purpose strings for every permission, no private API use.

## Review
- Check main-actor isolation, task cancellation, retain cycles in closures, view identity and `@State` ownership, accessibility (labels, Dynamic Type, VoiceOver order), dark mode, localization, and background modes.
- Check `Package.resolved` diffs: new packages justified, versions pinned to exact or `upToNextMinor`, no branch dependencies.

## Bug Fix
- Reproduce with an XCTest or snapshot test, patch the narrowest view, model, or service, run `swiftlint`, `swiftformat --lint`, and `xcodebuild test` for the affected scheme, then a simulator smoke check.

## Testing
- XCTest for unit and integration tests (Swift Testing acceptable on current toolchains), snapshot tests (for example `swift-snapshot-testing`) for views, XCUITest for critical flows on simulator.
- Mock boundaries with protocols and injected dependencies; never hit real network in unit tests.
- Coverage from `xcodebuild -enableCodeCoverage YES`; threshold from the quality gate.

## Docs
- README must include Xcode and Swift versions, deployment targets, schemes and configurations, setup (SPM resolve, signing approach), run/test commands, and App Store release steps.

## Toolchain
- Xcode stable (version pinned in `.xcode-version` or documented), Swift from the bundled toolchain, Simulator runtimes for the supported targets, optional fastlane for lanes.
- Lint and format: SwiftLint and SwiftFormat with committed configs, run in CI and as a build phase in debug.
- CI runs `swiftlint`, `swiftformat --lint .`, `xcodebuild build test -scheme <App> -destination 'platform=iOS Simulator,...'`, and an archive on release branches.

## Project Structure
- Feature-first groups: `App/` (entry, root navigation, environment), `Features/<Feature>/{Views,Models,Services}/`, `Core/` (networking, persistence, design system), `Resources/`, `Tests/`, `UITests/`; shared code in local Swift packages under `Packages/`.
- For greenfield KCC projects the Xcode project or workspace lives under `src/` unless an existing layout already exists.

## API & Architecture defaults
- When the app owns a backend, that backend follows [[api-standards]] and its own dialect; the Swift client consumes the OpenAPI document (generated clients acceptable when recorded in an ADR).
- Architecture style follows [[mobile-app-architecture]] (layered, feature-first, offline-first where required); opt down only for trivial apps with an ADR per [[architecture-styles]].

## Complexity
- low: junior-safe view, string, or asset change.
- medium: mid-level screen with observable model, service, and tests.
- high: senior persistence migrations, background tasks, offline sync, or performance tuning.
- extra-high: principal-expert multi-platform architecture, custom rendering (Metal, Core Animation), or system extensions.

## Escalate
- Escalate to the architect for persistence choice, package additions outside SPM, module boundaries, or UIKit fallbacks; escalate to a human for App Store review, signing, entitlements, or privacy-disclosure questions.
