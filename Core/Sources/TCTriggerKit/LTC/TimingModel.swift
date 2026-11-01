/// A least-squares straight-line fit of (frame index → arrival host time) over recent frames.
///
/// The slope is the real frame period (which absorbs any small speed difference between the
/// LTC source and this Mac's clock); the line predicts when any nearby frame will start.
public struct TimingModel: Sendable {
    public let capacity: Int
    private var points: [(index: Int, time: UInt64)] = []

    /// Difference between the last frame's actual and predicted start time, in seconds.
    public private(set) var lastResidual: Double?

    public init(capacity: Int = 64) {
        self.capacity = capacity
        points.reserveCapacity(capacity)
    }

    public var count: Int { points.count }

    /// Seconds covered by the frames in the model.
    public var span: Double {
        guard let a = points.first, let b = points.last else { return 0 }
        return HostClock.seconds(from: a.time, to: b.time)
    }

    public mutating func reset() {
        points.removeAll(keepingCapacity: true)
        lastResidual = nil
    }

    public mutating func add(index: Int, time: UInt64) {
        if points.count >= 4, let predicted = predict(index: index) {
            lastResidual = HostClock.seconds(from: predicted, to: time)
        }
        if points.count == capacity { points.removeFirst() }
        points.append((index, time))
    }

    /// (period in seconds, intercept time at the newest index) of the fitted line.
    private func fit() -> (period: Double, anchorIndex: Int, anchorTime: UInt64, offset: Double)? {
        guard points.count >= 2, let last = points.last else { return nil }
        // Work relative to the newest point to keep the numbers small.
        let n = Double(points.count)
        var sx = 0.0, sy = 0.0, sxx = 0.0, sxy = 0.0
        for p in points {
            let x = Double(p.index - last.index)
            let y = HostClock.seconds(from: last.time, to: p.time)
            sx += x; sy += y; sxx += x * x; sxy += x * y
        }
        let denom = n * sxx - sx * sx
        guard denom != 0 else { return nil }
        let slope = (n * sxy - sx * sy) / denom
        let intercept = (sy - slope * sx) / n
        return (slope, last.index, last.time, intercept)
    }

    /// Fitted frame period in seconds.
    public var period: Double? { fit()?.period }

    /// Predicted start host time of the frame with this index.
    public func predict(index: Int) -> UInt64? {
        guard let f = fit() else { return nil }
        let seconds = f.offset + f.period * Double(index - f.anchorIndex)
        return HostClock.adding(seconds, to: f.anchorTime)
    }
}
