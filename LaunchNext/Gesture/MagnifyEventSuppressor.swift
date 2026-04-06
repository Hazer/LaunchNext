import CoreGraphics
import os

/// Suppresses system-wide magnify (pinch) events while a four-finger
/// gesture is being tracked by the OMS-based gesture monitor.
///
/// Without this, both LaunchNext and the system Dock race to handle the same
/// trackpad gesture, causing the default Launchpad to appear alongside or
/// instead of the LaunchNext window.
///
/// The tap runs at the HID event tap level so it fires before the window
/// server processes the event. It reads a lock-protected flag that the
/// gesture monitor sets while it is actively tracking a potential pinch
/// gesture. Because four-finger pinches are distinct from normal two-finger
/// pinch-to-zoom, regular magnify gestures still work in other apps.
///
/// Requires the "Input Monitoring" accessibility permission (the same one
/// OMS needs), so no extra permission prompt is introduced. If the event
/// tap cannot be created (e.g. permission denied), it falls back silently —
/// the OMS gesture still works, the system gesture just won't be suppressed.
final class MagnifyEventSuppressor: Sendable {

    // MARK: - Public interface

    /// The gesture monitor writes this lock; the event tap callback reads it.
    let flag = OSAllocatedUnfairLock<Bool>(uncheckedState: false)

    // MARK: - Lifecycle

    private let state = OSAllocatedUnfairLock<State>(uncheckedState: .idle)

    private enum State: Sendable {
        case idle
        case active(tap: CFMachPort, source: CFRunLoopSource?, context: Unmanaged<Context>)
    }

    // CGEventType / CGEventField members without Swift names in macOS 26 SDK.
    private static let gestureEventType = CGEventType(rawValue: 29)!
    private static let gestureSubtypeField = CGEventField(rawValue: 59)!
    private static let magnifySubtype: Int64 = 2
    private static let hidEventTap = CGEventTapLocation(rawValue: 0)!

    deinit {
        stop()
    }

    /// Creates and activates the event tap on the main run loop.
    /// Safe to call multiple times; subsequent calls are no-ops.
    func start() {
        state.withLock { s in
            guard case .idle = s else { return }

            let context = Unmanaged.passRetained(Context(
                flag: flag,
                gestureEventType: Self.gestureEventType,
                gestureSubtypeField: Self.gestureSubtypeField,
                magnifySubtype: Self.magnifySubtype
            ))

            let tap = CGEvent.tapCreate(
                tap: Self.hidEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: 1 << Self.gestureEventType.rawValue,
                callback: { _, _, event, userInfo -> Unmanaged<CGEvent>? in
                    guard let userInfo else {
                        return Unmanaged.passUnretained(event)
                    }
                    let ctx = Unmanaged<Context>.fromOpaque(userInfo).takeUnretainedValue()

                    guard event.type == ctx.gestureEventType else {
                        return Unmanaged.passUnretained(event)
                    }
                    let subType = event.getIntegerValueField(ctx.gestureSubtypeField)
                    guard subType == ctx.magnifySubtype else {
                        return Unmanaged.passUnretained(event)
                    }
                    let suppress = ctx.flag.withLockUnchecked { $0 }
                    return suppress ? nil : Unmanaged.passUnretained(event)
                },
                userInfo: context.toOpaque()
            )

            guard let tap else {
                context.release()
                return
            }

            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            s = .active(tap: tap, source: source, context: context)
        }
    }

    /// Stops the event tap and removes it from the run loop.
    func stop() {
        state.withLock { s in
            guard case let .active(tap, source, context) = s else { return }
            if let source {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            }
            CGEvent.tapEnable(tap: tap, enable: false)
            context.release()
            s = .idle
        }
        flag.withLockUnchecked { $0 = false }
    }
}

/// Context object passed through the C callback's `userInfo` pointer.
private final class Context: @unchecked Sendable {
    let flag: OSAllocatedUnfairLock<Bool>
    let gestureEventType: CGEventType
    let gestureSubtypeField: CGEventField
    let magnifySubtype: Int64

    init(flag: OSAllocatedUnfairLock<Bool>,
         gestureEventType: CGEventType,
         gestureSubtypeField: CGEventField,
         magnifySubtype: Int64) {
        self.flag = flag
        self.gestureEventType = gestureEventType
        self.gestureSubtypeField = gestureSubtypeField
        self.magnifySubtype = magnifySubtype
    }
}
