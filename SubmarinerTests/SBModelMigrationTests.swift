//
//  SBModelMigrationTests.swift
//  SubmarinerTests
//
//  Verifies the Submariner v10 -> v11 Core Data migration. The v10 model
//  still had a cleartext "password" attribute on the Server entity, left
//  over from before passwords moved to the Keychain; values written by old
//  app versions were never read again but stayed in the database file.
//  v11 removes the attribute so lightweight migration drops that orphaned
//  credential data from the store.
//

import XCTest
import CoreData
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
        return NSManagedObjectModel(contentsOf: momdURL.appendingPathComponent("\(name).mom"))
    }

    func testV10StoreMigratesToV11DroppingPasswordAttribute() throws {
        guard let v10 = modelVersion("Submariner v10"),
              let v11 = modelVersion("Submariner v11") else {
            XCTFail("Could not load versioned managed object models from the test bundle")
            return
        }
        // Precondition: v10 still has the attribute, v11 does not.
        XCTAssertNotNil(v10.entitiesByName["Server"]?.attributesByName["password"],
                        "v10 model unexpectedly lacks the password attribute - is this test stale?")
        XCTAssertNil(v11.entitiesByName["Server"]?.attributesByName["password"],
                     "v11 model must remove the password attribute")

        let storeURL = tempDir.appendingPathComponent("migration-test.sqlite")

        // 1. Create a v10 store holding a legacy cleartext password. Use the
        //    primitive accessor on purpose: SBServer's custom `password`
        //    setter writes only to the Keychain cache, but legacy app
        //    versions wrote through Core Data, which is exactly what the
        //    primitive write simulates here.
        let psc10 = NSPersistentStoreCoordinator(managedObjectModel: v10)
        try psc10.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: storeURL)
        let moc10 = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        moc10.persistentStoreCoordinator = psc10
        let server = NSEntityDescription.insertNewObject(forEntityName: "Server", into: moc10)
        server.setPrimitiveValue("legacy-secret", forKey: "password")
        try moc10.save()

        // 2. Reopen with the v11 model using the same automatic lightweight
        //    migration options the app itself uses (see SBAppDelegate).
        let psc11 = NSPersistentStoreCoordinator(managedObjectModel: v11)
        let options: [NSPersistentStoreDescription.OptionKey: Any] = [
            NSInferMappingModelAutomaticallyOption: true,
            NSMigratePersistentStoresAutomaticallyOption: true
        ]
        try psc11.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: storeURL, options: options)
        let moc11 = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        moc11.persistentStoreCoordinator = psc11

        // 3. Migration succeeds, the server row survives, and the password
        //    attribute no longer exists on the entity.
        let servers = try moc11.fetch(NSFetchRequest<NSManagedObject>(entityName: "Server"))
        XCTAssertEqual(servers.count, 1, "server row must survive migration")
        XCTAssertNil(servers.first?.entity.attributesByName["password"])

        // 4. The migrated store file must not retain the cleartext credential.
        //    Lightweight migration writes a new store, so the old value should
        //    be gone; if this proves flaky on first native run because SQLite
        //    retains free pages, check with `PRAGMA secure_delete` and report
        //    instead of deleting the assertion.
        let raw = try Data(contentsOf: storeURL)
        XCTAssertFalse(raw.contains(Data("legacy-secret".utf8)),
                       "legacy cleartext password still present in the migrated store file")
    }
}
