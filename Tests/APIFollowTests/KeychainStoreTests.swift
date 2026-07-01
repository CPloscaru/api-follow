import Foundation
import Testing
@testable import APIFollow

@Suite("KeychainStore")
struct KeychainStoreTests {
    // Unique service name per test run so parallel/repeated test runs don't
    // collide with leftover items from a previous run.
    let store = KeychainStore(service: "com.apifollow.tests.\(UUID().uuidString)")

    @Test("read returns nil for a provider with no stored key")
    func readMissingItem() throws {
        let result = try store.read(for: .anthropic)
        #expect(result == nil)
    }

    @Test("save then read round-trips the secret")
    func saveThenRead() throws {
        try store.save("sk-ant-admin01-test", for: .anthropic)
        let result = try store.read(for: .anthropic)
        #expect(result == "sk-ant-admin01-test")
        try store.delete(for: .anthropic)
    }

    @Test("save is idempotent — re-saving overwrites rather than failing")
    func saveOverwrites() throws {
        try store.save("first-value", for: .openai)
        try store.save("second-value", for: .openai)
        let result = try store.read(for: .openai)
        #expect(result == "second-value")
        try store.delete(for: .openai)
    }

    @Test("delete on a missing item does not throw")
    func deleteMissingItemIsNoOp() throws {
        try store.delete(for: .anthropic)
    }

    @Test("multiple labels per provider are stored independently")
    func multipleKeysPerProvider() throws {
        try store.save("key-one", for: .anthropic, label: "work")
        try store.save("key-two", for: .anthropic, label: "personal")

        #expect(try store.read(for: .anthropic, label: "work") == "key-one")
        #expect(try store.read(for: .anthropic, label: "personal") == "key-two")

        let labels = try store.labels(for: .anthropic)
        #expect(Set(labels) == Set(["work", "personal"]))

        try store.delete(for: .anthropic, label: "work")
        try store.delete(for: .anthropic, label: "personal")
    }

    @Test("keys for different providers do not collide")
    func differentProvidersDoNotCollide() throws {
        try store.save("anthropic-key", for: .anthropic)
        try store.save("openai-key", for: .openai)

        #expect(try store.read(for: .anthropic) == "anthropic-key")
        #expect(try store.read(for: .openai) == "openai-key")

        try store.delete(for: .anthropic)
        try store.delete(for: .openai)
    }
}
