import Foundation

/// Keeps a separate byte window per notifying characteristic.
///
/// CoreBluetooth may interleave fragments from fd4b0003/0004/0005/0007. Feeding those fragments into
/// one shared `Reassembler` can splice unrelated frames together. This keyed bank preserves ordering
/// within each characteristic and makes the characteristic boundary part of reassembly state.
public final class CharacteristicReassembler {
    private let family: DeviceFamily
    private var lanes: [String: Reassembler] = [:]

    public init(family: DeviceFamily = .whoop4) {
        self.family = family
    }

    public func feed(_ fragment: [UInt8], characteristicID: String) -> [[UInt8]] {
        let lane: Reassembler
        if let existing = lanes[characteristicID] {
            lane = existing
        } else {
            let created = Reassembler(family: family)
            lanes[characteristicID] = created
            lane = created
        }
        return lane.feed(fragment)
    }

    public func reset() {
        lanes.removeAll(keepingCapacity: true)
    }
}
