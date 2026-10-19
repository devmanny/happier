import Foundation

/// Base64 helpers matching `packages/protocol/src/crypto/base64.ts`.
public enum Base64 {
    /// Lenient decoder: accepts standard or url alphabets, with or without padding or whitespace.
    public static func decode(_ input: String) -> Data? {
        // Fast path: canonical padded base64 (all wire ciphertexts). The lenient walk below is
        // only for user-typed keys and URL-safe values.
        if let data = Data(base64Encoded: input) { return data }
        var chars = input.unicodeScalars.compactMap { scalar -> Character? in
            switch scalar {
            case "-": return "+"
            case "_": return "/"
            case "A"..."Z", "a"..."z", "0"..."9", "+", "/": return Character(scalar)
            default: return nil
            }
        }
        if chars.count % 4 == 1 { chars.removeLast() }
        while chars.count % 4 != 0 { chars.append("=") }
        return Data(base64Encoded: String(chars))
    }

    public static func urlEncoded(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// The user-facing backup key: RFC 4648 base32, grouped in fives (`secretKeyBackup.ts`).
public enum SecretKeyFormat {
    public struct InvalidKey: Error {}

    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")

    public static func format(_ secret: Data) -> String {
        var bits = 0, value = 0
        var output = ""
        for byte in secret {
            value = (value << 8) | Int(byte)
            bits += 8
            while bits >= 5 {
                output.append(alphabet[(value >> (bits - 5)) & 31])
                bits -= 5
            }
        }
        if bits > 0 { output.append(alphabet[(value << (5 - bits)) & 31]) }
        return stride(from: 0, to: output.count, by: 5).map { start in
            let begin = output.index(output.startIndex, offsetBy: start)
            return String(output[begin..<(output.index(begin, offsetBy: 5, limitedBy: output.endIndex) ?? output.endIndex)])
        }.joined(separator: "-")
    }

    public static func parse(_ input: String) throws -> Data {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = Base64.decode(trimmed), data.count == 32 { return data }
        let normalized = trimmed.uppercased().map { c -> Character in
            switch c { case "0": "O"; case "1": "I"; case "8": "B"; case "9": "G"; default: c }
        }
        var bits = 0, value = 0
        var bytes = Data()
        for c in normalized {
            guard let index = alphabet.firstIndex(of: c) else { continue }
            value = ((value << 5) | index) & 0xFFFF
            bits += 5
            if bits >= 8 {
                bytes.append(UInt8((value >> (bits - 8)) & 0xFF))
                bits -= 8
            }
        }
        guard bytes.count == 32 else { throw InvalidKey() }
        return bytes
    }
}

/// Session avatar selection, identical to `avatarHash.ts` + `AvatarGradient.tsx`.
public enum AvatarHash {
    public static func positiveInt(_ value: String) -> Int {
        var hash: Int32 = 0
        for unit in value.utf16 { hash = (hash &<< 5) &- hash &+ Int32(unit) }
        return Int(hash.magnitude)
    }

    /// Index into the 100 bundled gradients (`Gradients/01` … `Gradients/100`).
    public static func gradientIndex(_ id: String) -> Int { positiveInt(id) % 100 }
}
