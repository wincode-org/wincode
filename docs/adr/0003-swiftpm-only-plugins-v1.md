# 0003. Support only Swift Package Manager plugins in v1

- Status: Proposed
- Date: 2026-10-12

## Context

xtool builds SwiftPM packages, not Xcode projects, and has no CocoaPods support. Flutter supports Swift Package Manager for iOS plugins, and it is the default since Flutter 3.44. Many plugins still ship only a podspec. See docs/PLAN.md, "Build on xtool" and "Build pipeline".

## Decision

v1 builds Flutter apps whose iOS plugins all support Swift Package Manager. `wincode` reads the project, and if any plugin is CocoaPods-only it stops with a clear message naming the plugin. CocoaPods support is out of scope for v1.

## Consequences

- The translator only needs to produce one SwiftPM package from `ios/Runner` plus Flutter's generated plugin package.
- Some popular plugins will not work until they add SwiftPM support, which limits adoption early on.
- Pod-to-SwiftPM conversion can be added later without changing the pipeline.

## Alternatives considered

- Run CocoaPods in WSL2: needs Ruby, an Xcode project and build tooling we do not have.
- Convert podspecs automatically: possible, but a large effort and error-prone for v1.

## Notes

- 2026-10-18: a read-only audit of a production reference app (a white-label Flutter app with several brands) supports accepting this ADR. Nine of its ten native plugins ship a `Package.swift`, the tenth (`path_provider_foundation`) has no native target, and there is no Podfile. The gap it found is native build hooks, not CocoaPods (ADR-0010). The status stays Proposed until the maintainer decides (`docs/PLAN.md`, "Decisions for the maintainer").
