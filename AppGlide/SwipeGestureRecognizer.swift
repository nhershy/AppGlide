//
//  SwipeGestureRecognizer.swift
//  AppGlide
//

import OpenMultitouchSupport

enum SwipeDirection {
    case left
    case right
}

/// Detects 3-finger horizontal swipe steps from raw multitouch frames.
///
/// A gesture fires its first step after `fireThreshold` of travel, then keeps
/// firing — one step per additional `continuationThreshold` of travel — for as
/// long as the fingers stay down, so a long glide scrubs across several apps.
/// Reversing direction mid-glide steps back. Failing (vertical motion, extra
/// fingers) latches the recognizer inert until every touch lifts.
///
/// Tracking starts at 2 fingers and keeps accumulating through brief 2-finger
/// phases so the staggered landing and lift-off of a fast flick still count
/// toward the threshold — but firing requires that 3 fingers were down, so a
/// plain 2-finger scroll can never trigger, and a scroll that only later gains
/// a third finger has its tally reset before it can fire.
struct SwipeGestureRecognizer {
    enum Constants {
        static let requiredFingers = 3
        /// Travel needed for the first step, as a fraction of trackpad width.
        static let fireThreshold: Float = 0.08
        /// Additional travel per subsequent step while fingers stay down.
        static let continuationThreshold: Float = 0.10
        /// |accX| must exceed this multiple of |accY| for the motion to count as horizontal.
        static let dominanceRatio: Float = 1.5
        /// Vertical travel beyond which a non-dominant gesture is abandoned.
        static let verticalAbort: Float = 0.10
        /// Tolerated duration of a momentary finger dropout mid-gesture; also
        /// the longest a 2-finger lead-in still counts as a staggered landing
        /// rather than a scroll.
        static let fingerGrace: Duration = .milliseconds(120)
    }

    private enum State {
        case idle
        case tracking
        case failed
    }

    private var state: State = .idle
    private var accX: Float = 0
    private var accY: Float = 0
    private var prevMeanX: Float = 0
    private var prevMeanY: Float = 0
    private var prevCount = 0
    private var sawRequiredFingers = false
    private var hasFired = false
    private var trackingStart: ContinuousClock.Instant?
    private var graceDeadline: ContinuousClock.Instant?
    private let clock = ContinuousClock()

    mutating func consume(_ frame: [OMSTouchData]) -> SwipeDirection? {
        let active = frame.filter { $0.state == .touching || $0.state == .making }
        let count = active.count

        if count == 0 {
            reset()
            return nil
        }

        switch state {
        case .idle:
            if count > Constants.requiredFingers {
                state = .failed
            } else if count >= 2 {
                state = .tracking
                trackingStart = clock.now
                sawRequiredFingers = count == Constants.requiredFingers
                prevMeanX = mean(active.map(\.position.x))
                prevMeanY = mean(active.map(\.position.y))
                prevCount = count
                accX = 0
                accY = 0
                graceDeadline = nil
            }

        case .tracking:
            if count > Constants.requiredFingers {
                state = .failed
                return nil
            }
            if count == 1 {
                // Mid-lift with one finger left: pause, fail once grace expires.
                prevCount = 1
                if let deadline = graceDeadline {
                    if clock.now > deadline { state = .failed }
                } else {
                    graceDeadline = clock.now + Constants.fingerGrace
                }
                return nil
            }

            if count == Constants.requiredFingers {
                graceDeadline = nil
                if !sawRequiredFingers {
                    sawRequiredFingers = true
                    // A long 2-finger lead-in was a scroll, not a staggered
                    // landing — its travel must not count toward the swipe.
                    if let start = trackingStart, clock.now - start > Constants.fingerGrace {
                        accX = 0
                        accY = 0
                    }
                }
            } else if sawRequiredFingers {
                // A finger lifted: keep accumulating within the grace window.
                if let deadline = graceDeadline {
                    if clock.now > deadline {
                        state = .failed
                        return nil
                    }
                } else {
                    graceDeadline = clock.now + Constants.fingerGrace
                }
            }

            let meanX = mean(active.map(\.position.x))
            let meanY = mean(active.map(\.position.y))
            // Deltas are only valid between consecutive frames with the same
            // finger count; a count change shifts the mean without real motion.
            if prevCount == count {
                accX += meanX - prevMeanX
                accY += meanY - prevMeanY
            }
            prevMeanX = meanX
            prevMeanY = meanY
            prevCount = count

            guard sawRequiredFingers else { return nil }
            if abs(accY) > Constants.verticalAbort,
               abs(accX) <= Constants.dominanceRatio * abs(accY) {
                state = .failed
            } else {
                let threshold = hasFired ? Constants.continuationThreshold : Constants.fireThreshold
                if abs(accX) >= threshold,
                   abs(accX) > Constants.dominanceRatio * abs(accY) {
                    let direction: SwipeDirection = accX < 0 ? .left : .right
                    // Keep the remainder so detents stay evenly spaced during
                    // a continuous glide; verticality is judged per segment.
                    accX += accX < 0 ? threshold : -threshold
                    accY = 0
                    hasFired = true
                    return direction
                }
            }

        case .failed:
            break
        }
        return nil
    }

    private mutating func reset() {
        self = SwipeGestureRecognizer()
    }

    private func mean(_ values: [Float]) -> Float {
        values.reduce(0, +) / Float(values.count)
    }
}
