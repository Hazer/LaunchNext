import LaunchNextCore
import CoreGraphics
import Foundation
import os

/// Unified HID-level gesture monitor that replaces both the OMS-based
/// GestureTouchProvider and the separate MagnifyEventSuppressor.
///
/// A single CGEventTap at the HID level both:
/// 1. Reads gesture events to detect multi-finger pinch-in/pinch-out
/// 2. Suppresses system magnify events by returning NULL from the callback
///
/// This eliminates the OMS third-party dependency, cross-thread race conditions
/// between detection and suppression, and the sleep/wake recovery hack.
///
/// Uses actor isolation for thread-safe state management. The CGEventTap
/// callback dispatches state mutations through the actor's executor,
/// avoiding manual lock management.
///
/// Architecture inspired by reverse-engineering LaunchOS v1.5.5.
public actor HIDGestureMonitor {

    // MARK: - Types

    public struct Configuration: Sendable, Equatable {
        public var isEnabled: Bool
        public var closeOnPinchOutEnabled: Bool = false
        public var requiredFingerCount: Int = 4
        public var openTriggerScaleRatio: Double = 0.84
        public var closeTriggerScaleRatio: Double = 1.10
        public var minimumConsecutiveMatches: Int = 2
        public var cooldownDuration: Double = 0.5
        public var smoothingAlpha: Double = 0.7

        public init(isEnabled: Bool,
                    closeOnPinchOutEnabled: Bool = false,
                    requiredFingerCount: Int = 4,
                    openTriggerScaleRatio: Double = 0.84,
                    closeTriggerScaleRatio: Double = 1.10,
                    minimumConsecutiveMatches: Int = 2,
                    cooldownDuration: Double = 0.5,
                    smoothingAlpha: Double = 0.7) {
            self.isEnabled = isEnabled
            self.closeOnPinchOutEnabled = closeOnPinchOutEnabled
            self.requiredFingerCount = requiredFingerCount
            self.openTriggerScaleRatio = openTriggerScaleRatio
            self.closeTriggerScaleRatio = closeTriggerScaleRatio
            self.minimumConsecutiveMatches = minimumConsecutiveMatches
            self.cooldownDuration = cooldownDuration
            self.smoothingAlpha = smoothingAlpha
        }
    }

    public enum Action: Sendable {
        case open
        case close
    }

    // MARK: - CGEvent constants (not exposed as named constants in Swift SDK)

    /// CGEventType for gesture events (kCGEventGesture)
    private static let gestureEventType = CGEventType(rawValue: 29)

    /// CGEventField for gesture subtype
    public static let gestureSubtypeField = CGEventField(rawValue: 59)!

    /// Magnify gesture subtype value
    public static let magnifySubtype: Int64 = 2

    /// Number of fingers in the gesture
    public static let gestureFingerCountField = CGEventField(rawValue: 44)!

    /// Gesture phase field
    public static let gesturePhaseField = CGEventField(rawValue: 51)!

    /// Gesture magnification value field
    public static let gestureMagnificationField = CGEventField(rawValue: 61)!

    /// HID-level event tap location
    private static let hidEventTap = CGEventTapLocation(rawValue: 0)!

    // MARK: - Gesture phase raw values (shared with CallbackContext)

    public enum GesturePhaseRaw: Int64 {
        case began = 1
        case changed = 2
        case ended = 4
        case cancelled = 8
    }

    // MARK: - Tracking state (actor-isolated, no locks needed)

    private var baselineScale: Double = 1.0
    private var filteredScale: Double = 1.0
    private var consecutiveMatches: Int = 0
    private var isTracking: Bool = false
    private var cooldownUntil: Double = 0

    // MARK: - Tap lifecycle state

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private var configuration: Configuration
    private let onTrigger: @Sendable (Action) -> Void

    /// Flag read by the C callback to decide suppression.
    /// Written by the actor, read by the C callback thread.
    /// Uses OSAllocatedUnfairLock because the C callback runs outside the actor.
    private let suppressFlag = OSAllocatedUnfairLock<Bool>(uncheckedState: false)

    // MARK: - Init

    public init(configuration: Configuration, onTrigger: @escaping @Sendable (Action) -> Void) {
        self.configuration = configuration
        self.onTrigger = onTrigger
    }

    // MARK: - Public interface

    public func update(configuration: Configuration) {
        self.configuration = configuration
        if !configuration.isEnabled {
            stop()
        }
    }

    public func start() async {
        guard configuration.isEnabled else { return }
        guard tap == nil else { return }
        guard let gestureEventType = Self.gestureEventType else { return }

        let config = self.configuration

        let context = Unmanaged.passRetained(CallbackContext(
            suppressFlag: suppressFlag,
            onAction: { [weak self] action in
                guard let self else { return }
                Task { await self.handleAction(action) }
            },
            gestureEventType: gestureEventType,
            gestureSubtypeField: Self.gestureSubtypeField,
            magnifySubtype: Self.magnifySubtype,
            fingerCountField: Self.gestureFingerCountField,
            phaseField: Self.gesturePhaseField,
            magnificationField: Self.gestureMagnificationField,
            requiredFingerCount: Int64(config.requiredFingerCount),
            openTriggerScaleRatio: config.openTriggerScaleRatio,
            closeTriggerScaleRatio: config.closeTriggerScaleRatio,
            closeOnPinchOutEnabled: config.closeOnPinchOutEnabled,
            minimumConsecutiveMatches: config.minimumConsecutiveMatches,
            cooldownDuration: config.cooldownDuration,
            smoothingAlpha: config.smoothingAlpha
        ))

        guard let createdTap = CGEvent.tapCreate(
            tap: Self.hidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: 1 << gestureEventType.rawValue,
            callback: { _, _, event, userInfo -> Unmanaged<CGEvent>? in
                guard let userInfo else {
                    return Unmanaged.passUnretained(event)
                }
                let ctx = Unmanaged<CallbackContext>.fromOpaque(userInfo).takeUnretainedValue()
                return ctx.handleEvent(event)
            },
            userInfo: context.toOpaque()
        ) else {
            context.release()
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, createdTap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: createdTap, enable: true)

        self.tap = createdTap
        self.runLoopSource = source
    }

    public func stop() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        // Context is released via the tap's userInfo — it lives as long as the tap.
        self.tap = nil
        self.runLoopSource = nil

        baselineScale = 1.0
        filteredScale = 1.0
        consecutiveMatches = 0
        isTracking = false
        suppressFlag.withLockUnchecked { $0 = false }
    }

    public func restart() async {
        stop()
        await start()
    }

    // MARK: - Internal

    private func handleAction(_ action: Action) {
        onTrigger(action)
    }
}

