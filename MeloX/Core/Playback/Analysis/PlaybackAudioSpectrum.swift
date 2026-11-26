import AVFoundation
import Foundation
import Synchronization

nonisolated struct PlaybackAudioSpectrumSnapshot:
    Equatable,
    Sendable
{
    static let zero = PlaybackAudioSpectrumSnapshot(
        low: 0,
        mid: 0,
        high: 0,
        overall: 0
    )

    let low: Float
    let mid: Float
    let high: Float
    let overall: Float
}

nonisolated final class SharedPlaybackAudioSpectrum: Sendable {
    private let revision = Atomic<UInt64>(0)
    private let lowAndMid = Atomic<UInt64>(0)
    private let highAndOverall = Atomic<UInt64>(0)

    // Five 8-bit levels fit in a single atomic word. The audio callback never
    // waits for a visible row, and reading the meter does not update any views.
    private let rowLevels = Atomic<UInt64>(0)
    private let rowUpdateTime = Atomic<UInt64>(0)

    func publishRowLevels(_ levels: SIMD8<Float>) {
        var packed: UInt64 = 0
        for band in 0..<5 {
            packed |= UInt64((min(1, max(0, levels[band])) * 255).rounded()) << (band * 8)
        }
        rowLevels.store(packed, ordering: .relaxed)
        rowUpdateTime.store(DispatchTime.now().uptimeNanoseconds, ordering: .releasing)
    }

    func currentRowLevels() -> SIMD8<Float>? {
        let timestamp = rowUpdateTime.load(ordering: .acquiring)
        guard timestamp != 0, DispatchTime.now().uptimeNanoseconds - timestamp < 500_000_000 else { return nil }
        let packed = rowLevels.load(ordering: .relaxed)
        var levels = SIMD8<Float>.zero
        for band in 0..<5 {
            levels[band] = Float((packed >> (band * 8)) & 0xff) / 255
        }
        return levels
    }

    func publish(_ snapshot: PlaybackAudioSpectrumSnapshot) {
        revision.wrappingAdd(
            1,
            ordering: .acquiringAndReleasing
        )
        lowAndMid.store(
            Self.pack(snapshot.low, snapshot.mid),
            ordering: .relaxed
        )
        highAndOverall.store(
            Self.pack(snapshot.high, snapshot.overall),
            ordering: .relaxed
        )
        revision.wrappingAdd(1, ordering: .releasing)
    }

    func snapshot() -> PlaybackAudioSpectrumSnapshot {
        while true {
            let startingRevision = revision.load(ordering: .acquiring)
            guard startingRevision.isMultiple(of: 2) else { continue }

            let packedLowAndMid = lowAndMid.load(ordering: .relaxed)
            let packedHighAndOverall = highAndOverall.load(
                ordering: .relaxed
            )
            let endingRevision = revision.load(ordering: .acquiring)
            guard startingRevision == endingRevision else { continue }

            let lowAndMid = Self.unpack(packedLowAndMid)
            let highAndOverall = Self.unpack(packedHighAndOverall)
            return PlaybackAudioSpectrumSnapshot(
                low: lowAndMid.first,
                mid: lowAndMid.second,
                high: highAndOverall.first,
                overall: highAndOverall.second
            )
        }
    }

    private static func pack(_ first: Float, _ second: Float) -> UInt64 {
        UInt64(first.bitPattern)
            | UInt64(second.bitPattern) << 32
    }

    private static func unpack(
        _ packedValue: UInt64
    ) -> (first: Float, second: Float) {
        (
            Float(bitPattern: UInt32(truncatingIfNeeded: packedValue)),
            Float(bitPattern: UInt32(truncatingIfNeeded: packedValue >> 32))
        )
    }
}

