import CoreMIDI
import Foundation

/// Somewhere MIDI can be sent. `hostTime` is the CoreMIDI timestamp to attach.
public protocol MIDISink: AnyObject {
    func send(_ status: UInt8, _ data1: UInt8, _ data2: UInt8, hostTime: UInt64)
}

public struct MIDIError: Error, CustomStringConvertible {
    public let step: String
    public let status: OSStatus
    public var description: String { "\(step) failed (OSStatus \(status))" }
}

/// The app's own virtual MIDI source. Ableton sees it as an input device named "TC Trigger".
public final class VirtualMIDISource: MIDISink {
    public let name: String
    private var client = MIDIClientRef()
    private var source = MIDIEndpointRef()
    public private(set) var uniqueID: Int32 = 0

    /// - Parameter uniqueID: reuse the ID from last launch so Ableton treats it as the same device.
    public init(name: String = "TC Trigger", uniqueID: Int32?) throws {
        self.name = name
        var status = MIDIClientCreateWithBlock("TC Trigger" as CFString, &client) { _ in }
        guard status == noErr else { throw MIDIError(step: "Create MIDI client", status: status) }
        status = MIDISourceCreateWithProtocol(client, name as CFString, ._1_0, &source)
        guard status == noErr else { throw MIDIError(step: "Create virtual MIDI source", status: status) }
        if let uniqueID, MIDIObjectSetIntegerProperty(source, kMIDIPropertyUniqueID, uniqueID) == noErr {
            self.uniqueID = uniqueID
        } else {
            var id: Int32 = 0
            MIDIObjectGetIntegerProperty(source, kMIDIPropertyUniqueID, &id)
            self.uniqueID = id
        }
    }

    deinit {
        MIDIEndpointDispose(source)
        MIDIClientDispose(client)
    }

    public func send(_ status: UInt8, _ data1: UInt8, _ data2: UInt8, hostTime: UInt64) {
        // MIDI 1.0 channel-voice message as a Universal MIDI Packet (type 2, group 0).
        var word = UInt32(0x2000_0000) | UInt32(status) << 16 | UInt32(data1 & 0x7F) << 8 | UInt32(data2 & 0x7F)
        var list = MIDIEventList()
        let packet = MIDIEventListInit(&list, ._1_0)
        _ = MIDIEventListAdd(&list, MemoryLayout<MIDIEventList>.size, packet, hostTime, 1, &word)
        MIDIReceivedEventList(source, &list)
    }
}

/// A MIDI sink that records what it was sent (for tests).
public final class RecordingMIDISink: MIDISink, @unchecked Sendable {
    public struct Message: Equatable, Sendable {
        public let status: UInt8, data1: UInt8, data2: UInt8
        public let hostTime: UInt64
        public let sentAt: UInt64
    }

    private let lock = NSLock()
    private var _messages: [Message] = []

    public init() {}

    public var messages: [Message] { lock.withLock { _messages } }

    public func send(_ status: UInt8, _ data1: UInt8, _ data2: UInt8, hostTime: UInt64) {
        let m = Message(status: status, data1: data1, data2: data2, hostTime: hostTime, sentAt: HostClock.now())
        lock.withLock { _messages.append(m) }
    }
}
