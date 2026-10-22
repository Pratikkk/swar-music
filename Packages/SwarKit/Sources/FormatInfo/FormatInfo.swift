import Decoding
import Foundation

/// Source-quality thresholds, independent of device capabilities and path integrity.
public struct FormatThresholds: Sendable {
    public var losslessMaximumBitDepth: Int
    public var losslessMaximumSampleRate: Double

    public init(losslessMaximumBitDepth: Int = 24, losslessMaximumSampleRate: Double = 48_000) {
        self.losslessMaximumBitDepth = losslessMaximumBitDepth
        self.losslessMaximumSampleRate = losslessMaximumSampleRate
    }
}

public enum FormatTier: Sendable, Equatable { case lossless, hiResLossless, lossy, dsd }
public enum SignalStatus: String, Sendable { case unverified = "Not verified", converted = "Converted", bitPerfect = "Bit-perfect" }
public enum OutputTransport: Sendable { case local, bluetooth, airPlay, unknown }
public enum SystemVolumeState: Sendable { case unity, attenuated, unknown }

/// Only an engine backed by sample-integrity verification may supply verifiedUnchanged.
/// Source/device metadata equality is not such evidence.
public enum SampleIntegrity: Sendable { case unverified, verifiedUnchanged }

/// Format of PCM supplied to AUHAL, independent of file encoding and the
/// physical format advertised by the device driver.
public struct SignalPCM: Sendable, Equatable {
    public let sampleRate: Double
    public let validBits: Int
    public let containerBits: Int
    public let channels: Int
    public let isFloat: Bool

    public init(sampleRate: Double, validBits: Int, containerBits: Int,
                channels: Int, isFloat: Bool) {
        self.sampleRate = sampleRate
        self.validBits = validBits
        self.containerBits = containerBits
        self.channels = channels
        self.isFloat = isFloat
    }

    public var detail: String {
        let precision = validBits == containerBits ? "\(validBits)-bit" :
            "\(validBits)-bit in \(containerBits)-bit container"
        return "\(precision) \(isFloat ? "float" : "integer") · \(sampleRate / 1000) kHz · \(channels) ch"
    }
}

public struct SignalOutput: Sendable, Equatable {
    public let name: String
    public let sampleRate: Double
    public let bitDepth: Int?
    public let channels: Int?
    public let isFloat: Bool

    public init(name: String, sampleRate: Double, bitDepth: Int?, channels: Int?, isFloat: Bool) {
        self.name = name
        self.sampleRate = sampleRate
        self.bitDepth = bitDepth
        self.channels = channels
        self.isFloat = isFloat
    }
}

public struct SignalPath: Sendable {
    public var output: SignalOutput?
    public var clientPCM: SignalPCM?
    public var underrunFrames: UInt64
    public var softwareVolume: Bool
    public var equalizer: Bool
    public var loudnessMatching: Bool
    public var isExclusive: Bool
    public var transport: OutputTransport
    public var systemVolume: SystemVolumeState
    public var integrity: SampleIntegrity

    public init(output: SignalOutput? = nil, clientPCM: SignalPCM? = nil, underrunFrames: UInt64 = 0, softwareVolume: Bool = false,
                equalizer: Bool = false, loudnessMatching: Bool = false,
                isExclusive: Bool = false, transport: OutputTransport = .unknown,
                systemVolume: SystemVolumeState = .unknown, integrity: SampleIntegrity = .unverified) {
        self.output = output
        self.clientPCM = clientPCM
        self.underrunFrames = underrunFrames
        self.softwareVolume = softwareVolume
        self.equalizer = equalizer
        self.loudnessMatching = loudnessMatching
        self.isExclusive = isExclusive
        self.transport = transport
        self.systemVolume = systemVolume
        self.integrity = integrity
    }
}

public struct FormatChipInfo: Sendable, Equatable {
    public let source: SourceFormat
    public let output: SignalOutput?
    public let clientPCM: SignalPCM?
    public let underrunFrames: UInt64
    public let tier: FormatTier
    public let label: String
    public let status: SignalStatus
    public let conversionReasons: [String]
    public let verificationNotes: [String]
    public let isExclusive: Bool

    public var sourceDetail: String {
        var parts = [source.codec]
        if let depth = source.bitDepth { parts.append("\(depth)-bit\(source.isFloat ? " float" : "")") }
        parts.append("\(number(source.sampleRate / 1000)) kHz")
        parts.append("\(source.channels) \(source.channels == 1 ? "channel" : "channels")")
        if let rate = source.bitRate, rate > 0, !source.isLossless { parts.append("\(rate / 1000) kbps") }
        return parts.joined(separator: " · ")
    }

    public var outputDetail: String {
        guard let output else { return "Output unavailable" }
        let depth = output.bitDepth.map { "\($0)-bit \(output.isFloat ? "float" : "integer")" } ?? "Unknown bit depth"
        let channels = output.channels.map { " · \($0) \($0 == 1 ? "channel" : "channels")" } ?? ""
        return "\(depth) · \(number(output.sampleRate / 1000)) kHz\(channels)"
    }

