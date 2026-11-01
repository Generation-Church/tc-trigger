import CoreMIDI
import Foundation

/// A MIDI source or destination, identified by CoreMIDI's unique ID (stable across replugging).
public struct MIDIEndpointInfo: Identifiable, Hashable, Sendable {
    public var id: Int32 { uniqueID }
    public let uniqueID: Int32
    public let name: String
    let ref: MIDIEndpointRef
}

/// The controller side of MIDI: one input (buttons for Arm, Fire Next, …) and one output
/// destination (armed-state LED). Reconnects automatically when devices come and go.
public final class MIDIController {
    private var client = MIDIClientRef()
    private var inPort = MIDIPortRef()
    private var outPort = MIDIPortRef()
    private var connectedSource: MIDIEndpointRef?
    private let ownSourceName: String

    public private(set) var wantedInput: (id: Int32?, name: String?) = (nil, nil)
    public private(set) var wantedOutput: (id: Int32?, name: String?) = (nil, nil)
    public private(set) var connectedInput: MIDIEndpointInfo?
    public private(set) var connectedOutput: MIDIEndpointInfo?

    /// Incoming messages, delivered on the main queue.
    public var onMessage: ((MIDIMessage) -> Void)?
    /// Device list changed (and connections were re-checked). Main queue.
    public var onSetupChanged: (() -> Void)?

    public init(ownSourceName: String = "TC Trigger") throws {
        self.ownSourceName = ownSourceName
        var status = MIDIClientCreateWithBlock("TC Trigger control" as CFString, &client) { [weak self] note in
            if note.pointee.messageID == .msgSetupChanged {
                DispatchQueue.main.async { self?.setupChanged() }
            }
        }
        guard status == noErr else { throw MIDIError(step: "Create MIDI control client", status: status) }
        status = MIDIInputPortCreateWithProtocol(client, "Control In" as CFString, ._1_0, &inPort) { [weak self] list, _ in
            let messages = Self.decode(list)
            guard !messages.isEmpty else { return }
            DispatchQueue.main.async { messages.forEach { self?.onMessage?($0) } }
        }
        guard status == noErr else { throw MIDIError(step: "Create MIDI input port", status: status) }
        status = MIDIOutputPortCreate(client, "Feedback Out" as CFString, &outPort)
        guard status == noErr else { throw MIDIError(step: "Create MIDI output port", status: status) }
    }

    deinit { MIDIClientDispose(client) }

    // MARK: Devices

    /// Controllers we can listen to (excluding TC Trigger's own source).
    public func sources() -> [MIDIEndpointInfo] {
        (0..<MIDIGetNumberOfSources()).compactMap { info(MIDIGetSource($0)) }.filter { $0.name != ownSourceName }
    }

    public func destinations() -> [MIDIEndpointInfo] {
        (0..<MIDIGetNumberOfDestinations()).compactMap { info(MIDIGetDestination($0)) }
    }

    /// Listen to this controller (nil = none). Found again by ID, or by name if the ID changed.
    public func selectInput(id: Int32?, name: String?) {
        wantedInput = (id, name)
        connectInput()
    }

    public func selectOutput(id: Int32?, name: String?) {
        wantedOutput = (id, name)
        connectedOutput = find(in: destinations(), id: id, name: name)
    }

    /// Send to the feedback destination. Returns false if it isn't connected.
    @discardableResult
    public func sendFeedback(_ m: MIDIMessage) -> Bool {
        guard let dest = connectedOutput else { return false }
        var word = UInt32(0x2000_0000) | UInt32(m.status) << 16 | UInt32(m.data1) << 8 | UInt32(m.data2)
        var list = MIDIEventList()
        let packet = MIDIEventListInit(&list, ._1_0)
        _ = MIDIEventListAdd(&list, MemoryLayout<MIDIEventList>.size, packet, 0, 1, &word)
        return MIDISendEventList(outPort, dest.ref, &list) == noErr
    }

    // MARK: Private

    private func setupChanged() {
        connectInput()
        connectedOutput = find(in: destinations(), id: wantedOutput.id, name: wantedOutput.name)
        onSetupChanged?()
    }

    private func connectInput() {
        let target = find(in: sources(), id: wantedInput.id, name: wantedInput.name)
        if target?.ref == connectedSource { connectedInput = target; return }
        if let old = connectedSource { MIDIPortDisconnectSource(inPort, old) }
        connectedSource = nil
        connectedInput = nil
        if let t = target, MIDIPortConnectSource(inPort, t.ref, nil) == noErr {
            connectedSource = t.ref
            connectedInput = t
        }
    }

    private func find(in list: [MIDIEndpointInfo], id: Int32?, name: String?) -> MIDIEndpointInfo? {
        guard id != nil || name != nil else { return nil }
        return list.first { $0.uniqueID == id } ?? list.first { $0.name == name }
    }

    private func info(_ ref: MIDIEndpointRef) -> MIDIEndpointInfo? {
        guard ref != 0 else { return nil }
        var uid: Int32 = 0
        MIDIObjectGetIntegerProperty(ref, kMIDIPropertyUniqueID, &uid)
        var name: Unmanaged<CFString>?
        MIDIObjectGetStringProperty(ref, kMIDIPropertyDisplayName, &name)
        var offline: Int32 = 0
        MIDIObjectGetIntegerProperty(ref, kMIDIPropertyOffline, &offline)
        guard offline == 0, let n = name?.takeRetainedValue() as String? else { return nil }
        return MIDIEndpointInfo(uniqueID: uid, name: n, ref: ref)
    }

    /// MIDI 1.0 channel-voice messages out of a UMP event list.
    static func decode(_ list: UnsafePointer<MIDIEventList>) -> [MIDIMessage] {
        var out: [MIDIMessage] = []
        for packet in list.unsafeSequence() {
            let words = MIDIEventPacket.WordCollection(packet)
            for w in words where (w >> 28) == 0x2 {
                out.append(MIDIMessage(UInt8((w >> 16) & 0xFF), UInt8((w >> 8) & 0x7F), UInt8(w & 0x7F)))
            }
        }
        return out
    }
}
