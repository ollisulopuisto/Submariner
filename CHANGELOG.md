# Changelog

## Unreleased

- Repair test compilation on the supported macOS deployment target: use String-keyed Core Data store options and Foundation's backwards-compatible Data range lookup. Keep the existing migration assertions active.
- Verification: the failure locations match the native CI compiler diagnostics. Native XCTest and SwiftLint verification remain pending; this change has not been compiled on macOS locally.
