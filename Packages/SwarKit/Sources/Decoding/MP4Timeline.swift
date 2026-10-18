import Foundation

/// Core Audio can ignore MP4 edit lists for ALAC. Inspect only box headers and
/// the small timing records; never load media/artwork payloads or sample tables.
enum MP4Timeline {
    private struct Box {
        let type: String
        let payload: UInt64
        let end: UInt64
    }

    static func requiresBundledDecoder(url: URL, frames: Int64, sampleRate: Double) throws -> Bool {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let length = try file.seekToEnd()
        func read(_ offset: UInt64, _ count: Int) throws -> [UInt8] {
            try file.seek(toOffset: offset)
            let data = try file.read(upToCount: count) ?? Data()
            guard data.count == count else { throw AudioFailure("The MP4 timing records are truncated.") }
            return Array(data)
        }
        func integer(_ bytes: [UInt8], _ offset: Int, _ size: Int) -> UInt64 {
            bytes[offset..<(offset + size)].reduce(0) { ($0 << 8) | UInt64($1) }
        }
        guard length >= 8 else { return false }
        let signature = String(decoding: try read(4, 4), as: UTF8.self)
        guard ["ftyp", "moov", "wide", "free", "mdat"].contains(signature) else { return false } // e.g. ALAC in CAF
        var inspected = 0
        func boxes(_ start: UInt64, _ end: UInt64) throws -> [Box] {
            var offset = start
            var result: [Box] = []
            while end - offset >= 8 {
                inspected += 1
                guard inspected <= 10_000 else { throw AudioFailure("The MP4 timing structure is too complex.") }
                let header = try read(offset, 8)
                let type = String(decoding: header[4..<8], as: UTF8.self)
                var size = integer(header, 0, 4)
                var headerSize: UInt64 = 8
                if size == 1 {
                    guard end - offset >= 16 else { throw AudioFailure("The MP4 box header is truncated.") }
                    size = integer(try read(offset + 8, 8), 0, 8); headerSize = 16
                } else if size == 0 { size = end - offset }
                guard size >= headerSize, size <= end - offset else { throw AudioFailure("The MP4 box size is invalid.") }
                result.append(Box(type: type, payload: offset + headerSize, end: offset + size))
                offset += size
            }
            return result
        }
        func children(_ box: Box) throws -> [Box] { try boxes(box.payload, box.end) }
        guard let movie = try boxes(0, length).first(where: { $0.type == "moov" }) else { return false }
        let movieBoxes = try children(movie)
        var movieRate: UInt64 = 0
        if let header = movieBoxes.first(where: { $0.type == "mvhd" }), header.end - header.payload >= 16 {
            let data = try read(header.payload, Int(min(24, header.end - header.payload)))
            if data[0] == 0 { movieRate = integer(data, 12, 4) }
            else if data[0] == 1, data.count >= 24 { movieRate = integer(data, 20, 4) }
        }
        for track in movieBoxes where track.type == "trak" {
            let trackBoxes = try children(track)
            guard let media = trackBoxes.first(where: { $0.type == "mdia" }),
                  let handler = try children(media).first(where: { $0.type == "hdlr" }), handler.end - handler.payload >= 12,
                  String(decoding: try read(handler.payload + 8, 4), as: UTF8.self) == "soun",
                  let edits = trackBoxes.first(where: { $0.type == "edts" }),
                  let list = try children(edits).first(where: { $0.type == "elst" }) else { continue }
            let data = try read(list.payload, Int(min(32, list.end - list.payload)))
            guard data.count >= 8 else { return true }
            if integer(data, 4, 4) != 1 || data[0] > 1 { return true }
            let wide = data[0] == 1
            guard data.count >= (wide ? 28 : 20) else { return true }
            let duration = integer(data, 8, wide ? 8 : 4)
            let mediaTime = integer(data, wide ? 16 : 12, wide ? 8 : 4)
            if mediaTime != 0 || integer(data, wide ? 24 : 16, 4) != 0x10000 { return true }
            if movieRate > 0 {
                // Accept only rounding to adjacent movie ticks. If movie ticks
                // are sample-exact, even a one-sample trim must be honored.
                let expected = Double(frames) * Double(movieRate) / sampleRate
                if Double(duration) < floor(expected) || Double(duration) > ceil(expected) { return true }
            }
        }
        return false
    }
}
