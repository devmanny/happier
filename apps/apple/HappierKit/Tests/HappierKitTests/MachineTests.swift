import Foundation
import Testing
@testable import HappierKit

/// Machines for "New Session" (`syncMachines.ts`, `machineEncryption.ts`, `machineStoredContent.ts`).
@Suite struct MachineTests {
    let keys = try! AccountKeys(masterSecret: Data(0..<32))

    @Test func decryptsE2EEMachineMetadata() throws {
        let dataKey = Data(repeating: 4, count: 32)
        let envelope = try HappierCrypto.sealDataKeyEnvelope(dataKey, recipientPublicKey: keys.content.publicKey)
        let metadata: JSONValue = ["host": "mbp.local", "displayName": "Manny's Mac", "platform": "darwin", "homeDir": "/Users/manny", "happyCliVersion": "0.2.12"]
        let machine = try Machine(row: [
            "id": "m1", "active": true, "activeAt": 1000,
            "dataEncryptionKey": .string(envelope.base64EncodedString()),
            "metadata": .string(try ContentCipher.aesGCM(key: dataKey).encryptBase64(metadata)),
        ], keys: keys)
        #expect(machine.name == "Manny's Mac" && machine.homeDir == "/Users/manny" && machine.active)
        #expect(machine.cliVersion == "0.2.12")
    }

    @Test func readsPlainMachinesAndFallsBackToHost() throws {
        let marker = Data(#"{"t":"plain","v":null}"#.utf8).base64EncodedString()
        let doc = Data(#"{"t":"plain","v":{"host":"devbox","homeDir":"/home/m"}}"#.utf8).base64EncodedString()
        let machine = try Machine(row: ["id": "m2", "active": false, "dataEncryptionKey": JSONValue.string(marker), "metadata": JSONValue.string(doc)] as JSONValue, keys: nil)
        #expect(machine.name == "devbox" && machine.homeDir == "/home/m" && !machine.active)
    }

    @Test func recentDirectoriesComeFromThatMachinesSessions() throws {
        func session(_ id: String, _ machine: String, _ path: String, _ at: Double) throws -> Session {
            try Session(row: ["id": .string(id), "seq": 1, "createdAt": 1, "updatedAt": .number(at), "active": false,
                              "encryptionMode": "plain", "metadata": .string(#"{"path":"\#(path)","machineId":"\#(machine)"}"#), "metadataVersion": 1], keys: nil)
        }
        let sessions = [try session("a", "m1", "/p/one", 10), try session("b", "m1", "/p/two", 30), try session("c", "m2", "/p/x", 50), try session("d", "m1", "/p/one", 40)]
        #expect(Machine.recentDirectories(machineId: "m1", sessions: sessions) == ["/p/one", "/p/two"])
    }
}
