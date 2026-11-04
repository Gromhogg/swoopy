// "Super Advanced" for What you hear (made for metal and heavy rock). The work is done by HeavyChain (C++, in
// Sources/Heavy). It plays through AdvancedPlayer, like Advanced processing: only the sound processing differs.
import Foundation

// What AdvancedPlayer and AdvancedWorker need from the sound processing. One thread uses it at a time, except readAutoEQ.
protocol HearProcessor: AnyObject {
    var latencyFrames: Int { get }
    var fullRange: Bool { get }
    func setHalfSteps(_ value: Float)
    func setTone(bass: Double, treble: Double)
    func setAutoEQ(on: Bool, offsets: [Double])
    func readAutoEQ() -> (auto: [Float], level: [Float])
    func process(_ left: UnsafePointer<Float>, _ right: UnsafePointer<Float>,
                 _ outLeft: UnsafeMutablePointer<Float>, _ outRight: UnsafeMutablePointer<Float>, _ frames: Int)
}

// Bass ↔ Treble and Auto EQ belong to Advanced processing, so Super Advanced has neither. Its delay doesn't depend on
// the amount, so it never needs a player made for a bigger range. `process` makes no memory.
final class HeavyProcessor: HearProcessor {
    private let chain: OpaquePointer
    private var halfSteps: Float
    private let ins = UnsafeMutablePointer<UnsafePointer<Float>?>.allocate(capacity: 2)
    private let outs = UnsafeMutablePointer<UnsafeMutablePointer<Float>?>.allocate(capacity: 2)

    init?(sampleRate: Double, halfSteps: Float, maxFrames: Int = 1024) {
        guard let chain = heavy_new(sampleRate, Int32(maxFrames)) else { return nil }
        self.chain = chain
        self.halfSteps = halfSteps
        heavy_set_semis(chain, Double(halfSteps))
    }

    deinit {
        heavy_delete(chain)
        ins.deallocate()
        outs.deallocate()
    }

    var latencyFrames: Int { Int(heavy_latency_frames(chain)) }
    var fullRange: Bool { true }

    func setHalfSteps(_ value: Float) {
        guard value != halfSteps else { return }
        halfSteps = value
        heavy_set_semis(chain, Double(value))
    }

    func setTone(bass: Double, treble: Double) {}
    func setAutoEQ(on: Bool, offsets: [Double]) {}
    func readAutoEQ() -> (auto: [Float], level: [Float]) { ([], []) }

    func process(_ left: UnsafePointer<Float>, _ right: UnsafePointer<Float>,
                 _ outLeft: UnsafeMutablePointer<Float>, _ outRight: UnsafeMutablePointer<Float>, _ frames: Int) {
        ins[0] = left; ins[1] = right
        outs[0] = outLeft; outs[1] = outRight
        heavy_process(chain, ins, outs, Int32(frames))
    }
}
