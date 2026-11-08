import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif

/// Stereo audio at the beat's sample rate.
public struct StereoAudio: Sendable {
    public var left: [Float]
    public var right: [Float]

    public init(left: [Float], right: [Float]) {
        self.left = left
        self.right = right
    }

    public var frames: Int { left.count }
}

public enum BeatAudio {
    public static let sampleRate = 44_100.0
    /// Longest part of any sample that's used. Long files are cut here.
    static let maxSampleSeconds = 6.0

    // MARK: Reading samples

    /// Decodes WAV, AIFF or FLAC to stereo floats at 44.1 kHz.
    public static func decode(_ url: URL) throws -> StereoAudio {
        #if canImport(AVFoundation)
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let wanted = min(file.length, AVAudioFramePosition(format.sampleRate * maxSampleSeconds))
        guard wanted > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(wanted)) else {
            throw PrismError.local("The sample is empty: \(url.lastPathComponent)")
        }
        try file.read(into: buffer, frameCount: AVAudioFrameCount(wanted))
        guard let channels = buffer.floatChannelData else {
            throw PrismError.local("The sample couldn't be read: \(url.lastPathComponent)")
        }
        let n = Int(buffer.frameLength)
        let left = Array(UnsafeBufferPointer(start: channels[0], count: n))
        let right = format.channelCount > 1 ? Array(UnsafeBufferPointer(start: channels[1], count: n)) : left
        let audio = StereoAudio(left: left, right: right)
        return format.sampleRate == sampleRate ? audio : resample(audio, from: format.sampleRate)
        #else
        throw PrismError.local("Audio decoding needs macOS.")
        #endif
    }

    static func resample(_ a: StereoAudio, from rate: Double) -> StereoAudio {
        let ratio = rate / sampleRate
        let count = Int(Double(a.frames) / ratio)
        func run(_ x: [Float]) -> [Float] {
            var out = [Float](repeating: 0, count: count)
            for i in 0..<count {
                let pos = Double(i) * ratio
                let j = Int(pos)
                let f = Float(pos - Double(j))
                let a0 = x[min(j, x.count - 1)], a1 = x[min(j + 1, x.count - 1)]
                out[i] = a0 + (a1 - a0) * f
            }
            return out
        }
        return StereoAudio(left: run(a.left), right: run(a.right))
    }

    // MARK: Writing

    /// 16-bit stereo PCM WAV.
    public static func wav(_ audio: StereoAudio) -> Data {
        let frames = audio.frames
        let dataBytes = frames * 4
        var d = Data(capacity: 44 + dataBytes)
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + dataBytes))
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(2)
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate) * 4); u16(4); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(UInt32(dataBytes))
        var pcm = [Int16](repeating: 0, count: frames * 2)
        for i in 0..<frames {
            pcm[i * 2] = Int16(max(-1, min(1, audio.left[i])) * 32767)
            pcm[i * 2 + 1] = Int16(max(-1, min(1, audio.right[i])) * 32767)
        }
        // Apple silicon and Intel Macs are little-endian, which is what WAV stores.
        pcm.withUnsafeBytes { d.append(contentsOf: $0) }
        return d
    }

    /// Loudness outline of a WAV this app wrote, for drawing a waveform. Values are 0...1.
    public static func peaks(ofWAV data: Data, count: Int) -> [Float] {
        guard data.count > 44, count > 0 else { return [] }
        let samples = (data.count - 44) / 2
        let framesTotal = samples / 2
        guard framesTotal > 0 else { return [] }
        let per = max(1, framesTotal / count)
        var out: [Float] = []
        out.reserveCapacity(count)
        data.withUnsafeBytes { raw in
            let base = raw.baseAddress!.advanced(by: 44)
            for b in 0..<count {
                var peak: Float = 0
                let start = b * per
                if start >= framesTotal { break }
                let end = min(framesTotal, start + per)
                var f = start
                while f < end {
                    let v = base.advanced(by: f * 4).loadUnaligned(as: Int16.self)
                    peak = max(peak, abs(Float(Int16(littleEndian: v))) / 32767)
                    f += max(1, (end - start) / 64)
                }
                out.append(peak)
            }
        }
        return out
    }
}

/// Decoded samples kept in memory, so moving a dial doesn't reread files from the drive.
final class SampleCache: @unchecked Sendable {
    static let shared = SampleCache()
    private let lock = NSLock()
    private var store: [String: StereoAudio] = [:]
    private var order: [String] = []
    private let limit = 160

