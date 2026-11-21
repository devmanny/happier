import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Testing
@testable import HappierKit

/// Agent photos (`packages/protocol/src/agentProfiles/agentPhoto.ts`): a small JPEG per agent,
/// sealed for the account under `agentphoto/<id>`, apart from the profile.
struct AgentPhotoTests {
    static let machineKey = Data(0..<32)

    /// `sealAccountScopedBlobCiphertext({kind:'agent_photo', material:{type:'dataKey', machineKey:0..31},
    /// payload:{v:1,id:'a-tomas',mime:'image/jpeg',data:'/9j/4AAQ',updatedAt:5}})` with a nonce of zeros.
    static let tsSealed = "oREAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAuNmJ2rkWRp1KYAAg3uK20N380RHdCCtOa4tr8YNxfhbv9xxnF0IAfmUUYirsP8ykKj9yM5DDFEi4e1dmExhIpCOTzZDgD4kPhIXCY13sBk/bG9Di73wcOJ3M="

    @Test func opensWhatTheTypeScriptClientSeals() throws {
        let photo = try #require(AgentPhoto.open(Self.tsSealed, machineKey: Self.machineKey))
        #expect(photo.id == "a-tomas")
        #expect(photo.jpeg == Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10]))
        #expect(photo.updatedAt == 5)
        // Not a profile, and not readable with another key.
        #expect(AgentProfile.open(Self.tsSealed, machineKey: Self.machineKey) == nil)
        #expect(AgentPhoto.open(Self.tsSealed, machineKey: Data(repeating: 9, count: 32)) == nil)
    }

    @Test func sealsUnderItsOwnKindAndOpensAgain() throws {
        let photo = AgentPhoto(id: "a-julian", jpeg: Data([0xFF, 0xD8, 1, 2, 3]), updatedAt: 7)
        let sealed = try photo.sealed(machineKey: Self.machineKey)
        #expect(Base64.decode(sealed)?.prefix(2) == Data([0xA1, 17]))
        #expect(AgentPhoto.open(sealed, machineKey: Self.machineKey) == photo)
        #expect(AgentPhoto.kvKey(id: "A-Julian") == "agentphoto/a-julian")
    }

    @Test func readsEachAgentsPhotoFromAListing() throws {
        let tomas = try AgentPhoto(id: "a-tomas", jpeg: Data([0xFF, 0xD8, 1]), updatedAt: 1).sealed(machineKey: Self.machineKey)
        let items: JSONValue = ["items": [
            ["key": "agentphoto/a-tomas", "value": .string(tomas), "version": 2],
            // Removed, filed under another agent, or unreadable: skipped.
            ["key": "agentphoto/a-mateo", "value": "", "version": 3],
            ["key": "agentphoto/a-julian", "value": .string(tomas), "version": 1],
            ["key": "agentphoto/a-leo", "value": "bm90IHNlYWxlZA==", "version": 1],
        ]]
        let photos = AgentPhoto.records(fromList: items, machineKey: Self.machineKey)
        #expect(photos.map(\.photo.id) == ["a-tomas"])
        #expect(photos.first?.version == 2)
    }

    /// A picked photo becomes a small square JPEG: cropped to its center, at most `side` pixels.
    @Test func makesASmallSquareJPEGFromAPickedImage() throws {
        func png(width: Int, height: Int) throws -> Data {
            let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                                 space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let out = NSMutableData()
            let destination = try #require(CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
            #expect(CGImageDestinationFinalize(destination))
            return out as Data
        }
        func size(_ jpeg: Data) throws -> (Int, Int) {
            let image = try #require(CGImageSourceCreateWithData(jpeg as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
            return (image.width, image.height)
        }
        let wide = try #require(AgentPhoto.squareJPEG(from: try png(width: 1200, height: 800), side: 512))
        #expect(wide.prefix(2) == Data([0xFF, 0xD8]))
        #expect(try size(wide) == (512, 512))
        let small = try #require(AgentPhoto.squareJPEG(from: try png(width: 300, height: 200), side: 512))
        #expect(try size(small) == (200, 200))
        #expect(AgentPhoto.squareJPEG(from: Data("not an image".utf8)) == nil)
    }
}
