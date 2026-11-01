import CoreAudio
import Foundation

/// An audio device that has inputs.
public struct AudioInputDevice: Identifiable, Hashable, Sendable {
    public var id: String { uid }
    public let deviceID: AudioDeviceID
    public let uid: String
    public let name: String
    public let inputChannels: Int
    public let nominalSampleRate: Double
}

/// Reads the list of input devices from Core Audio and reports changes.
public enum AudioDevices {
    public static func inputDevices() -> [AudioInputDevice] {
        allDeviceIDs().compactMap { id in
            let channels = inputChannelCount(id)
            guard channels > 0, let uid = deviceUID(id) else { return nil }
            return AudioInputDevice(deviceID: id, uid: uid, name: deviceName(id) ?? uid,
                                    inputChannels: channels, nominalSampleRate: nominalSampleRate(id) ?? 0)
        }
    }

    public static func defaultInputDeviceID() -> AudioDeviceID? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = address(kAudioHardwarePropertyDefaultInputDevice)
        let err = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return err == noErr && id != 0 ? id : nil
    }

    public static func device(uid: String) -> AudioInputDevice? {
        inputDevices().first { $0.uid == uid }
    }

    public static func device(id: AudioDeviceID) -> AudioInputDevice? {
        inputDevices().first { $0.deviceID == id }
    }

    public static func nominalSampleRate(_ id: AudioDeviceID) -> Double? {
        var rate = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        var addr = address(kAudioDevicePropertyNominalSampleRate)
        return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &rate) == noErr ? rate : nil
    }

    public static func bufferFrameSize(_ id: AudioDeviceID) -> Int? {
        var frames = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = address(kAudioDevicePropertyBufferFrameSize)
        return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &frames) == noErr ? Int(frames) : nil
    }

    public static func isAlive(_ id: AudioDeviceID) -> Bool {
        var alive = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = address(kAudioDevicePropertyDeviceIsAlive)
        return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &alive) == noErr && alive != 0
    }

    // MARK: Helpers

    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size = UInt32(0)
        let sys = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(sys, &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(sys, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func deviceUID(_ id: AudioDeviceID) -> String? { stringProperty(id, kAudioDevicePropertyDeviceUID) }
    private static func deviceName(_ id: AudioDeviceID) -> String? { stringProperty(id, kAudioObjectPropertyName) }

    private static func stringProperty(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr,
              let s = value?.takeRetainedValue() else { return nil }
        return s as String
    }

    private static func inputChannelCount(_ id: AudioDeviceID) -> Int {
        var addr = address(kAudioDevicePropertyStreamConfiguration, scope: kAudioDevicePropertyScopeInput)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}

/// Watches Core Audio for device-list, default-input and sample-rate changes.
/// Calls `onChange` on the given queue; the receiver re-checks what it cares about.
public final class AudioDeviceWatcher {
    public enum Change: Sendable { case deviceList, defaultInput, sampleRate(AudioDeviceID), deviceDied(AudioDeviceID) }

    private let queue: DispatchQueue
    private let onChange: (Change) -> Void
    private var systemListeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var deviceListeners: [(AudioDeviceID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    public init(queue: DispatchQueue, onChange: @escaping (Change) -> Void) {
        self.queue = queue
        self.onChange = onChange
        addSystem(kAudioHardwarePropertyDevices) { [weak self] in self?.onChange(.deviceList) }
        addSystem(kAudioHardwarePropertyDefaultInputDevice) { [weak self] in self?.onChange(.defaultInput) }
    }

    deinit {
        let sys = AudioObjectID(kAudioObjectSystemObject)
        for (addr, block) in systemListeners {
            var a = addr
            AudioObjectRemovePropertyListenerBlock(sys, &a, queue, block)
        }
        watchDevice(nil)
    }

    /// Watch sample-rate and is-alive on this device (replacing any previous device).
    public func watchDevice(_ id: AudioDeviceID?) {
        for (dev, addr, block) in deviceListeners {
            var a = addr
            AudioObjectRemovePropertyListenerBlock(dev, &a, queue, block)
        }
        deviceListeners.removeAll()
        guard let id else { return }
        addDevice(id, kAudioDevicePropertyNominalSampleRate) { [weak self] in self?.onChange(.sampleRate(id)) }
        addDevice(id, kAudioDevicePropertyDeviceIsAlive) { [weak self] in self?.onChange(.deviceDied(id)) }
    }

    private func addSystem(_ selector: AudioObjectPropertySelector, _ handler: @escaping () -> Void) {
        var addr = AudioDevices.address(selector)
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, queue, block) == noErr {
            systemListeners.append((addr, block))
        }
    }

    private func addDevice(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector, _ handler: @escaping () -> Void) {
        var addr = AudioDevices.address(selector)
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        if AudioObjectAddPropertyListenerBlock(id, &addr, queue, block) == noErr {
            deviceListeners.append((id, addr, block))
        }
    }
}
