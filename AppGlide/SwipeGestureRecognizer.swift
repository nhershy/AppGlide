//
//  SwipeGestureRecognizer.swift
//  AppGlide
//

import Foundation
import OpenMultitouchSupport

enum SwipeDirection {
    case left
    case right
    case down
    /// Not a swipe: 3 fingers resting on the pad — show the carousel without
    /// stepping, so the user can see the ring before gliding.
    case peek
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
        /// Downward travel needed to fire the music HUD gesture.
        static let downThreshold: Float = 0.10
        /// MultitouchSupport normalized y grows upward (origin bottom-left),
        /// so a swipe DOWN makes accY negative. Flip to +1 if the DEBUG log
        /// in the vertical branch disproves this.
        static let downwardYSign: Float = -1
        /// Tolerated duration of a momentary finger dropout mid-gesture; also
        /// the longest a 2-finger lead-in still counts as a staggered landing
        /// rather than a scroll.
        static let fingerGrace: Duration = .milliseconds(120)
        /// 3 fingers resting this long fires .peek. Zero = the first frame
        /// they're all down (a 3-finger tap will flash the HUD; accepted).
        static let peekDelay: Duration = .zero
        /// While fingers stay down, .peek repeats at this cadence so the HUD's
        /// auto-hide keeps getting extended for the duration of the hold.
        static let peekRepeat: Duration = .milliseconds(500)
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
    private var threeFingersSince: ContinuousClock.Instant?
    private var lastPeekAt: ContinuousClock.Instant?
    private let clock = ContinuousClock()

    /// User-tunable thresholds (Settings window); Constants hold the defaults.
    private var firstStepDistance: Float {
        let value = UserDefaults.standard.double(forKey: PrefKey.swipeDistance)
        return value > 0 ? Float(value) : Constants.fireThreshold
    }

    private var glideStepDistance: Float {
        let value = UserDefaults.standard.double(forKey: PrefKey.glideStepDistance)
        return value > 0 ? Float(value) : Constants.continuationThreshold
    }

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
            if count == Constants.requiredFingers {
                threeFingersSince = threeFingersSince ?? clock.now
            }
            if abs(accY) > Constants.verticalAbort,
               abs(accX) <= Constants.dominanceRatio * abs(accY) {
                // Vertical gesture. Downward-dominant fires .down once;
                // upward (or diagonal mush) belongs to Mission Control — fail
                // silently. Either way latch .failed so neither horizontal
                // steps nor a second .down can fire until every touch lifts.
                #if DEBUG
                NSLog("AppGlide: vertical accY=%.3f (expect negative for swipe DOWN)", accY)
                #endif
                let firesDown = !hasFired
                    && Constants.downwardYSign * accY >= Constants.downThreshold
                    && abs(accY) > Constants.dominanceRatio * abs(accX)
                state = .failed
                return firesDown ? .down : nil
            } else {
                let threshold = hasFired ? glideStepDistance : firstStepDistance
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
                // No step this frame: 3 fingers resting past the dwell shows
                // the carousel (and keeps it alive for the duration of the hold).
                if count == Constants.requiredFingers,
                   let since = threeFingersSince,
                   clock.now - since >= Constants.peekDelay,
                   lastPeekAt.map({ clock.now - $0 >= Constants.peekRepeat }) ?? true {
                    lastPeekAt = clock.now
                    return .peek
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
