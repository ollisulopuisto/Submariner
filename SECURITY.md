# Security Policy

## Supported versions

| Version | Supported |
| ------- | --------- |
| master  | :white_check_mark: |

## Password handling

Server passwords are **never** stored in Core Data (the local SQLite database) in cleartext:

- The `password` attribute was removed from the Core Data model in model version v10.
- `SBServer.password` is a keychain-backed accessor: it reads from / writes to the macOS Keychain (Internet Password items), with a small in-memory cache for the lifetime of the server object.
- `SBEditServerController` restores the previous password on cancel by writing it back to the Keychain via `SBServer.password` — never to Core Data in cleartext (see `Submariner/SBEditServerController.swift:95`).

## Token authentication (MD5)

The Subsonic API defines token authentication as `t = md5(password + salt)`, where `salt` is a per-request random nonce. This is a **protocol constraint**, not a choice:

- Subsonic servers do not accept any other digest for token authentication, so MD5 cannot be replaced without breaking authentication with every Subsonic server.
- This is a per-request token digest, **not** password storage. The password itself is never transmitted or stored via MD5 (see `Submariner/SBServer.swift:400`).

## Accepted risks / CodeQL false positives

The following CodeQL findings are intentionally accepted and documented. They cannot be remediated in code without breaking the product:

| Finding | Location | Reason accepted |
| ------- | -------- | --------------- |
| `swift/cleartext-storage-database` — Cleartext storage of sensitive information in a local database | `Submariner/SBEditServerController.swift:95` | The password is Keychain-backed via `SBServer.password`; nothing is written to the local database in cleartext. |
| `swift/weak-password-hashing` — Use of an inappropriate cryptographic hashing algorithm on passwords | `Submariner/SBServer.swift:400` | MD5 is mandated by the Subsonic token-auth protocol (`t = md5(password + salt)` with a per-request random salt). It is a token digest, not password hashing for storage. |

## Reporting a vulnerability

If you believe you have found a security issue, please open a private issue or contact the maintainers. Do not disclose the issue publicly until it has been addressed.
