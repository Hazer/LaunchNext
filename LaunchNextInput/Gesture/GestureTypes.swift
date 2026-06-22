import CoreGraphics
import Foundation

/// Single multitouch sample (one finger at one instant).
///
/// Identity (`id`) is stable across consecutive frames for the same finger
/// while it remains in contact; it is reused by the input provider when
/// synthesizing frames from raw HID records or gesture events.
public struct GestureTouchSample: Sendable, Equatable {
    public let id: Int32
    public let point: CGPoint

    public init(id: Int32, point: CGPoint) {
        self.id = id
        self.point = point
    }
}

/// One frame of multitouch input, scoped to a single source device.
///
/// `deviceID` identifies the origin (e.g. built-in trackpad vs external).
/// When the input source is system-wide and doesn't expose per-device data
/// (as with `kCGHIDEventTap`), `deviceID` is a constant sentinel.
public struct GestureTouchFrame: Sendable, Equatable {
    public let deviceID: String
    public let samples: [GestureTouchSample]

    public init(deviceID: String, samples: [GestureTouchSample]) {
        self.deviceID = deviceID
        self.samples = samples
    }
}

/// Action emitted by `GestureStateMachine` when a gesture is recognized.
public enum GestureTriggerAction: Sendable, Equatable {
    case open
    case close
    case toggle
}
