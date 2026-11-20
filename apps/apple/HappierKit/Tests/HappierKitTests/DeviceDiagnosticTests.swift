import Foundation
import Testing
@testable import HappierKit

/// MetricKit reports saved for the developer under `diag/<uuid>`, sealed `device_diagnostics`
/// (`packages/protocol/src/diagnostics/deviceDiagnostics.ts`), read by `happier diagnostics pull`.
@Suite struct DeviceDiagnosticTests {
    static let machineKey = Data(0..<32)
    static let origin = DeviceDiagnostic.Origin(model: "iPhone17,1", os: "iOS 26.1", appVersion: "0.2.19", build: "412")
    static let createdAt = Date(timeIntervalSince1970: 1_762_594_200)

    /// `sealAccountScopedBlobCiphertext({kind:'device_diagnostics', material:{type:'dataKey', machineKey:0..31},
    /// payload:{v:1,kind:'metric',tooLarge:true,compressedBytes:9,rawBytes:20,build:'7',createdAt:5}})` with a nonce of 3s.
    static let tsSealed = "oQ8DAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwPBvWwZiM4nLqHgSacOxyYH5D7OtE4VG6Jyh/znFZ+FCZSE9W9xX4S27cOdNoPfL+R/j/+6PrjA0HMWgL5Id3n+XIMVJn+hwHfXF5LReoN2Up8l9XIR0/Hydfy1HS0GKCY31Wwyuv1RYmIYV1wkuv6kyKd7"

    /// A hang report's shape, repeated to a realistic size.
    static func sample(bytes: Int) -> Data {
        var frames: [JSONValue] = []
        var index = 0
        while (try? JSONValue.array(frames).encoded().count) ?? 0 < bytes {
            frames.append(["binaryName": "Happier", "binaryUUID": "6A3F1C2E-9B1D-4C55-8E0A-2F7E1D3C4B5A",
                           "offsetIntoBinaryTextSegment": .number(Double(123_456 + index * 64)), "sampleCount": 3,
                           "address": .number(Double(4_295_000_000 + index * 64))])
            index += 1
        }
        return try! JSONValue.object(["hangDiagnostics": [["callStackTree": ["callStacks": .array(frames)]]]]).encoded()
    }

    @Test func sharesTheKindWithTheTypeScriptClient() throws {
        let opened = try #require(AccountScopedBlob.open(Self.tsSealed, kind: .deviceDiagnostics, machineKey: Self.machineKey))
        #expect(opened["tooLarge"]?.boolValue == true)
        #expect(AccountScopedBlob.open(Self.tsSealed, kind: .agentTask, machineKey: Self.machineKey) == nil)
    }

    @Test func sealsTheCompressedReportWithWhereItCameFrom() throws {
        let json = Self.sample(bytes: 20_000)
        let key = DeviceDiagnostic.kvKey(id: UUID())
        #expect(key.hasPrefix("diag/"))
        let saved = try DeviceDiagnostic.sealedValue(json, kind: .diagnostic, origin: Self.origin, createdAt: Self.createdAt,
                                                     key: key, machineKey: Self.machineKey)
        #expect(!saved.tooLarge)
        let record = try #require(AccountScopedBlob.open(saved.value, kind: .deviceDiagnostics, machineKey: Self.machineKey))
        #expect(record["v"]?.intValue == 1)
        #expect(record["kind"]?.stringValue == "diagnostic")
        #expect(record["createdAt"]?.doubleValue == 1_762_594_200_000)
        #expect(record["device"] == ["model": "iPhone17,1", "os": "iOS 26.1"])
        #expect(record["appVersion"]?.stringValue == "0.2.19" && record["build"]?.stringValue == "412")
        #expect(record["encoding"]?.stringValue == "zlib")
        let payloadBase64 = try #require(record["payloadBase64"]?.stringValue)
        let compressed = try #require(Data(base64Encoded: payloadBase64))
        #expect(compressed.count < json.count / 4)
        #expect(try (compressed as NSData).decompressed(using: .zlib) as Data == json)
    }

    @Test func aReportTooLargeForOneRequestIsSavedAsAShortEntry() throws {
        let json = Self.sample(bytes: 20_000)
        let key = DeviceDiagnostic.kvKey(id: UUID())
        let fits = try DeviceDiagnostic.sealedValue(json, kind: .metric, origin: Self.origin, createdAt: Self.createdAt, key: key,
                                                    machineKey: Self.machineKey)
        let body = try HappierAPI.kvWriteBody(key: key, value: fits.value, version: -1).encoded().count
        // Exactly at the limit still fits; one byte under it doesn't.
        #expect(try !DeviceDiagnostic.sealedValue(json, kind: .metric, origin: Self.origin, createdAt: Self.createdAt, key: key,
                                                  machineKey: Self.machineKey, requestBodyLimit: body).tooLarge)
        let short = try DeviceDiagnostic.sealedValue(json, kind: .metric, origin: Self.origin, createdAt: Self.createdAt, key: key,
                                                     machineKey: Self.machineKey, requestBodyLimit: body - 1)
        #expect(short.tooLarge)
        let record = try #require(AccountScopedBlob.open(short.value, kind: .deviceDiagnostics, machineKey: Self.machineKey))
        #expect(record["tooLarge"]?.boolValue == true)
        #expect(record["rawBytes"]?.intValue == json.count)
        #expect((record["compressedBytes"]?.intValue ?? 0) > 0)
        #expect(record["build"]?.stringValue == "412" && record["kind"]?.stringValue == "metric")
        #expect(record["payloadBase64"] == nil)
    }

    @Test func theRelayRequestLimitIsItsBodyLimit() {
        // `bodyLimit` in apps/server/sources/app/api/api.ts.
        #expect(DeviceDiagnostic.requestBodyLimit == 100 * 1024 * 1024)
    }

    @MainActor @Test func aDiagnosticKeyInALiveUpdateChangesNothingShownHere() throws {
        let store = HappierStore(server: URL(string: "http://127.0.0.1:1")!)
        store.applyKVChanges([.init(key: "task/t1", value: try AccountKVSyncTests.task("t1", title: "Primera"), version: 0)],
                             machineKey: AccountKVSyncTests.machineKey)
        store.setAgentMemoryForTests(AgentMemory(), agentId: "a1")
        let tasks = store.tasks, profiles = store.agentProfiles, memories = store.agentMemories
        let value = try DeviceDiagnostic.sealedValue(Self.sample(bytes: 2_000), kind: .diagnostic, origin: Self.origin,
                                                     createdAt: Self.createdAt, key: "diag/x", machineKey: AccountKVSyncTests.machineKey).value
        let body: JSONValue = ["t": "kv-batch-update", "changes": [["key": "diag/x", "value": .string(value), "version": 0]]]
        store.applyKVChanges(AccountKVSync.changes(fromUpdate: body), machineKey: AccountKVSyncTests.machineKey)
        #expect(store.tasks == tasks)
        #expect(store.agentProfiles == profiles)
        #expect(store.agentMemories == memories)
    }
}
