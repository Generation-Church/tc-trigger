import AudioToolbox
import CoreAudio
import CTCCore
import Foundation

public struct AudioInputError: Error, CustomStringConvertible {
    public let step: String
    public let status: OSStatus
    public var description: String { "\(step) failed (OSStatus \(status))" }
}

/// What a running input is doing, for display and logging.
public struct AudioInputInfo: Equatable, Sendable {
    public var deviceID: AudioDeviceID
    public var deviceName: String
    public var deviceUID: String
    public var channel: Int // 1-based
    public var sampleRate: Double
    public var bufferFrames: Int?
}

/// Pulls one channel from an input device through an AUHAL audio unit, as an extra client
/// alongside Ableton. It never changes the device's sample rate or buffer size and never takes
/// exclusive (hog) access. The real-time callback is the C function tc_rt_input_proc.
public final class AudioInput {
    public static let maxFramesPerCallback: UInt32 = 4096

    private var unit: AudioUnit?
    public private(set) var rt: OpaquePointer?
    public private(set) var info: AudioInputInfo?

    public init() {}

    deinit { stop() }

    public var isRunning: Bool { unit != nil }

    /// Start capturing `channel` (1-based) of `device`.
    public func start(device: AudioInputDevice, channel: Int) throws {
        stop()
        guard channel >= 1, channel <= device.inputChannels else {
            throw AudioInputError(step: "Channel \(channel) not available on \(device.name)", status: -50)
        }

        var desc = AudioComponentDescription(componentType: kAudioUnitType_Output,
                                             componentSubType: kAudioUnitSubType_HALOutput,
                                             componentManufacturer: kAudioUnitManufacturer_Apple,
                                             componentFlags: 0, componentFlagsMask: 0)
        guard let comp = AudioComponentFindNext(nil, &desc) else {
            throw AudioInputError(step: "Find HAL audio unit", status: -1)
        }
        var newUnit: AudioUnit?
        try check(AudioComponentInstanceNew(comp, &newUnit), "Create audio unit")
        guard let au = newUnit else { throw AudioInputError(step: "Create audio unit", status: -1) }

        var created: OpaquePointer?
        do {
            var one: UInt32 = 1, zero: UInt32 = 0
            try set(au, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &one, "Enable input")
            try set(au, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &zero, "Disable output")
            var dev = device.deviceID
            try set(au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &dev, "Select device")

            // The device side of the input bus tells us the hardware sample rate.
            var hw = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try check(AudioUnitGetProperty(au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &hw, &size),
                      "Read device format")
            let sampleRate = hw.mSampleRate > 0 ? hw.mSampleRate : device.nominalSampleRate

            // Ask for just our one channel, as 32-bit float.
            var client = AudioStreamBasicDescription(
                mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
                mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1,
                mBitsPerChannel: 32, mReserved: 0)
            try set(au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &client, "Set client format")
            var map: [Int32] = [Int32(channel - 1)]
            try check(AudioUnitSetProperty(au, kAudioOutputUnitProperty_ChannelMap, kAudioUnitScope_Output, 1,
                                           &map, UInt32(MemoryLayout<Int32>.size)), "Set channel map")
            var maxFrames = Self.maxFramesPerCallback
            try set(au, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFrames, "Set max frames")

            guard let r = tc_rt_create(sampleRate, Self.maxFramesPerCallback) else {
                throw AudioInputError(step: "Allocate decoder", status: -1)
            }
            created = r
            tc_rt_set_audio_unit(r, au)
            var cb = AURenderCallbackStruct(inputProc: tc_rt_input_proc, inputProcRefCon: UnsafeMutableRawPointer(r))
            try set(au, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &cb, "Set input callback")

            try check(AudioUnitInitialize(au), "Initialize audio unit")
            try check(AudioOutputUnitStart(au), "Start audio unit")

            unit = au
            rt = r
            info = AudioInputInfo(deviceID: device.deviceID, deviceName: device.name, deviceUID: device.uid,
                                  channel: channel, sampleRate: sampleRate,
                                  bufferFrames: AudioDevices.bufferFrameSize(device.deviceID))
        } catch {
            AudioUnitUninitialize(au)
            AudioComponentInstanceDispose(au)
            if let created { tc_rt_destroy(created) }
            throw error
        }
    }

    public func stop() {
        if let au = unit {
            // AudioOutputUnitStop waits for any callback in progress, so freeing rt afterwards is safe.
            AudioOutputUnitStop(au)
            AudioUnitUninitialize(au)
            AudioComponentInstanceDispose(au)
        }
        unit = nil
        if let r = rt { tc_rt_destroy(r) }
        rt = nil
        info = nil
    }

    // MARK: Reading (engine thread)

    public func popFrame() -> DecodedFrame? {
        guard let rt else { return nil }
        var f = tc_frame_t()
        return tc_rt_pop_frame(rt, &f) != 0 ? DecodedFrame(f) : nil
    }

    public func takePeak() -> Float {
        guard let rt else { return 0 }
        return tc_rt_take_peak(rt)
    }

    public func stats() -> tc_rt_stats_t? {
        guard let rt else { return nil }
        var s = tc_rt_stats_t()
        tc_rt_get_stats(rt, &s)
        return s
    }

    // MARK: Helpers

    private func check(_ status: OSStatus, _ step: String) throws {
        if status != noErr { throw AudioInputError(step: step, status: status) }
    }

    private func set<T: BitwiseCopyable>(_ au: AudioUnit, _ prop: AudioUnitPropertyID, _ scope: AudioUnitScope,
                        _ element: AudioUnitElement, _ value: inout T, _ step: String) throws {
        try check(AudioUnitSetProperty(au, prop, scope, element, &value, UInt32(MemoryLayout<T>.size)), step)
    }
}