    public var accessibilityLabel: String {
        var details = [label.replacingOccurrences(of: " · ", with: " ")]
        if let depth = source.bitDepth { details.append("\(depth)-bit") }
        details.append("\(number(source.sampleRate / 1000)) kilohertz")
        details.append(status.rawValue)
        return details.joined(separator: ", ")
    }

    private func number(_ value: Double) -> String { String(format: "%g", value) }
}

public enum FormatClassifier {
    public static func describe(source: SourceFormat, path: SignalPath,
                                thresholds: FormatThresholds = FormatThresholds()) -> FormatChipInfo {
        let tier: FormatTier
        let label: String
        let codec = source.codec.uppercased()
        if codec == "DSD" {
            // Presentation support for a future decoder; this does not enable DSD playback.
            tier = .dsd
            let multiple = source.sampleRate / 44_100
            label = [64.0, 128, 256, 512].contains(multiple) ? "DSD\(Int(multiple))" : "DSD"
        } else if source.isLossless {
            let highResolution = source.sampleRate > thresholds.losslessMaximumSampleRate ||
                (source.bitDepth.map { $0 > thresholds.losslessMaximumBitDepth } ?? false)
            tier = highResolution ? .hiResLossless : .lossless
            label = "\(highResolution ? "Hi-Res Lossless" : "Lossless") · \(source.codec)"
        } else {
            tier = .lossy
            label = source.bitRate.flatMap { $0 > 0 ? "\(source.codec) · \($0 / 1000) kbps" : nil } ?? source.codec
        }

        var conversions: [String] = []
        var notes: [String] = []
        if path.softwareVolume { conversions.append("Software volume changes the decoded samples.") }
        if path.equalizer { conversions.append("Equalization changes the decoded samples.") }
        if path.loudnessMatching { conversions.append("Loudness matching changes the decoded samples.") }
        if path.systemVolume == .attenuated { conversions.append("System volume attenuates the signal.") }
        switch path.transport {
        case .bluetooth: conversions.append("Bluetooth output uses a converted signal path.")
        case .airPlay: conversions.append("AirPlay output uses a converted signal path.")
        case .unknown: notes.append("Output transport has not been verified.")
        case .local: break
        }
        if let pcm = path.clientPCM {
            if pcm.sampleRate != source.sampleRate {
                conversions.append("Decoder PCM rate differs from source rate.")
            }
            if pcm.channels != source.channels {
                conversions.append("Decoder PCM channel count differs from source.")
            }
        }
        if path.underrunFrames > 0 {
            notes.append("Playback underruns detected: \(path.underrunFrames) frames.")
        }
        if let output = path.output {
            if !output.sampleRate.isFinite || output.sampleRate <= 0 {
                notes.append("Output sample rate is unavailable.")
            } else if output.sampleRate != source.sampleRate {
                conversions.append("Sample rate changes from \(khz(source.sampleRate)) to \(khz(output.sampleRate)).")
            }
            if codec == "DSD" {
                notes.append("DSD delivery (PCM or DoP) has not been verified.")
            } else if source.isLossless {
                // Physical container width may exceed sample precision without
                // changing values (for example 24 valid bits in a 32-bit slot).
                // A mismatch is evidence of a differing representation, not
                // evidence that the audio samples were changed.
                if let pcm = path.clientPCM {
                    if pcm.isFloat != output.isFloat {
                        notes.append("AUHAL PCM representation differs from the device format.")
                    }
                    if let depth = output.bitDepth, depth > 0,
                       depth < pcm.validBits {
                        notes.append("Device precision is below decoded PCM precision.")
                    }
                } else {
                    notes.append("Decoded PCM representation is unavailable.")
                }
            }
            if let channels = output.channels, channels > 0 {
                if channels != source.channels { conversions.append("Channel count changes from \(source.channels) to \(channels).") }
            } else { notes.append("Output channel count is unavailable.") }
        } else { notes.append("The output device format is unavailable.") }

        if !path.isExclusive { notes.append("Shared output: other apps may mix audio or change the device format.") }
        if path.systemVolume == .unknown { notes.append("System volume applies; its effect on samples has not been measured.") }
        if path.clientPCM == nil { notes.append("AUHAL client PCM format has not been inspected.") }
        if path.integrity == .unverified { notes.append("Sample equality at the output has not been verified.") }
        // A status label must never infer measured bit-perfect delivery from
        // matching metadata or the absence of diagnostic warnings.
        let canClaimVerified = path.integrity == .verifiedUnchanged &&
            path.output != nil && path.clientPCM != nil &&
            path.transport == .local && path.isExclusive &&
            path.systemVolume == .unity && path.underrunFrames == 0
        let status: SignalStatus = !conversions.isEmpty ? .converted :
            (canClaimVerified && notes.isEmpty ? .bitPerfect : .unverified)
        return FormatChipInfo(source: source, output: path.output, clientPCM: path.clientPCM, underrunFrames: path.underrunFrames, tier: tier, label: label,
                              status: status, conversionReasons: conversions, verificationNotes: notes,
                              isExclusive: path.isExclusive)
    }

    private static func khz(_ rate: Double) -> String { "\(String(format: "%g", rate / 1000)) kHz" }
}
