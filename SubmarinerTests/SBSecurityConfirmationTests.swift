//
//  SBSecurityConfirmationTests.swift
//  SubmarinerTests
//
//  Regression tests confirming that the two remaining CodeQL security findings
//  are resolved / intentionally accepted and stay that way:
//
//  - swift/cleartext-storage-database:
//    SBServer.password is Keychain-backed (macOS Internet Password items) with a
//    small in-memory cache; it never touches the local Core Data / SQLite store.
//    The current managed object model must therefore not expose a persistent
//    "password" attribute on the Server entity.
//  - swift/weak-password-hashing:
//    MD5 is retained for Subsonic token auth only because the protocol mandates
//    t = md5(password + salt) with a per-request salt; no Subsonic server
//    accepts another digest. This is a per-request token digest, not password
//    hashing for storage. Locked by SBLastFMTests (MD5 official vectors +
//    testSubsonicToken_sha256WouldNotMatchProtocol).
//
//  See SECURITY.md ("Accepted risks / CodeQL false positives").
//

import CoreData
import XCTest
@testable import Submariner

final class SBSecurityConfirmationTests: XCTestCase {
    // MARK: - Cleartext storage in the local database

    /// The app loads its model the same way (SBAppDelegate:
    /// NSManagedObjectModel(contentsOf:) on the "Submariner.momd" bundle
    /// resource), so this asserts against the exact model the shipped app uses.
    func testCurrentModelDropsPasswordAttribute() throws {
        let bundle = Bundle(for: SBServer.self)
        guard let modelURL = bundle.url(forResource: "Submariner", withExtension: "momd") else {
            XCTFail("Could not locate the compiled managed object model in the test bundle")
            return
        }
        guard let model = NSManagedObjectModel(contentsOf: modelURL) else {
            XCTFail("Could not load the current managed object model")
            return
        }

        let serverEntity = try XCTUnwrap(model.entitiesByName["Server"],
                                         "Server entity must exist in the current model")

        // Passwords live in the Keychain, never in Core Data in cleartext.
        XCTAssertNil(serverEntity.attributesByName["password"],
                     "Server must not persist a cleartext password attribute; SBServer.password is Keychain-backed")
    }
}