// MARK: - Callback Context

/// Context passed through the C callback's `userInfo` pointer.
///
/// This class is `@unchecked Sendable` because it's shared between the
/// C callback thread and the actor. It only uses lock-protected or
/// immutable properties for cross-thread access.
///
/// The state machine runs entirely in the C callback (on the run loop thread)
/// to avoid the latency of dispatching to an actor. Triggered actions are
/// dispatched asynchronously to the actor's `handleAction`.
private final class CallbackContext: @unchecked Sendable {
    let suppressFlag: OSAllocatedUnfairLock<Bool>
    let onAction: @Sendable (HIDGestureMonitor.Action) -> Void

    // Immutable config snapshot — captured at start() time
    let gestureEventType: CGEventType
    let gestureSubtypeField: CGEventField
    let magnifySubtype: Int64
    let fingerCountField: CGEventField
    let phaseField: CGEventField
    let magnificationField: CGEventField
    let requiredFingerCount: Int64
    let openTriggerScaleRatio: Double
    let closeTriggerScaleRatio: Double
    let closeOnPinchOutEnabled: Bool
    let minimumConsecutiveMatches: Int
    let cooldownDuration: Double
    let smoothingAlpha: Double

    // Mutable tracking state — only accessed from the run loop thread
    // (the CGEventTap callback is always called on the run loop that added it)
    private var baselineScale: Double = 1.0
    private var filteredScale: Double = 1.0
    private var consecutiveMatches: Int = 0
    private var isTracking: Bool = false
    private var cooldownUntil: Double = 0

