import Testing
import Foundation
import Decoding
@testable import Player

struct TransitionPlannerTests {
    private func profile(bpm: Double = 120, confidence: Double = 0.9, duration: Double = 120,
                         phase: Double = 0.2) -> RhythmProfile {
        RhythmProfile(bpm: bpm, confidence: confidence,
            beats: Array(stride(from: phase, through: duration, by: 60 / bpm)),
            duration: duration, energy: Array(repeating: 0.2, count: Int(ceil(duration * 2))))
    }
    private func plan(_ outgoing: RhythmProfile?, _ incoming: RhythmProfile?, notBefore: Double = 0,
                      beats: Int = 8, album: Bool = false) -> TransitionPlan {
        TransitionPlanner.plan(outgoing: outgoing, incoming: incoming, outgoingDuration: 120,
            incomingDuration: 120, notBefore: notBefore, preferredBeats: beats, preserveGapless: album)
    }

    @Test func matchesActualBeatPhaseWithoutSkippingTheIntro() {
        let outgoing = profile(phase: 0.35), incoming = profile(phase: 0.17)
        let result = plan(outgoing, incoming)
        #expect(result.mode == .beatAligned && result.beats == 8)
        #expect(result.incomingStart == 0)
        #expect(abs(result.outgoingStart + result.duration - 120) < 1e-8)
        #expect(outgoing.beats.contains { abs($0 - result.outgoingStart - 0.17) < 1e-8 })
        #expect(result.duration >= 2 && result.duration <= 12)
    }

    @Test func reducesOverlapWhenTemposWouldDrift() {
        let result = plan(profile(), profile(bpm: 123), beats: 16)
        #expect(result.mode == .beatAligned && result.beats == 4)
    }

    @Test func doesNotTreatHalfTempoAsBeatmatched() {
        let result = plan(profile(bpm: 90), profile(bpm: 180))
        #expect(result.mode == .adaptiveFade && result.reason == .incompatibleBeats)
    }

    @Test func preservesConsecutiveAlbumPlaybackWithoutAnalysis() {
        let result = plan(nil, nil, album: true)
        #expect(result.mode == .gapless && result.reason == .continuousAlbum)
        #expect(result.duration == 0 && result.outgoingStart == 120)
    }

    @Test func uncertaintyAndMissingAnalysisHaveSafeFallbacks() {
        #expect(plan(profile(confidence: 0.2), profile()).reason == .uncertainRhythm)
        let result = plan(nil, profile())
        #expect(result.mode == .adaptiveFade && result.reason == .missingAnalysis)
        #expect(result.duration == 2 && result.outgoingStart == 118)
    }

    @Test func rejectsUnsortedNonfiniteOrStaleProfiles() {
        let broken = RhythmProfile(bpm: 120, confidence: 0.9, beats: [0.2, 1.2, 0.7], duration: 120, energy: [])
        let nan = RhythmProfile(bpm: .nan, confidence: 0.9, beats: [], duration: 120, energy: [])
        for bad in [broken, nan, profile(duration: 119)] {
            #expect(plan(bad, profile()).mode == .gapless)
            #expect(plan(bad, profile()).reason == .invalidTiming)
        }
    }

    @Test func sparseAndLateIntroBeatsDoNotCreateLongBeatmatchedOverlap() {
        let sparse = RhythmProfile(bpm: 120, confidence: 0.95, beats: [1, 10, 20], duration: 120, energy: [])
        #expect(plan(sparse, profile()).mode == .adaptiveFade)
        #expect(plan(profile(), profile(phase: 5)).mode == .adaptiveFade)
    }

    @Test func neverPlansInThePastOrTruncatesTheIncomingSong() {
        let result = plan(profile(), profile(), notBefore: 119)
        #expect(result.mode == .gapless)
        #expect(result.reason == .transitionAlreadyPassed)
        let short = TransitionPlanner.plan(outgoing: nil, incoming: nil, outgoingDuration: 10, incomingDuration: 120)
        #expect(short.mode == .gapless && short.reason == .shortTrack)
        let invalid = TransitionPlanner.plan(outgoing: nil, incoming: nil, outgoingDuration: .nan, incomingDuration: 120)
        #expect(invalid.mode == .gapless && invalid.outgoingStart.isFinite)
    }

    @Test(arguments: [4, 8, 16]) func respectsRequestedBeatCount(count: Int) {
        let result = plan(profile(), profile(), beats: count)
        #expect(result.mode == .beatAligned && result.beats == count)
    }

    @Test func irregularObservedBeatsOverrideStrongGlobalBPM() {
        let regular = profile()
        let irregular = RhythmProfile(bpm: 120, confidence: 0.99,
            beats: regular.beats.enumerated().map { $0.element + ($0.offset % 2 == 0 ? 0.08 : 0) },
            duration: 120, energy: [])
        #expect(plan(regular, irregular).mode == .adaptiveFade)
    }
}
