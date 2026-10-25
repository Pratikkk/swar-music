import Foundation
import Decoding

public struct TransitionPlan: Sendable, Equatable {
    public enum Mode: String, Sendable { case beatAligned, adaptiveFade, gapless }
    public enum Reason: String, Sendable {
        case matchedBeats, continuousAlbum, missingAnalysis, uncertainRhythm, incompatibleBeats
        case invalidTiming, shortTrack, transitionAlreadyPassed
    }
    public let mode: Mode
    public let reason: Reason
    /// Positions in each source file, in seconds. Incoming intros are never skipped.
    public let outgoingStart: Double
    public let incomingStart: Double
    public let duration: Double
    public let beats: Int
}

/// Analysis-only policy: no audio/device state, tempo changes, or queue mutations.
public enum TransitionPlanner {
    public static func plan(outgoing: RhythmProfile?, incoming: RhythmProfile?,
                            outgoingDuration: Double, incomingDuration: Double,
                            notBefore: Double = 0, preferredBeats: Int = 8,
                            preserveGapless: Bool = false) -> TransitionPlan {
        func gapless(_ reason: TransitionPlan.Reason) -> TransitionPlan {
            TransitionPlan(mode: .gapless, reason: reason,
                outgoingStart: outgoingDuration.isFinite ? max(0, outgoingDuration) : 0,
                incomingStart: 0, duration: 0, beats: 0)
        }
        guard outgoingDuration.isFinite, incomingDuration.isFinite, notBefore.isFinite,
              outgoingDuration > 0, incomingDuration > 0, notBefore >= 0 else { return gapless(.invalidTiming) }
        if preserveGapless { return gapless(.continuousAlbum) }
        guard min(outgoingDuration, incomingDuration) >= 12 else { return gapless(.shortTrack) }
        guard notBefore < outgoingDuration else { return gapless(.transitionAlreadyPassed) }

        func fallback(_ reason: TransitionPlan.Reason) -> TransitionPlan {
            // A short overlap scaled to track length, never an emergency late fade.
            let length = max(0.5, min(2, min(outgoingDuration, incomingDuration) * 0.025))
            let start = outgoingDuration - length
            guard start >= notBefore, length >= 0.5 else { return gapless(.transitionAlreadyPassed) }
            return TransitionPlan(mode: .adaptiveFade, reason: reason, outgoingStart: start,
                                  incomingStart: 0, duration: length, beats: 0)
        }
        guard let outgoing, let incoming else { return fallback(.missingAnalysis) }
        guard valid(outgoing, duration: outgoingDuration), valid(incoming, duration: incomingDuration) else {
            return gapless(.invalidTiming)
        }
        guard let outBPM = outgoing.bpm, let inBPM = incoming.bpm,
              outgoing.confidence >= 0.6, incoming.confidence >= 0.6 else { return fallback(.uncertainRhythm) }
        // Neither half/double tempo assumptions nor time stretching are allowed here.
        guard abs(outBPM - inBPM) / max(outBPM, inBPM) <= 0.04 else { return fallback(.incompatibleBeats) }
        guard let first = incoming.beats.first, first <= 2 else { return fallback(.incompatibleBeats) }
        let requested = [4, 8, 16].contains(preferredBeats) ? preferredBeats : 8
        for count in [16, 8, 4] where count <= requested {
            guard incoming.beats.count > count, outgoing.beats.count > count else { continue }
            let nextBeats = Array(incoming.beats.prefix(count + 1))
            guard steady(nextBeats, period: 60 / inBPM) else { continue }
            var candidates: [(Double, Double)] = []
            for index in 0..<(outgoing.beats.count - count) {
                let beat = outgoing.beats[index]
                // Start the next file from zero so its first beat meets this outgoing beat.
                let start = beat - first
                let length = outgoingDuration - start
                guard start >= notBefore, (2...12).contains(length), length <= incomingDuration,
                      abs(outgoingDuration - outgoing.beats[index + count]) <= 0.75 else { continue }
                let tail = Array(outgoing.beats[index...(index + count)])
                guard steady(tail, period: 60 / outBPM) else { continue }
                let drift = (0...count).map { abs((tail[$0] - tail[0]) - (nextBeats[$0] - first)) }.max() ?? .infinity
                guard drift <= 0.07 else { continue }
                // Energy is only a preference among timing-safe candidates, not a vocal detector.
                let energy = meanEnergy(outgoing, from: start, to: outgoingDuration)
                    + meanEnergy(incoming, from: 0, to: length)
                let score = abs(length - Double(count) * 60 / outBPM) + energy * 0.2 + drift
                candidates.append((start, score))
            }
            if let best = candidates.min(by: { $0.1 < $1.1 }) {
                return TransitionPlan(mode: .beatAligned, reason: .matchedBeats, outgoingStart: best.0,
                                      incomingStart: 0, duration: outgoingDuration - best.0, beats: count)
            }
        }
        return fallback(.incompatibleBeats)
    }

    private static func valid(_ profile: RhythmProfile, duration: Double) -> Bool {
        guard profile.duration.isFinite, profile.duration > 0, profile.duration <= 900,
              abs(profile.duration - duration) <= 0.25,
              profile.confidence.isFinite, (0...1).contains(profile.confidence),
              profile.bpm.map({ $0.isFinite && (60...180).contains($0) }) ?? true,
              profile.beats.count <= 3000, profile.energy.count <= 1800,
              profile.beats.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= duration }),
              profile.energy.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { return false }
        return zip(profile.beats, profile.beats.dropFirst()).allSatisfy { $0 < $1 }
    }

    private static func steady(_ beats: [Double], period: Double) -> Bool {
        zip(beats, beats.dropFirst()).allSatisfy { abs(($1 - $0) - period) <= max(0.025, period * 0.08) }
    }

    private static func meanEnergy(_ profile: RhythmProfile, from: Double, to: Double) -> Double {
        guard profile.energy.count >= Int(ceil(profile.duration * 2)) else { return 0 }
        let low = max(0, Int(from * 2)), high = min(profile.energy.count, Int(ceil(to * 2)))
        guard high > low else { return 0 }
        return profile.energy[low..<high].reduce(0) { $0 + Double($1) } / Double(high - low)
    }
}
