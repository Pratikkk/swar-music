import Decoding
import FormatInfo
import Testing

struct FormatClassifierTests {
    private func source(codec: String = "ALAC", depth: Int? = 24, rate: Double = 96_000,
                        channels: Int = 2, lossless: Bool = true, floating: Bool = false,
                        bitrate: UInt32? = nil) -> SourceFormat {
        SourceFormat(codec: codec, sampleRate: rate, bitDepth: depth, channels: channels,
                     isLossless: lossless, isFloat: floating, bitRate: bitrate)
    }

    private func output(depth: Int? = 24, rate: Double = 96_000, channels: Int? = 2, floating: Bool = false) -> SignalOutput {
        SignalOutput(name: "Test DAC", sampleRate: rate, bitDepth: depth, channels: channels, isFloat: floating)
    }

    private func verifiedPath() -> SignalPath {
        SignalPath(output: output(),
                   clientPCM: SignalPCM(sampleRate: 96_000, validBits: 24,
                                        containerBits: 24, channels: 2, isFloat: false),
                   isExclusive: true, transport: .local,
                   systemVolume: .unity, integrity: .verifiedUnchanged)
    }

    @Test(arguments: [
        (16, 44_100.0, FormatTier.lossless),
        (24, 44_100.0, .lossless),
        (24, 48_000.0, .lossless),
        (16, 88_200.0, .hiResLossless),
        (24, 96_000.0, .hiResLossless),
        (24, 192_000.0, .hiResLossless),
        (32, 48_000.0, .hiResLossless),
        (32, 384_000.0, .hiResLossless)
    ])
    func losslessThresholds(depth: Int, rate: Double, expected: FormatTier) {
        let info = FormatClassifier.describe(source: source(depth: depth, rate: rate), path: SignalPath())
        #expect(info.tier == expected)
        #expect(info.label == "\(expected == .lossless ? "Lossless" : "Hi-Res Lossless") · ALAC")
    }

    @Test func thresholdsAreConfigurable() {
        let info = FormatClassifier.describe(source: source(depth: 32), path: SignalPath(),
            thresholds: FormatThresholds(losslessMaximumBitDepth: 32, losslessMaximumSampleRate: 192_000))
        #expect(info.tier == .lossless)
    }

    @Test(arguments: [("AAC", UInt32(256_000)), ("MP3", 320_000), ("Opus", 160_000), ("Vorbis", 192_000)])
    func lossyLabelsIncludeDecoderBitrate(codec: String, bitrate: UInt32) {
        let info = FormatClassifier.describe(source: source(codec: codec, depth: nil, rate: 48_000,
                                                           lossless: false, bitrate: bitrate), path: SignalPath())
        #expect(info.tier == .lossy)
        #expect(info.label == "\(codec) · \(bitrate / 1000) kbps")
        #expect(!info.sourceDetail.contains("24-bit"))
        #expect(!info.accessibilityLabel.contains("Lossless"))
    }

    @Test func unavailableBitrateIsNotInvented() {
        for bitrate: UInt32? in [nil, 0] {
            let info = FormatClassifier.describe(source: source(codec: "AAC", depth: nil, lossless: false, bitrate: bitrate), path: SignalPath())
            #expect(info.label == "AAC")
        }
    }

    @Test(arguments: [64, 128, 256, 512])
    func dsdPresentationForFutureDecoders(multiple: Int) {
        let info = FormatClassifier.describe(source: source(codec: "DSD", depth: 1, rate: 44_100 * Double(multiple)), path: SignalPath())
        #expect(info.tier == .dsd)
        #expect(info.label == "DSD\(multiple)")
        #expect(info.status == .unverified)
    }

    @Test func equalFormatsAreNotProof() {
        let info = FormatClassifier.describe(source: source(), path: SignalPath(output: output()))
        #expect(info.status == .unverified)
        #expect(info.conversionReasons.isEmpty)
        #expect(info.verificationNotes.contains("Sample equality at the output has not been verified."))
    }

    @Test func verifiedPathRequiresEvidenceAndNoUnknownStages() {
        let info = FormatClassifier.describe(source: source(), path: verifiedPath())
        #expect(info.status == .bitPerfect)
        #expect(info.conversionReasons.isEmpty)
        #expect(info.verificationNotes.isEmpty)
        #expect(info.isExclusive)
        for stage in 0..<4 {
            var path = verifiedPath()
            switch stage {
            case 0: path.isExclusive = false
            case 1: path.systemVolume = .unknown
            case 2: path.transport = .unknown
            default: path.integrity = .unverified
            }
            #expect(FormatClassifier.describe(source: source(), path: path).status == .unverified)
        }
    }

