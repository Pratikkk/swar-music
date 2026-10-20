import Decoding
import Foundation
import ImageIO
import CryptoKit
import UniformTypeIdentifiers

public struct AudioTags: Codable, Sendable {
    public var title: String?
    public var artist: String?
    public var albumArtist: String?
    public var album: String?
    public var genre: String?
    public var composer: String?
    public var comment: String?
    public var lyrics: String?
    public var date: String?
    public var track: String?
    public var disc: String?
    public var compilation: Bool
    public var replayGainTrack: String?
    public var replayGainAlbum: String?
}

protocol MediaInspecting: Sendable {
    var artworkDirectory: URL { get }
    func inspect(file: ScanFile, folder: LibraryFolder, prior: ScanFingerprint?) -> LibraryTrack
}

struct MediaInspector: MediaInspecting {
    let codecDirectory: URL?
    let artworkDirectory: URL

    func inspect(file: ScanFile, folder: LibraryFolder, prior: ScanFingerprint?) -> LibraryTrack {
        var track = LibraryTrack(id: prior?.id ?? folder.id + ":" + file.relativePath, folderID: folder.id,
            relativePath: file.relativePath, title: file.url.deletingPathExtension().lastPathComponent,
            artist: "Unknown Artist", albumArtist: "Unknown Artist", album: file.url.deletingLastPathComponent().lastPathComponent,
            genre: "Unknown Genre", trackNumber: 0, discNumber: 1, year: nil, tagsJSON: nil,
            codec: nil, bitDepth: nil, sampleRate: nil, channels: nil, bitRate: nil, isLossless: false, isFloat: false,
            duration: 0, fileSize: file.size, modifiedAt: file.modified, addedAt: prior?.addedAt ?? Date(),
            artworkKey: nil, coverStamp: file.coverStamp, error: nil)
        do {
            // One FFmpeg probe supplies metadata and audio facts when available.
            // Optional metadata must not make a native-playable file unreadable.
            let (decoder, metadata) = try probe(file.url)
            let source = decoder.source
            track.codec = source.codec; track.bitDepth = source.bitDepth; track.sampleRate = source.sampleRate
            track.channels = source.channels; track.bitRate = source.bitRate; track.isLossless = source.isLossless; track.isFloat = source.isFloat
            track.duration = Double(decoder.frameCount) / source.sampleRate
            let tags = AudioTags(title: metadata?.tag("title"), artist: metadata?.tag("artist"),
                albumArtist: metadata?.tag("album_artist", "albumartist"), album: metadata?.tag("album"),
                genre: metadata?.tag("genre"), composer: metadata?.tag("composer"), comment: metadata?.tag("comment", "description"),
                lyrics: metadata?.tag("lyrics", "unsyncedlyrics"), date: metadata?.tag("date", "year"),
                track: metadata?.tag("track", "tracknumber"), disc: metadata?.tag("disc", "discnumber"),
                compilation: ["1", "true"].contains(metadata?.tag("compilation")?.lowercased() ?? ""),
                replayGainTrack: metadata?.tag("replaygain_track_gain"), replayGainAlbum: metadata?.tag("replaygain_album_gain"))
            track.title = tags.title ?? track.title
            track.artist = tags.artist ?? track.artist
            track.albumArtist = tags.albumArtist ?? (tags.compilation ? "Various Artists" : track.artist)
            track.album = tags.album ?? track.album; track.genre = tags.genre ?? track.genre
            track.trackNumber = Self.number(tags.track) ?? 0; track.discNumber = Self.number(tags.disc) ?? 1
            track.year = tags.date.map { String($0.prefix(4)) }
            track.tagsJSON = String(data: try JSONEncoder().encode(tags), encoding: .utf8)
            let artwork = metadata?.embeddedArtwork ?? file.coverURL.flatMap { try? Data(contentsOf: $0, options: .mappedIfSafe) }
            if let artwork { track.artworkKey = try? cacheArtwork(artwork) }
        } catch { track.error = error.localizedDescription }
        return track
    }

    private func probe(_ url: URL) throws -> (any AudioDecoding, FFmpegDecoder?) {
        do {
            let metadata = try FFmpegDecoder(url: url, codecDirectory: codecDirectory)
            return (metadata, metadata)
        } catch {
            let codecFailure = error.localizedDescription
            do { return (try NativeDecoder(url: url), nil) }
            catch {
                throw AudioFailure("Could not decode this file. Native decoder: \(error.localizedDescription) Additional codecs: \(codecFailure)")
            }
        }
    }

    private static func number(_ value: String?) -> Int? { value.flatMap { Int($0.split(separator: "/").first ?? "") } }

    func cacheArtwork(_ data: Data, maximumPixelSize: Int = 384) throws -> String? {
        guard data.count <= 20 * 1024 * 1024 else { return nil }
        let key = (maximumPixelSize == 384 ? "" : "custom-\(maximumPixelSize)-") + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() + ".png"
        let target = artworkDirectory.appendingPathComponent(key)
        if FileManager.default.fileExists(atPath: target.path) { return key }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
                kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        try FileManager.default.createDirectory(at: artworkDirectory, withIntermediateDirectories: true)
        try (output as Data).write(to: target, options: .atomic)
        return key
    }
}