    init(suppressFlag: OSAllocatedUnfairLock<Bool>,
         onAction: @escaping @Sendable (HIDGestureMonitor.Action) -> Void,
         gestureEventType: CGEventType,
         gestureSubtypeField: CGEventField,
         magnifySubtype: Int64,
         fingerCountField: CGEventField,
         phaseField: CGEventField,
         magnificationField: CGEventField,
         requiredFingerCount: Int64,
         openTriggerScaleRatio: Double,
         closeTriggerScaleRatio: Double,
         closeOnPinchOutEnabled: Bool,
         minimumConsecutiveMatches: Int,
         cooldownDuration: Double,
         smoothingAlpha: Double) {
        self.suppressFlag = suppressFlag
        self.onAction = onAction
        self.gestureEventType = gestureEventType
        self.gestureSubtypeField = gestureSubtypeField
        self.magnifySubtype = magnifySubtype
        self.fingerCountField = fingerCountField
        self.phaseField = phaseField
        self.magnificationField = magnificationField
        self.requiredFingerCount = requiredFingerCount
        self.openTriggerScaleRatio = openTriggerScaleRatio
        self.closeTriggerScaleRatio = closeTriggerScaleRatio
        self.closeOnPinchOutEnabled = closeOnPinchOutEnabled
        self.minimumConsecutiveMatches = minimumConsecutiveMatches
        self.cooldownDuration = cooldownDuration
        self.smoothingAlpha = smoothingAlpha
    }

    /// Single callback for both gesture detection and system event suppression.
    /// Returns nil to swallow the event (preventing the system Apps menu).
    func handleEvent(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        guard event.type == gestureEventType else {
            return Unmanaged.passUnretained(event)
        }

        let subtype = event.getIntegerValueField(gestureSubtypeField)
        guard subtype == magnifySubtype else {
            return Unmanaged.passUnretained(event)
        }

        let time = ProcessInfo.processInfo.systemUptime
        let fingerCount = event.getIntegerValueField(fingerCountField)
        let rawPhase = event.getIntegerValueField(phaseField)
        let magnification = event.getDoubleValueField(magnificationField)

        // Phase flags
        let phaseBegan = HIDGestureMonitor.GesturePhaseRaw.began.rawValue
        let phaseChanged = HIDGestureMonitor.GesturePhaseRaw.changed.rawValue
        let phaseEnded = HIDGestureMonitor.GesturePhaseRaw.ended.rawValue
        let phaseCancelled = HIDGestureMonitor.GesturePhaseRaw.cancelled.rawValue

        let isBegin = (rawPhase & phaseBegan) != 0
        let isChange = (rawPhase & phaseChanged) != 0
        let isEnd = (rawPhase & phaseEnded) != 0 || (rawPhase & phaseCancelled) != 0

        // Cooldown check
        guard time >= cooldownUntil else {
            suppressFlag.withLockUnchecked { $0 = isTracking }
            return isTracking ? nil : Unmanaged.passUnretained(event)
        }

        // Start tracking on begin with correct finger count
        if isBegin && !isEnd && fingerCount == requiredFingerCount && !isTracking {
            baselineScale = 1.0
            filteredScale = 1.0
            isTracking = true
            consecutiveMatches = 0
        }

        // Process changes
        if isChange && isTracking {
            if fingerCount != requiredFingerCount {
                isTracking = false
                consecutiveMatches = 0
                suppressFlag.withLockUnchecked { $0 = false }
                return Unmanaged.passUnretained(event)
            }

            // Exponential smoothing on magnification delta
            let smoothed = (filteredScale * smoothingAlpha) +
                           ((filteredScale + magnification) * (1 - smoothingAlpha))
            filteredScale = smoothed

            let scaleRatio = smoothed / baselineScale

            var detectedAction: HIDGestureMonitor.Action?

            if scaleRatio <= openTriggerScaleRatio {
                detectedAction = .open
            } else if closeOnPinchOutEnabled && scaleRatio >= closeTriggerScaleRatio {
                detectedAction = .close
            }

            if let detectedAction {
                consecutiveMatches += 1
                if consecutiveMatches >= minimumConsecutiveMatches {
                    isTracking = false
                    cooldownUntil = time + cooldownDuration
                    suppressFlag.withLockUnchecked { $0 = false }
                    onAction(detectedAction)
                    return Unmanaged.passUnretained(event)
                }
            } else {
                consecutiveMatches = 0
            }
        }

        // End tracking
        if isEnd {
            isTracking = false
            consecutiveMatches = 0
        }

        // Suppress system magnify while tracking
        suppressFlag.withLockUnchecked { $0 = isTracking }
        return isTracking ? nil : Unmanaged.passUnretained(event)
    }
}
