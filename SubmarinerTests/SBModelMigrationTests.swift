//
//  SBModelMigrationTests.swift
//  SubmarinerTests
//
//  Verifies migrations using the actual historical model versions and isolated stores.
//

import CoreData
import XCTest
@testable import Submariner

final class SBModelMigrationTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// Load one versioned model from the compiled model bundle (.momd holds
    /// one .mom per version).
    private func modelVersion(_ name: String) -> NSManagedObjectModel? {
        let bundle = Bundle(for: SBServer.self)
        guard let momdURL = bundle.url(forResource: "Submariner", withExtension: "momd") else { return nil }
        guard let model = NSManagedObjectModel(contentsOf: momdURL.appendingPathComponent("\(name).mom")) else { return nil }
        // Historical stores test schema migration, not current subclass lifecycle hooks.
        // Multiple loaded versions make subclass entity() lookup ambiguous.
        for entity in model.entities {
            entity.managedObjectClassName = "NSManagedObject"
        }
        return model
    }

    func testV9StoreMigratesToV10DroppingPasswordAttribute() throws {
        guard let v9 = modelVersion("Submariner v9"),
              let v10 = modelVersion("Submariner v10") else {
            XCTFail("Could not load versioned managed object models from the test bundle")
            return
        }
        // Precondition: v9 still has the attribute, v10 does not.
        XCTAssertNotNil(v9.entitiesByName["Server"]?.attributesByName["password"],
                        "v9 model unexpectedly lacks the password attribute - is this test stale?")
        XCTAssertNil(v10.entitiesByName["Server"]?.attributesByName["password"],
                     "v10 model must remove the password attribute")

        let storeURL = tempDir.appendingPathComponent("migration-test.sqlite")

        // Create the historical schema with generic managed objects, bypassing
        // current application subclasses and their lifecycle side effects.
        let psc9 = NSPersistentStoreCoordinator(managedObjectModel: v9)
        defer { for store in psc9.persistentStores { try? psc9.remove(store) } }
        try psc9.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: storeURL)
        let moc9 = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        moc9.persistentStoreCoordinator = psc9
        let server = NSEntityDescription.insertNewObject(forEntityName: "Server", into: moc9)
        server.setPrimitiveValue("legacy-secret", forKey: "password")
        try moc9.save()
        moc9.reset()
        for store in psc9.persistentStores { try psc9.remove(store) }

        // 2. Reopen with the v10 model using the same automatic lightweight
        //    migration options the app itself uses (see SBAppDelegate).
        let psc10 = NSPersistentStoreCoordinator(managedObjectModel: v10)
        defer { for store in psc10.persistentStores { try? psc10.remove(store) } }
        let options: [String: Any] = [
            NSInferMappingModelAutomaticallyOption: true,
            NSMigratePersistentStoresAutomaticallyOption: true
        ]
        try psc10.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: storeURL, options: options)
        let moc10 = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        moc10.persistentStoreCoordinator = psc10

        // 3. Migration succeeds, the server row survives, and the password
        //    attribute no longer exists on the entity.
        let servers = try moc10.fetch(NSFetchRequest<NSManagedObject>(entityName: "Server"))
        XCTAssertEqual(servers.count, 1, "server row must survive migration")
        XCTAssertNil(servers.first?.entity.attributesByName["password"])

        moc10.reset()
        for store in psc10.persistentStores { try psc10.remove(store) }

        // 4. The migrated store file must not retain the cleartext credential.
        //    Lightweight migration writes a new store, so the old value should
        //    be gone; if this proves flaky on first native run because SQLite
        //    retains free pages, check with `PRAGMA secure_delete` and report
        //    instead of deleting the assertion.
        let raw = try Data(contentsOf: storeURL)
        XCTAssertNil(raw.range(of: Data("legacy-secret".utf8)),
                       "legacy cleartext password still present in the migrated store file")
    }

    func testV11StoreMigratesToV12DroppingCleartextLicenseDate() throws {
        guard let v11 = modelVersion("Submariner v11"),
              let v12 = modelVersion("Submariner v12") else {
            XCTFail("Could not load versioned managed object models from the test bundle")
            return
        }
        // Precondition: v11 still has licenseDate as a persistent attribute,
        // v12 makes it transient.
        XCTAssertNotNil(v11.entitiesByName["Server"]?.attributesByName["licenseDate"],
                        "v11 model unexpectedly lacks the licenseDate attribute - is this test stale?")
        XCTAssertNotNil(v12.entitiesByName["Server"]?.attributesByName["licenseDate"],
                        "v12 model unexpectedly lacks the licenseDate attribute - is this test stale?")
        let licenseDateAttrV11 = v11.entitiesByName["Server"]?.attributesByName["licenseDate"]
        XCTAssertFalse(licenseDateAttrV11?.isTransient ?? true,
                       "v11 licenseDate must be persistent (not transient)")
        let licenseDateAttrV12 = v12.entitiesByName["Server"]?.attributesByName["licenseDate"]
        XCTAssertTrue(licenseDateAttrV12?.isTransient ?? false,
                      "v12 licenseDate must be transient")

        let storeURL = tempDir.appendingPathComponent("migration-test-license-date.sqlite")

        // 1. Create a v11 store holding a cleartext licenseDate.
        let psc11 = NSPersistentStoreCoordinator(managedObjectModel: v11)
        defer { for store in psc11.persistentStores { try? psc11.remove(store) } }
        try psc11.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: storeURL)
        let moc11 = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        moc11.persistentStoreCoordinator = psc11
        let server = NSEntityDescription.insertNewObject(forEntityName: "Server", into: moc11)
        server.setPrimitiveValue(Date.distantPast, forKey: "licenseDate")
        try moc11.save()
        moc11.reset()
        for store in psc11.persistentStores { try psc11.remove(store) }

        // 2. Reopen with the v12 model using automatic lightweight migration.
        let psc12 = NSPersistentStoreCoordinator(managedObjectModel: v12)
        defer { for store in psc12.persistentStores { try? psc12.remove(store) } }
        let options: [String: Any] = [
            NSInferMappingModelAutomaticallyOption: true,
            NSMigratePersistentStoresAutomaticallyOption: true
        ]
        try psc12.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: storeURL, options: options)
        let moc12 = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        moc12.persistentStoreCoordinator = psc12

        // 3. Migration succeeds, the server row survives, but licenseDate
        //    is no longer a stored attribute.
        let servers = try moc12.fetch(NSFetchRequest<NSManagedObject>(entityName: "Server"))
        XCTAssertEqual(servers.count, 1, "server row must survive migration")
        let migratedAttribute = try XCTUnwrap(servers.first?.entity.attributesByName["licenseDate"])
        XCTAssertTrue(migratedAttribute.isTransient, "licenseDate must not persist after migration")
        XCTAssertNil(servers.first?.value(forKey: "licenseDate"), "legacy value must not survive migration")
        moc12.reset()
        for store in psc12.persistentStores { try psc12.remove(store) }
    }
}
