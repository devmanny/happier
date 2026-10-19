import Testing
@testable import HappierKit

@Suite struct SocketIOPacketTests {
    @Test func decodesEngineOpenHandshake() throws {
        let packet = try SocketIOPacket.decode(#"0{"sid":"abc","pingInterval":25000,"pingTimeout":20000,"maxPayload":1000000}"#)
        guard case .open(let info) = packet else { Issue.record("expected open, got \(packet)"); return }
        #expect(info["pingInterval"]?.intValue == 25000)
    }

    @Test func decodesPingAndClose() throws {
        #expect(try SocketIOPacket.decode("2") == .ping)
        #expect(try SocketIOPacket.decode("1") == .close)
    }

    @Test func decodesNamespaceConnectAndConnectError() throws {
        #expect(try SocketIOPacket.decode(#"40{"sid":"xyz"}"#) == .connect(["sid": "xyz"]))
        #expect(try SocketIOPacket.decode(#"44{"message":"Invalid token"}"#) == .connectError(["message": "Invalid token"]))
    }

    @Test func decodesEventWithoutAck() throws {
        let packet = try SocketIOPacket.decode(#"42["update",{"id":"u1","seq":7}]"#)
        #expect(packet == .event(name: "update", args: [["id": "u1", "seq": 7]], ackId: nil))
    }

    @Test func decodesEventWithAckIdAndAckResponse() throws {
        #expect(try SocketIOPacket.decode(#"4213["rpc-request",{"method":"x"}]"#)
            == .event(name: "rpc-request", args: [["method": "x"]], ackId: 13))
        #expect(try SocketIOPacket.decode(#"435[{"ok":true}]"#) == .ack(id: 5, args: [["ok": true]]))
    }

    @Test func encodesClientPackets() throws {
        #expect(try SocketIOPacket.pong.encode() == "3")
        #expect(try SocketIOPacket.connect(["token": "t"]).encode() == #"40{"token":"t"}"#)
        #expect(try SocketIOPacket.event(name: "ping", args: [], ackId: 2).encode() == #"422["ping"]"#)
        #expect(try SocketIOPacket.event(name: "message", args: [["sid": "s"]], ackId: nil).encode()
            == #"42["message",{"sid":"s"}]"#)
    }

    @Test func rejectsMalformedPacket() {
        #expect(throws: SocketIOPacket.DecodingError.self) { try SocketIOPacket.decode("") }
        #expect(throws: SocketIOPacket.DecodingError.self) { try SocketIOPacket.decode("42not-json") }
    }
}

@Suite struct JSONValueParseTests {
    @Test func preservesBooleansNumbersAndNesting() throws {
        let value = try JSONValue.parse(#"{"a":true,"b":0,"c":1,"d":1.5,"e":null,"f":["x",false],"g":{"h":"ñ🚀"}}"#)
        #expect(value == ["a": true, "b": 0, "c": 1, "d": 1.5, "e": nil, "f": ["x", false], "g": ["h": "ñ🚀"]])
    }

    @Test func parsesTopLevelScalars() throws {
        #expect(try JSONValue.parse("\"hello\"") == "hello")
        #expect(try JSONValue.parse("42") == 42)
        #expect(try JSONValue.parse("false") == false)
        #expect(throws: (any Error).self) { try JSONValue.parse("{oops") }
    }
}
