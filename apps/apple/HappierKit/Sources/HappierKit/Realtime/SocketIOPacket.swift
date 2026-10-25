import Foundation

/// Engine.IO v4 + Socket.IO v5 text packets, default namespace only (the Happier server uses `/`).
/// Binary attachments are not used by the Happier protocol and are rejected.
enum SocketIOPacket: Equatable, Sendable {
    // Engine.IO
    case open(JSONValue)
    case close
    case ping
    case pong
    // Socket.IO (carried in an Engine.IO "message" packet)
    case connect(JSONValue?)
    case disconnect
    case event(name: String, args: [JSONValue], ackId: Int?)
    case ack(id: Int, args: [JSONValue])
    case connectError(JSONValue)

    struct DecodingError: Error, CustomStringConvertible {
        let raw: String
        var description: String { "Malformed Socket.IO packet: \(raw.prefix(120))" }
    }

    static func decode(_ raw: String) throws -> SocketIOPacket {
        guard let engineType = raw.first else { throw DecodingError(raw: raw) }
        let rest = raw.dropFirst()
        switch engineType {
        case "0": return .open(try json(rest, raw))
        case "1": return .close
        case "2": return .ping
        case "3": return .pong
        case "4": return try decodeSocket(rest, raw)
        default: throw DecodingError(raw: raw)
        }
    }

    private static func decodeSocket(_ body: Substring, _ raw: String) throws -> SocketIOPacket {
        guard let socketType = body.first else { throw DecodingError(raw: raw) }
        var rest = body.dropFirst()
        // Optional namespace ("/ns,") — only the default namespace is supported.
        if rest.first == "/" {
            guard let comma = rest.firstIndex(of: ",") else { throw DecodingError(raw: raw) }
            rest = rest[rest.index(after: comma)...]
        }
        let digits = rest.prefix(while: \.isNumber)
        let id = digits.isEmpty ? nil : Int(digits)
        rest = rest.dropFirst(digits.count)
        switch socketType {
        case "0": return .connect(rest.isEmpty ? nil : try json(rest, raw))
        case "1": return .disconnect
        case "2":
            guard case .array(let items) = try json(rest, raw), case .string(let name)? = items.first else {
                throw DecodingError(raw: raw)
            }
            return .event(name: name, args: Array(items.dropFirst()), ackId: id)
        case "3":
            guard let id, case .array(let items) = try json(rest, raw) else { throw DecodingError(raw: raw) }
            return .ack(id: id, args: items)
        case "4": return .connectError(try json(rest, raw))
        default: throw DecodingError(raw: raw)
        }
    }

    private static func json(_ text: Substring, _ raw: String) throws -> JSONValue {
        do { return try JSONValue.parse(String(text)) } catch { throw DecodingError(raw: raw) }
    }

    func encode() throws -> String {
        switch self {
        case .open(let info): return "0" + (try text(info))
        case .close: return "1"
        case .ping: return "2"
        case .pong: return "3"
        case .connect(let auth): return "40" + (try auth.map(text) ?? "")
        case .disconnect: return "41"
        case .event(let name, let args, let ackId):
            return "42" + (ackId.map(String.init) ?? "") + (try text(.array([.string(name)] + args)))
        case .ack(let id, let args): return "43\(id)" + (try text(.array(args)))
        case .connectError(let info): return "44" + (try text(info))
        }
    }

    private func text(_ value: JSONValue) throws -> String {
        String(decoding: try value.encoded(), as: UTF8.self)
    }
}