    func audio(for path: String) throws -> StereoAudio {
        lock.lock()
        if let hit = store[path] { lock.unlock(); return hit }
        lock.unlock()
        let decoded = try BeatAudio.decode(URL(fileURLWithPath: path))
        lock.lock()
        store[path] = decoded
        order.append(path)
        if order.count > limit {
            let old = order.removeFirst()
            store[old] = nil
        }
        lock.unlock()
        return decoded
    }
}

/// Mixes a beat plan with the chosen samples into one stereo track.
public enum BeatMixer {
    struct Voice {
        var gain: Float
        var pan: Float
    }

    static let voices: [SampleRole: Voice] = [
        .kick: Voice(gain: 1.0, pan: 0), .snare: Voice(gain: 0.85, pan: 0.04), .clap: Voice(gain: 0.75, pan: -0.04),
        .closedHat: Voice(gain: 0.42, pan: 0.18), .openHat: Voice(gain: 0.4, pan: -0.18), .perc: Voice(gain: 0.45, pan: -0.3),
        .tom: Voice(gain: 0.7, pan: 0.25), .cymbal: Voice(gain: 0.45, pan: 0.1), .bass: Voice(gain: 0.8, pan: 0)
    ]

    /// `sounds` maps each role to decoded audio; a missing bass is played by a simple sine sub.
    public static func mix(_ plan: BeatPlan, sounds: [SampleRole: StereoAudio], tone: Double) -> StereoAudio {
        let sr = BeatAudio.sampleRate
        let stepFrames = plan.secondsPerStep * sr
        let total = Int(Double(plan.steps) * stepFrames + sr * 1.5)
        var left = [Float](repeating: 0, count: total)
        var right = [Float](repeating: 0, count: total)

        // An open hat stops when the next closed hat plays, like on a real kit.
        let closedTimes = plan.events.filter { $0.role == .closedHat }.map(\.time)

        for e in plan.events {
            let voice = voices[e.role] ?? Voice(gain: 0.5, pan: 0)
            let start = Int(e.time * stepFrames)
            guard start < total else { continue }
            let g = voice.gain * Float(e.velocity)
            let lg = g * min(1, 1 - voice.pan), rg = g * min(1, 1 + voice.pan)

            if e.role == .bass, sounds[.bass] == nil {
                synthSub(into: &left, &right, start: start, frames: Int(e.length * stepFrames),
                         semitones: e.semitones, gain: g)
                continue
            }
            guard let s = sounds[e.role] ?? e.role.fallbacks.lazy.compactMap({ sounds[$0] }).first else { continue }

            var maxFrames = s.frames
            if e.role == .openHat, let next = closedTimes.first(where: { $0 > e.time + 0.01 }) {
                maxFrames = min(maxFrames, Int((next - e.time) * stepFrames))
            }
            let ratio = e.role == .bass ? pow(2, e.semitones / 12) : 1
            var length = Int(Double(maxFrames) / ratio)
            if e.role == .bass { length = min(length, Int(e.length * stepFrames)) }
            length = min(length, total - start)
            guard length > 0 else { continue }
            let fade = min(length, Int(sr * 0.006))
            for i in 0..<length {
                let pos = Double(i) * ratio
                let j = Int(pos)
                guard j < s.frames else { break }
                let f = Float(pos - Double(j))
                let k = min(j + 1, s.frames - 1)
                var l = s.left[j] + (s.left[k] - s.left[j]) * f
                var r = s.right[j] + (s.right[k] - s.right[j]) * f
                if i >= length - fade {
                    let env = Float(length - i) / Float(fade)
                    l *= env
                    r *= env
                }
                left[start + i] += l * lg
                right[start + i] += r * rg
            }
        }

        // Tone: a gentle low-pass that opens fully at the bright end.
        if tone < 0.95 {
            let cutoff = 900 * pow(18_000 / 900, tone)
            let a = Float(exp(-2 * Double.pi * cutoff / sr))
            var yl: Float = 0, yr: Float = 0
            for i in 0..<total {
                yl = (1 - a) * left[i] + a * yl
                yr = (1 - a) * right[i] + a * yr
                left[i] = yl
                right[i] = yr
            }
        }

        // Even loudness: peaks land just under full scale.
        var peak: Float = 0
        for i in 0..<total { peak = max(peak, abs(left[i]), abs(right[i])) }
        if peak > 0.0001 {
            let scale = 0.89 / peak
            for i in 0..<total {
                left[i] *= scale
                right[i] *= scale
            }
        }
        return StereoAudio(left: left, right: right)
    }

