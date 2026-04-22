import Foundation
import os

/// High-level gesture monitor that wraps HIDGestureMonitor (actor-based).
///
/// Translates HIDGestureMonitor.Action into GestureTriggerAction and
/// manages the monitor lifecycle. The underlying HIDGestureMonitor uses
/// a single CGEventTap for both gesture detection and system event suppression,
/// eliminating the need for OMS and a separate MagnifyEventSuppressor.
@MainActor
final class GestureMonitor: Sendable {
    typealias Configuration = GestureConfiguration

    private let onTrigger: @Sendable (GestureTriggerAction) -> Void
    private let configurationBox = OSAllocatedUnfairLock<Configuration>(uncheckedState:
        Configuration(isEnabled: false)
    )

    /// Underlying HID-level actor monitor
    private var hidMonitor: HIDGestureMonitor?

    var configuration: Configuration {
        get { configurationBox.withLockUnchecked { $0 } }
        set { configurationBox.withLockUnchecked { $0 = newValue } }
    }

    init(configuration: Configuration, onTrigger: @escaping @Sendable (GestureTriggerAction) -> Void) {
        self.configurationBox.withLockUnchecked { $0 = configuration }
        self.onTrigger = onTrigger
    }

    // nonisolated deinit needed because self is actor-isolated
    // but we need to clean up the actor monitor
    deinit {
        // HIDGestureMonitor's own deinit handles stop()
        hidMonitor = nil
    }

    func update(configuration newConfiguration: Configuration) {
        configuration = newConfiguration

        if !newConfiguration.isEnabled {
            stop()
            return
        }

        let hidConfig = HIDGestureMonitor.Configuration(
            isEnabled: newConfiguration.isEnabled,
            closeOnPinchOutEnabled: newConfiguration.closeOnPinchOutEnabled,
            requiredFingerCount: newConfiguration.requiredFingerCount,
            openTriggerScaleRatio: newConfiguration.openTriggerScaleRatio,
            closeTriggerScaleRatio: newConfiguration.closeTriggerScaleRatio,
            minimumConsecutiveMatches: newConfiguration.requiredConsecutiveMatches,
            cooldownDuration: newConfiguration.cooldownDuration,
            smoothingAlpha: 0.7
        )

        if let hidMonitor {
            Task { await hidMonitor.update(configuration: hidConfig) }
        } else {
            let monitor = HIDGestureMonitor(configuration: hidConfig) { [weak self] action in
                guard let self else { return }
                let mapped: GestureTriggerAction = switch action {
                case .open: .open
                case .close: .close
                }
                Task { @MainActor in
                    self.onTrigger(mapped)
                }
            }
            hidMonitor = monitor
            Task { await monitor.start() }
        }
    }

    func start() {
        guard configuration.isEnabled else { return }
        update(configuration: configuration)
    }

    func restart() {
        stop()
        start()
    }

    func stop() {
        if let hidMonitor {
            Task { await hidMonitor.stop() }
        }
    }
}