/// The backdrop and the compact five-band meter share one pass over the decoded PCM.
nonisolated final class PlaybackAudioSpectrumAnalyzer {
    private static let delayCount = 10
    private static let historyCount = 4
    private static let historyWeights = SIMD4<Float>(0.1, 0.2, 0.3, 0.4)

    private let sharedSpectrum: SharedPlaybackAudioSpectrum
    private var sampleRate = 0.0
    private var channelCount = 0
    private var coefficients = SIMD4<Float>.zero
    private var filterStates: [SIMD4<Float>] = []
    private var rowLevels = SIMD8<Float>.zero

    private struct BandEnergy {
        var backdrop = SIMD3<Double>.zero
        var lowerFour = SIMD4<Double>.zero
    }

    private var delayedBands = Array(
        repeating: SIMD3<Float>(repeating: 0),
        count: delayCount
    )
    private var recentBands = Array(
        repeating: SIMD3<Float>(repeating: 0),
        count: historyCount
    )
    private var delayIndex = 0
    private var recentIndex = 0
    private var target = SIMD3<Float>(repeating: 0)
    private var current = SIMD3<Float>(repeating: 0)

    init(sharedSpectrum: SharedPlaybackAudioSpectrum) {
        self.sharedSpectrum = sharedSpectrum
    }

    func prepare(sampleRate: Double, channelCount: Int) {
        self.sampleRate = sampleRate
        self.channelCount = max(channelCount, 1)
        coefficients = SIMD4(
            Self.lowPassCoefficient(cutoff: 100, sampleRate: sampleRate),
            Self.lowPassCoefficient(cutoff: 300, sampleRate: sampleRate),
            Self.lowPassCoefficient(cutoff: 1_100, sampleRate: sampleRate),
            Self.lowPassCoefficient(cutoff: 3_500, sampleRate: sampleRate)
        )
        filterStates = Array(repeating: .zero, count: self.channelCount)
        reset()
    }

    func reset() {
        for index in filterStates.indices { filterStates[index] = .zero }
        rowLevels = .zero
        for index in delayedBands.indices {
            delayedBands[index] = .zero
        }
        for index in recentBands.indices {
            recentBands[index] = .zero
        }
        delayIndex = 0
        recentIndex = 0
        target = .zero
        current = .zero
        sharedSpectrum.publish(.zero)
    }

    func process(buffer: AVAudioPCMBuffer) {
        if sampleRate != buffer.format.sampleRate || channelCount != Int(buffer.format.channelCount) {
            prepare(sampleRate: buffer.format.sampleRate, channelCount: Int(buffer.format.channelCount))
        }
        process(bufferList: buffer.mutableAudioBufferList, frameCount: Int(buffer.frameLength))
    }

    func process(
        bufferList: UnsafeMutablePointer<AudioBufferList>,
        frameCount: Int
    ) {
        guard sampleRate > 0,
              frameCount > 0,
              !filterStates.isEmpty else {
            return
        }

        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        var energy = BandEnergy()
        var analyzedSampleCount = 0
        var channelBase = 0

        for buffer in buffers {
            guard let data = buffer.mData else {
                channelBase += Int(buffer.mNumberChannels)
                continue
            }

            let channelsInBuffer = max(Int(buffer.mNumberChannels), 1)
            let availableSampleCount = Int(buffer.mDataByteSize)
                / MemoryLayout<Float>.stride
            let requestedSampleCount = frameCount * channelsInBuffer
            let sampleCount = min(availableSampleCount, requestedSampleCount)
            let samples = data.assumingMemoryBound(to: Float.self)

            if channelsInBuffer == 1 {
                analyzeNoninterleaved(
                    samples: samples,
                    sampleCount: sampleCount,
                    channel: channelBase,
                    energy: &energy,
                    analyzedSampleCount: &analyzedSampleCount
                )
            } else {
                analyzeInterleaved(
                    samples: samples,
                    sampleCount: sampleCount,
                    channelsInBuffer: channelsInBuffer,
                    channelBase: channelBase,
                    energy: &energy,
                    analyzedSampleCount: &analyzedSampleCount
                )
            }
            channelBase += channelsInBuffer
        }

        guard analyzedSampleCount > 0 else { return }
        let divisor = Double(analyzedSampleCount)
        let duration = Double(frameCount) / sampleRate
        updateRowLevels(energy: energy, samples: divisor, duration: duration)
        let rawBands = SIMD3<Float>(
            Self.normalizedPower(sqrt(energy.backdrop.x / divisor)),
            Self.normalizedPower(sqrt(energy.backdrop.y / divisor)),
            Self.normalizedPower(sqrt(energy.backdrop.z / divisor))
        )
        updateEnvelope(
            with: Self.smootherstep(rawBands),
            duration: duration
        )
    }

    private func analyzeNoninterleaved(
        samples: UnsafeMutablePointer<Float>,
        sampleCount: Int,
        channel: Int,
        energy: inout BandEnergy,
        analyzedSampleCount: inout Int
    ) {
        guard channel < channelCount else { return }
        for index in 0..<sampleCount {
            accumulate(
                sample: samples[index],
                channel: channel,
                energy: &energy
            )
        }
        analyzedSampleCount += sampleCount
    }

    private func analyzeInterleaved(
        samples: UnsafeMutablePointer<Float>,
        sampleCount: Int,
        channelsInBuffer: Int,
        channelBase: Int,
        energy: inout BandEnergy,
        analyzedSampleCount: inout Int
    ) {
        let frameCount = sampleCount / channelsInBuffer
        for frameIndex in 0..<frameCount {
            for localChannel in 0..<channelsInBuffer {
                let channel = channelBase + localChannel
                guard channel < channelCount else { continue }
                accumulate(
                    sample: samples[
                        frameIndex * channelsInBuffer + localChannel
                    ],
                    channel: channel,
                    energy: &energy
                )
                analyzedSampleCount += 1
            }
        }
    }

    private func accumulate(
        sample: Float,
        channel: Int,
        energy: inout BandEnergy
    ) {
        let finiteSample = sample.isFinite ? sample : 0
        var state = filterStates[channel]
        state += coefficients * (SIMD4(repeating: finiteSample) - state)
        filterStates[channel] = state

        let mid = state.w - state.y
        let high = finiteSample - state.w
        energy.backdrop += SIMD3(Double(state.y * state.y), Double(mid * mid), Double(high * high))

        // Adjacent low-pass differences split the same samples into five bands.
        // The fifth band already has its energy in backdrop.z.
        let bands = SIMD4(state.x, state.y - state.x, state.z - state.y, state.w - state.z)
        energy.lowerFour += SIMD4<Double>(bands * bands)
    }

    private func updateRowLevels(energy: BandEnergy, samples: Double, duration: TimeInterval) {
        let attack = Float(-expm1(-duration / 0.025))
        let release = Float(-expm1(-duration / 0.13))
        for band in 0..<5 {
            let sum = band == 4 ? energy.backdrop.z : energy.lowerFour[band]
            let rms = sqrt(sum / samples)
            let level = Self.normalizedPower(rms)
            let target = level * level
            rowLevels[band] += (target - rowLevels[band]) * (target > rowLevels[band] ? attack : release)
        }
        sharedSpectrum.publishRowLevels(rowLevels)
    }

    private func updateEnvelope(
        with bands: SIMD3<Float>,
        duration: TimeInterval
    ) {
        let delayed = delayedBands[delayIndex]
        delayedBands[delayIndex] = bands
        delayIndex = (delayIndex + 1) % Self.delayCount

        recentBands[recentIndex] = delayed
        recentIndex = (recentIndex + 1) % Self.historyCount

        var weighted = SIMD3<Float>(repeating: 0)
        for offset in 0..<Self.historyCount {
            let index = (recentIndex + offset) % Self.historyCount
            weighted += recentBands[index]
                * Self.historyWeights[offset]
        }

        let equivalentFrames = Float(max(duration, 0) * 120)
        target.x *= pow(49.0 / 50.0, equivalentFrames)
        target.y *= pow(99.0 / 100.0, equivalentFrames)
        target.z *= pow(999.0 / 1_000.0, equivalentFrames)
        target = max(target, weighted)

        let retention = pow(0.5, equivalentFrames)
        current = target + (current - target) * retention
        let overall = max(current.x, max(current.y, current.z))
        sharedSpectrum.publish(
            PlaybackAudioSpectrumSnapshot(
                low: current.x,
                mid: current.y,
                high: current.z,
                overall: overall
            )
        )
    }

    private static func lowPassCoefficient(
        cutoff: Double,
        sampleRate: Double
    ) -> Float {
        guard sampleRate > 0 else { return 0 }
        let limitedCutoff = min(cutoff, sampleRate * 0.45)
        return Float(1 - exp(-2 * Double.pi * limitedCutoff / sampleRate))
    }

    private static func normalizedPower(_ rootMeanSquare: Double) -> Float {
        guard rootMeanSquare.isFinite, rootMeanSquare > 0 else { return 0 }
        let decibels = 20 * log10(rootMeanSquare)
        return Float(min(max((decibels + 55) / 47, 0), 1))
    }

    private static func smootherstep(_ value: SIMD3<Float>) -> SIMD3<Float> {
        value * value * value * (value * (value * 6 - 15) + 10)
    }
}