    /// A plain 808-style sub: sine with a quick pitch drop and a smooth decay. Pitch is around A1.
    static func synthSub(into left: inout [Float], _ right: inout [Float], start: Int, frames: Int,
                         semitones: Double, gain: Float) {
        let sr = BeatAudio.sampleRate
        let freq = 55 * pow(2, semitones / 12)
        let n = min(frames + Int(sr * 0.05), left.count - start)
        guard n > 0 else { return }
        var phase = 0.0
        for i in 0..<n {
            let t = Double(i) / sr
            let f = freq * (1 + 1.5 * exp(-t * 60))
            phase += 2 * Double.pi * f / sr
            let env = exp(-t * 2.2) * (i > frames ? Double(n - i) / Double(max(1, n - frames)) : 1)
            let attack = min(1, Double(i) / (sr * 0.003))
            let v = Float(tanh(sin(phase) * 1.4) * env * attack) * gain * 0.9
            left[start + i] += v
            right[start + i] += v
        }
    }
}

/// Standard MIDI file of the beat (General MIDI drums on channel 10, bass on channel 2).
public enum BeatMIDI {
    static let ppq = 480
    static let drumNotes: [SampleRole: UInt8] = [.kick: 36, .snare: 38, .clap: 39, .closedHat: 42, .openHat: 46,
                                                 .perc: 56, .tom: 45, .cymbal: 49]

    struct Note {
        var tick: Int
        var on: Bool
        var channel: UInt8
        var note: UInt8
        var vel: UInt8
    }

    public static func file(_ plan: BeatPlan) -> Data {
        let ticksPerStep = Double(ppq) / 4
        func track(_ notes: [Note], name: String, tempo: Bool) -> Data {
            var body = Data()
            func vlq(_ value: Int) {
                var v = max(0, value)
                var bytes: [UInt8] = [UInt8(v & 0x7F)]
                v >>= 7
                while v > 0 {
                    bytes.insert(UInt8((v & 0x7F) | 0x80), at: 0)
                    v >>= 7
                }
                body.append(contentsOf: bytes)
            }
            vlq(0)
            let nameBytes = Array(name.utf8.prefix(100))
            body.append(contentsOf: [0xFF, 0x03, UInt8(nameBytes.count)] + nameBytes)
            if tempo {
                let usPerQuarter = Int(60_000_000 / plan.bpm)
                vlq(0)
                body.append(contentsOf: [0xFF, 0x51, 0x03, UInt8((usPerQuarter >> 16) & 0xFF),
                                         UInt8((usPerQuarter >> 8) & 0xFF), UInt8(usPerQuarter & 0xFF)])
                vlq(0)
                body.append(contentsOf: [0xFF, 0x58, 0x04, 4, 2, 24, 8])
            }
            var last = 0
            for n in notes.sorted(by: { $0.tick == $1.tick ? (!$0.on && $1.on) : $0.tick < $1.tick }) {
                vlq(n.tick - last)
                last = n.tick
                body.append(contentsOf: [(n.on ? 0x90 : 0x80) | n.channel, n.note, n.vel])
            }
            vlq(0)
            body.append(contentsOf: [0xFF, 0x2F, 0x00])
            var chunk = Data(Array("MTrk".utf8))
            var len = UInt32(body.count).bigEndian
            withUnsafeBytes(of: &len) { chunk.append(contentsOf: $0) }
            chunk.append(body)
            return chunk
        }

        var drums: [Note] = []
        var bass: [Note] = []
        for e in plan.events {
            let tick = Int(e.time * ticksPerStep)
            let vel = UInt8(max(1, min(127, Int(e.velocity * 127))))
            if e.role == .bass {
                let note = UInt8(max(0, min(127, 36 + Int(e.semitones))))
                bass.append(Note(tick: tick, on: true, channel: 1, note: note, vel: vel))
                bass.append(Note(tick: tick + max(1, Int(e.length * ticksPerStep) - 10), on: false, channel: 1, note: note, vel: 0))
            } else if let note = drumNotes[e.role] {
                drums.append(Note(tick: tick, on: true, channel: 9, note: note, vel: vel))
                drums.append(Note(tick: tick + Int(ticksPerStep / 2), on: false, channel: 9, note: note, vel: 0))
            }
        }
        var d = Data(Array("MThd".utf8))
        d.append(contentsOf: [0, 0, 0, 6, 0, 1, 0, 2, UInt8(ppq >> 8), UInt8(ppq & 0xFF)])
        d.append(track(drums, name: "Drums", tempo: true))
        d.append(track(bass, name: "Bass", tempo: false))
        return d
    }
}
