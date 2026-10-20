import Foundation

/// Native protocol: librespot-org/librespot/protocol/proto/{extended_metadata,metadata}.proto.
enum SpotifyMobileMetadata {
    struct Track { let title: String; let artist: String; let albumURI: String?; let year: String? }
    private final class Box: NSObject { let track: Track; init(_ track: Track) { self.track = track } }
    private static let tracks: NSCache<NSString, Box> = { let c = NSCache<NSString, Box>(); c.countLimit = 128; return c }()
    private static let years: NSCache<NSString, NSString> = { let c = NSCache<NSString, NSString>(); c.countLimit = 128; return c }()
    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral; c.timeoutIntervalForRequest = 8; c.timeoutIntervalForResource = 10
        return URLSession(configuration: c)
    }()
    private struct Field { let number: Int; let integer: UInt64?; let bytes: Data? }
    private static func fields(_ data: Data) -> [Field] {
        let bytes = [UInt8](data); var index = 0, result = [Field]()
        func read() -> UInt64? {
            var value: UInt64 = 0
            for shift in stride(from: 0, through: 63, by: 7) {
                guard index < bytes.count else { return nil }
                let byte = bytes[index]; index += 1
                guard shift != 63 || byte <= 1 else { return nil }
                value |= UInt64(byte & 0x7f) << shift
                if byte & 0x80 == 0 { return value }
            }
            return nil
        }
        while index < bytes.count {
            guard let tag = read(), tag >> 3 > 0 else { return [] }
            let number = Int(tag >> 3)
            switch tag & 7 {
            case 0:
                guard let value = read() else { return [] }
                result.append(Field(number: number, integer: value, bytes: nil))
            case 2:
                guard let length = read(), length <= UInt64(bytes.count - index) else { return [] }
                let end = index + Int(length)
                result.append(Field(number: number, integer: nil, bytes: Data(bytes[index..<end]))); index = end
            case 1, 5:
                let count = tag & 7 == 1 ? 8 : 4
                guard count <= bytes.count - index else { return [] }; index += count
            default: return []
            }
        }
        return result
    }
    private static func bytes(_ field: Int, in data: Data) -> Data? { fields(data).first { $0.number == field }?.bytes }
    private static func string(_ field: Int, in data: Data) -> String? { bytes(field, in: data).flatMap { String(data: $0, encoding: .utf8) } }
    private static func varint(_ value: UInt64) -> Data {
        var value = value, result = Data()
        repeat { let byte = UInt8(value & 127); value >>= 7; result.append(value > 0 ? byte | 128 : byte) } while value > 0
        return result
    }
    private static func message(_ field: Int, _ value: Data) -> Data { varint(UInt64(field * 8 + 2)) + varint(UInt64(value.count)) + value }
    private static func year(in album: Data) -> String? {
        guard let date = bytes(6, in: album), let encoded = fields(date).first(where: { $0.number == 1 })?.integer,
              encoded & 1 == 0, (2000...5998).contains(encoded) else { return nil }
        return String(encoded >> 1) // Date.year uses zigzag encoding (sint32).
    }
    private static func albumURI(_ gid: Data?) -> String? {
        guard let gid, gid.count == 16 else { return nil }
        let alphabet = Array("0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
        var number = [UInt8](gid), digits = [Character]()
        while number.contains(where: { $0 != 0 }) {
            var remainder = 0
            for i in number.indices { let v = remainder * 256 + Int(number[i]); number[i] = UInt8(v / 62); remainder = v % 62 }
            digits.append(alphabet[remainder])
        }
        let id = String(digits.reversed())
        return "spotify:album:" + String(repeating: "0", count: max(0, 22 - id.count)) + id
    }
    private static func request(uri: String, kind: UInt64, completion: @escaping (Data?) -> Void) -> URLSessionDataTask? {
        guard let token = spotifyAccessToken, let url = URL(string: "https://spclient.wg.spotify.com/extended-metadata/v0/extended-metadata") else { completion(nil); return nil }
        let entity = message(1, Data(uri.utf8)) + message(2, varint(8) + varint(kind))
        var request = URLRequest(url: url); request.httpMethod = "POST"; request.httpBody = message(2, entity)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(spotifyClientToken, forHTTPHeaderField: "client-token")
        request.setValue("iOS", forHTTPHeaderField: "App-Platform")
        request.setValue("application/x-protobuf", forHTTPHeaderField: "Content-Type")
        request.setValue("application/x-protobuf", forHTTPHeaderField: "Accept")
        let task = session.dataTask(with: request) { data, response, _ in
            guard (response as? HTTPURLResponse)?.statusCode == 200, let data, data.count <= 2_000_000 else {
                writeDebugLog("[Metadata] extension \(kind) HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
                completion(nil); return
            }
            for array in fields(data).filter({ $0.number == 2 }).compactMap(\.bytes) {
                for entry in fields(array).filter({ $0.number == 3 }).compactMap(\.bytes) {
                    guard let any = bytes(3, in: entry), let value = bytes(2, in: any) else { continue }
                    completion(value); return
                }
            }
            writeDebugLog("[Metadata] extension \(kind) missing from native response")
            completion(nil)
        }
        task.resume(); return task
    }
    @discardableResult static func track(_ id: String, completion: @escaping (Track?) -> Void) -> URLSessionDataTask? {
        if let cached = tracks.object(forKey: id as NSString) { completion(cached.track); return nil }
        guard id.range(of: "^[A-Za-z0-9]{22}$", options: .regularExpression) != nil else { completion(nil); return nil }
        return request(uri: "spotify:track:\(id)", kind: 10) { data in
            guard let data, let title = string(2, in: data), let artistData = bytes(4, in: data), let artist = string(2, in: artistData) else { completion(nil); return }
            let album = bytes(3, in: data)
            let value = Track(title: title, artist: artist, albumURI: albumURI(album.flatMap { bytes(1, in: $0) }), year: album.flatMap { year(in: $0) })
            tracks.setObject(Box(value), forKey: id as NSString); completion(value)
        }
    }
    @discardableResult static func albumYear(_ uri: String, completion: @escaping (String?) -> Void) -> URLSessionDataTask? {
        if let cached = years.object(forKey: uri as NSString) { completion(cached as String); return nil }
        guard uri.range(of: "^spotify:album:[A-Za-z0-9]{22}$", options: .regularExpression) != nil else { completion(nil); return nil }
        return request(uri: uri, kind: 9) { data in
            let value = data.flatMap { year(in: $0) }
            if let value { years.setObject(value as NSString, forKey: uri as NSString) }
            completion(value)
        }
    }
}
