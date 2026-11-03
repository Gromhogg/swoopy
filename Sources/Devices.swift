// Small helpers for talking to the Mac's sound system (Core Audio): devices, names, sample rates, and listeners.
import AVFoundation
import CoreAudio

let system = AudioObjectID(kAudioObjectSystemObject)

struct Problem: Error { let message: String }

// All "What you hear" sound handling after the grab happens on this one queue.
let audioQueue = DispatchQueue(label: "swoopy")

func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

func getValue<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, default value: T) -> T {
    var addr = address(selector, scope)
    var result = value
    var size = UInt32(MemoryLayout<T>.size)
    return AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &result) == noErr ? result : value
}

func getArray<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, of: T.Type) -> [T] {
    var addr = address(selector, scope)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
    let count = Int(size) / MemoryLayout<T>.stride
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<T>.alignment)
    defer { raw.deallocate() }
    guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, raw) == noErr else { return [] }
    let typed = raw.bindMemory(to: T.self, capacity: count)
    return Array(UnsafeBufferPointer(start: typed, count: Int(size) / MemoryLayout<T>.stride))
}

func getString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String {
    var addr = address(selector)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr, let value else { return "" }
    return value.takeRetainedValue() as String
}

func allDevices() -> [AudioDeviceID] { getArray(system, kAudioHardwarePropertyDevices, of: AudioDeviceID.self) }
func deviceName(_ id: AudioDeviceID) -> String { getString(id, kAudioObjectPropertyName) }
func deviceUID(_ id: AudioDeviceID) -> String { getString(id, kAudioDevicePropertyDeviceUID) }
// The same for every unit of one model (for Bluetooth headphones it holds the maker's and the model's numbers).
func modelUID(_ id: AudioDeviceID) -> String { getString(id, kAudioDevicePropertyModelUID) }
func defaultOutput() -> AudioDeviceID { getValue(system, kAudioHardwarePropertyDefaultOutputDevice, default: AudioDeviceID(0)) }
func defaultInput() -> AudioDeviceID { getValue(system, kAudioHardwarePropertyDefaultInputDevice, default: AudioDeviceID(0)) }
func nominalRate(_ id: AudioDeviceID) -> Double { getValue(id, kAudioDevicePropertyNominalSampleRate, default: Float64(0)) }
func transportType(_ id: AudioDeviceID) -> UInt32 { getValue(id, kAudioDevicePropertyTransportType, default: UInt32(0)) }
func isRunningSomewhere(_ id: AudioDeviceID) -> Bool { getValue(id, kAudioDevicePropertyDeviceIsRunningSomewhere, default: UInt32(0)) != 0 }
func streamCount(_ id: AudioDeviceID, _ scope: AudioObjectPropertyScope) -> Int { getArray(id, kAudioDevicePropertyStreams, scope, of: AudioStreamID.self).count }

func setNominalRate(_ id: AudioDeviceID, _ rate: Double) -> Bool {
    var addr = address(kAudioDevicePropertyNominalSampleRate)
    var value = rate
    return AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<Float64>.size), &value) == noErr
}

func setDefaultInput(_ id: AudioDeviceID) {
    var addr = address(kAudioHardwarePropertyDefaultInputDevice)
    var id = id
    AudioObjectSetPropertyData(system, &addr, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &id)
}

func setDefaultOutput(_ id: AudioDeviceID) {
    var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
    var id = id
    AudioObjectSetPropertyData(system, &addr, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &id)
}

// Finds a device by its UID, including hidden ones (like the hidden side of Swoopy Mic).
func device(uid: String) -> AudioDeviceID? {
    var addr = address(kAudioHardwarePropertyTranslateUIDToDevice)
    var uid = uid as CFString
    var id = AudioDeviceID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    let err = AudioObjectGetPropertyData(system, &addr, UInt32(MemoryLayout<CFString>.size), &uid, &size, &id)
    return err == noErr && id != kAudioObjectUnknown ? id : nil
}

func useDevice(_ unit: AudioUnit, _ id: AudioDeviceID) -> Bool {
    var id = id
    return AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr
}

// The Core Audio id for a running app's sound, or nil if the app hasn't used sound yet.
func audioProcess(for pid: pid_t) -> AudioObjectID? {
    var addr = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
    var pid = pid
    var id = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    let err = AudioObjectGetPropertyData(system, &addr, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &id)
    return err == noErr && id != kAudioObjectUnknown ? id : nil
}

// Runs `handler` on the main queue whenever a Core Audio setting changes. Stops when cancelled or released.
final class Listener {
    private let object: AudioObjectID
    private var addr: AudioObjectPropertyAddress
    private var block: AudioObjectPropertyListenerBlock?

    init(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, _ handler: @escaping () -> Void) {
        self.object = object
        addr = address(selector, scope)
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        if AudioObjectAddPropertyListenerBlock(object, &addr, .main, block) == noErr { self.block = block }
    }

    func cancel() {
        guard let block else { return }
        AudioObjectRemovePropertyListenerBlock(object, &addr, .main, block)
        self.block = nil
    }

    deinit { cancel() }
}

// Calls `action` once, a moment after the last of several quick calls (devices often send changes in bursts).
final class Debouncer {
    private var work: DispatchWorkItem?
    private let delay: Double
    init(_ delay: Double = 0.3) { self.delay = delay }
    func call(_ action: @escaping () -> Void) {
        work?.cancel()
        let item = DispatchWorkItem(block: action)
        work = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }
}