    @Test(arguments: ["softwareVolume", "equalizer", "loudnessMatching", "systemVolume", "bluetooth", "airPlay"])
    func processingOverridesVerification(feature: String) {
        var path = verifiedPath()
        switch feature {
        case "softwareVolume": path.softwareVolume = true
        case "equalizer": path.equalizer = true
        case "loudnessMatching": path.loudnessMatching = true
        case "systemVolume": path.systemVolume = .attenuated
        case "bluetooth": path.transport = .bluetooth
        default: path.transport = .airPlay
        }
        let info = FormatClassifier.describe(source: source(), path: path)
        #expect(info.status == .converted)
        #expect(info.conversionReasons.count == 1)
    }

    @Test func differingPhysicalRepresentationRequiresVerificationNotConversionClaim() {
        let info = FormatClassifier.describe(source: source(), path: SignalPath(output: output(depth: 32, floating: true)))
        #expect(info.label == "Hi-Res Lossless · ALAC")
        #expect(info.status == .unverified)
        #expect(info.conversionReasons.isEmpty)
        #expect(info.verificationNotes.contains("Decoded PCM representation is unavailable."))
        #expect(info.outputDetail.contains("32-bit float"))
        #expect(info.sourceDetail.contains("24-bit"))
    }

    @Test func reportsResamplingAndChannelMapping() {
        let info = FormatClassifier.describe(source: source(), path: SignalPath(output: output(rate: 48_000, channels: 1)))
        #expect(info.status == .converted)
        #expect(info.conversionReasons.contains("Sample rate changes from 96 kHz to 48 kHz."))
        #expect(info.conversionReasons.contains("Channel count changes from 2 to 1."))
    }

    @Test func unknownOutputDoesNotProduceVerifiedCheck() {
        var path = verifiedPath()
        path.output = nil
        #expect(FormatClassifier.describe(source: source(), path: path).status == .unverified)
        path.output = output(depth: nil, channels: nil)
        #expect(FormatClassifier.describe(source: source(), path: path).status == .unverified)
        path.output = output(rate: .nan)
        #expect(FormatClassifier.describe(source: source(), path: path).status == .unverified)
    }

    @Test func widerPhysicalContainerDoesNotImplyAlteredSamples() {
        let pcm = SignalPCM(sampleRate: 96_000, validBits: 24,
                            containerBits: 32, channels: 2, isFloat: false)
        let path = SignalPath(output: output(depth: 32), clientPCM: pcm)
        let info = FormatClassifier.describe(source: source(), path: path)
        #expect(info.status == .unverified)
        #expect(info.conversionReasons.isEmpty)
        #expect(info.clientPCM?.containerBits == 32)
        #expect(info.clientPCM?.validBits == 24)
    }

    @Test func underrunsAreReportedWithoutClaimingPCMConversion() {
        let path = SignalPath(output: output(), underrunFrames: 128)
        let info = FormatClassifier.describe(source: source(), path: path)
        #expect(info.underrunFrames == 128)
        #expect(info.verificationNotes.contains("Playback underruns detected: 128 frames."))
        #expect(info.conversionReasons.isEmpty)
        #expect(info.status == .unverified)
    }

    @Test func matchingFormatsWithoutIntegrityEvidenceNeverClaimBitPerfect() {
        let pcm = SignalPCM(sampleRate: 96_000, validBits: 24,
                            containerBits: 24, channels: 2, isFloat: false)
        let path = SignalPath(output: output(), clientPCM: pcm,
                              isExclusive: true, transport: .local,
                              systemVolume: .unity, integrity: .unverified)
        let info = FormatClassifier.describe(source: source(), path: path)
        #expect(info.status == .unverified)
        #expect(info.conversionReasons.isEmpty)
    }

    @Test func verifiedSamplesWithUnderrunsDoNotClaimContinuousBitPerfectPlayback() {
        var path = verifiedPath()
        path.underrunFrames = 64
        let info = FormatClassifier.describe(source: source(), path: path)
        #expect(info.status == .unverified)
        #expect(info.underrunFrames == 64)
    }

    @Test func losslessCodecAndAccessibleDetailsArePreserved() {
        let info = FormatClassifier.describe(source: source(codec: "FLAC"), path: SignalPath())
        #expect(info.label == "Hi-Res Lossless · FLAC")
        #expect(info.accessibilityLabel == "Hi-Res Lossless FLAC, 24-bit, 96 kilohertz, Not verified")
        let standard = FormatClassifier.describe(source: source(depth: 16, rate: 44_100), path: SignalPath())
        #expect(standard.accessibilityLabel.contains("44.1 kilohertz"))
    }

    @Test func changingTracksUpdatesLabelAndStatusTogether() {
        let first = FormatClassifier.describe(source: source(), path: SignalPath(output: output(depth: 32, floating: true)))
        let next = FormatClassifier.describe(source: source(codec: "AAC", depth: nil, rate: 44_100, lossless: false, bitrate: 256_000),
                                             path: SignalPath(output: output(depth: 32, rate: 44_100, floating: true)))
        #expect(first.status == .converted)
        #expect(next.label == "AAC · 256 kbps")
        #expect(next.status == .unverified)
        #expect(next.conversionReasons.isEmpty)
    }
}
