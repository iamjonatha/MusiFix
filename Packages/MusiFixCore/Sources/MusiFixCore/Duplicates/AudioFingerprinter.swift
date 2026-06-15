import Foundation
import AVFoundation
import Accelerate
import OSLog

private let log = Logger(subsystem: "it.musifixapp", category: "AudioFingerprinter")

public enum FingerprintError: Error, LocalizedError {
    case noAudioTrack
    case decodingFailed
    case tooShort

    public var errorDescription: String? {
        switch self {
        case .noAudioTrack:    return "File audio non contiene tracce audio"
        case .decodingFailed:  return "Impossibile decodificare il file audio"
        case .tooShort:        return "File audio troppo corto per il fingerprint"
        }
    }
}

/// Calcola un fingerprint audio Chromaprint-compatibile usando AVFoundation + vDSP.
/// Legge i primi 60 s a 11025 Hz mono; produce un array di UInt32 (~256 elementi).
public actor AudioFingerprinter {

    private static let targetRate: Double = 11025
    private static let frameSize = 4096
    private static let hopSize   = 2048          // 50% overlap
    private static let numBands  = 32
    private static let maxFrames = 512           // ~60 s di audio

    // ── API pubblica ──────────────────────────────────────────────────────────

    /// Calcola il fingerprint per il file all'URL dato.
    public func fingerprint(for url: URL) async throws -> [UInt32] {
        let samples = try await decodePCM(url: url)
        guard samples.count >= AudioFingerprinter.frameSize else { throw FingerprintError.tooShort }
        return computeFingerprint(samples: samples)
    }

    /// Similarità tra due fingerprint: complementare alla distanza di Hamming normalizzata.
    public static func similarity(_ a: [UInt32], _ b: [UInt32]) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        let len = min(a.count, b.count)
        var matchingBits = 0
        for i in 0..<len {
            matchingBits += 32 - Int((a[i] ^ b[i]).nonzeroBitCount)
        }
        return Double(matchingBits) / Double(len * 32)
    }

    // ── Decodifica PCM ────────────────────────────────────────────────────────

    private func decodePCM(url: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: url)

        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let audioTrack = tracks.first else { throw FingerprintError.noAudioTrack }

        let reader = try AVAssetReader(asset: asset)

        // Leggi i primi 60 s
        let duration = try await asset.load(.duration)
        let limit = CMTime(seconds: min(duration.seconds, 60), preferredTimescale: 44100)
        reader.timeRange = CMTimeRange(start: .zero, duration: limit)

        let settings: [String: Any] = [
            AVFormatIDKey:              kAudioFormatLinearPCM,
            AVSampleRateKey:            AudioFingerprinter.targetRate,
            AVNumberOfChannelsKey:      1,
            AVLinearPCMBitDepthKey:     32,
            AVLinearPCMIsFloatKey:      true,
            AVLinearPCMIsBigEndianKey:  false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw FingerprintError.decodingFailed }

        var samples: [Float] = []
        samples.reserveCapacity(Int(AudioFingerprinter.targetRate * 60))

        while let sampleBuffer = output.copyNextSampleBuffer() {
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            let byteCount = CMBlockBufferGetDataLength(blockBuffer)
            let floatCount = byteCount / MemoryLayout<Float>.size
            var chunk = [Float](repeating: 0, count: floatCount)
            _ = chunk.withUnsafeMutableBytes { ptr in
                CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: byteCount,
                                          destination: ptr.baseAddress!)
            }
            samples.append(contentsOf: chunk)
        }

        guard reader.status == .completed || reader.status == .reading else {
            throw FingerprintError.decodingFailed
        }
        return samples
    }

    // ── Fingerprinting ────────────────────────────────────────────────────────

    private func computeFingerprint(samples: [Float]) -> [UInt32] {
        let N = AudioFingerprinter.frameSize
        let hop = AudioFingerprinter.hopSize
        let bands = AudioFingerprinter.numBands
        let maxF = AudioFingerprinter.maxFrames

        let log2n = vDSP_Length(log2(Double(N)))
        guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return [] }
        defer { vDSP_destroy_fftsetup(fftSetup) }

        // Hann window
        var window = [Float](repeating: 0, count: N)
        vDSP_hann_window(&window, vDSP_Length(N), Int32(vDSP_HANN_NORM))

        var allEnergies: [[Float]] = []
        var realBuf = [Float](repeating: 0, count: N / 2)
        var imagBuf = [Float](repeating: 0, count: N / 2)
        var power   = [Float](repeating: 0, count: N / 2)
        var frame   = [Float](repeating: 0, count: N)

        var pos = 0
        while pos + N <= samples.count && allEnergies.count < maxF {
            // Applica finestra Hann
            vDSP_vmul(Array(samples[pos..<pos+N]), 1, window, 1, &frame, 1, vDSP_Length(N))

            // Converti a split-complex e calcola FFT
            frame.withUnsafeMutableBufferPointer { buf in
                buf.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: N / 2) { complexPtr in
                    realBuf.withUnsafeMutableBufferPointer { rp in
                        imagBuf.withUnsafeMutableBufferPointer { ip in
                            var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                            vDSP_ctoz(complexPtr, 2, &split, 1, vDSP_Length(N / 2))
                            vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
                            vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(N / 2))
                        }
                    }
                }
            }

            allEnergies.append(bandEnergies(power: power, numBands: bands))
            pos += hop
        }

        guard allEnergies.count >= 2 else { return [] }

        // Genera bit di fingerprint dalle differenze di energia tra frame adiacenti
        var fingerprint: [UInt32] = []
        fingerprint.reserveCapacity(allEnergies.count - 1)

        for i in 1..<allEnergies.count {
            var bits: UInt32 = 0
            let prev = allEnergies[i - 1]
            let curr = allEnergies[i]
            for j in 0..<min(32, bands - 1) {
                let diff = (curr[j] - curr[j + 1]) - (prev[j] - prev[j + 1])
                if diff > 0 { bits |= (1 << UInt32(j)) }
            }
            fingerprint.append(bits)
        }

        return fingerprint
    }

    /// Energia per banda logaritmica (da ~30 Hz a Nyquist).
    private func bandEnergies(power: [Float], numBands: Int) -> [Float] {
        let rate = AudioFingerprinter.targetRate
        let binSize = rate / Double(power.count * 2)
        let minFreq = 30.0, maxFreq = rate / 2.0

        return (0..<numBands).map { band in
            let lo = minFreq * pow(maxFreq / minFreq, Double(band)     / Double(numBands))
            let hi = minFreq * pow(maxFreq / minFreq, Double(band + 1) / Double(numBands))
            let bLo = max(0,               Int(lo / binSize))
            let bHi = min(power.count - 1, Int(hi / binSize))
            guard bLo <= bHi else { return 0 }
            var sum: Float = 0
            vDSP_sve(power, 1, &sum, vDSP_Length(bHi - bLo + 1))
            return sum
        }
    }
}
