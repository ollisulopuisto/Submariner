# Changelog

## Unreleased

- Repair test compilation on the supported macOS deployment target: use String-keyed Core Data store options and Foundation's backwards-compatible Data range lookup. Keep the existing migration assertions active.
- Verification: the failure locations match the native CI compiler diagnostics. Native XCTest and SwiftLint verification remain pending; this change has not been compiled on macOS locally.

- Repair migration test fixtures after native run41400381781: select the actual historical version transition, isolate model instances from application lifecycle hooks, detach stores before reopening or deleting them, and assert the existing transient attribute contract. Native tests and lint are pending; no runtime schema changes.
