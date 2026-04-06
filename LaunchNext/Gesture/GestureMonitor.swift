import Foundation
import os

final class GestureMonitor: Sendable {
    typealias Configuration = GestureConfiguration

    private let provider = GestureTouchProvider()
    private let onTrigger: @Sendable (GestureTriggerAction) -> Void
    private let configurationBox: OSAllocatedUnfairLock<Configuration>
    private let monitorTaskBox = OSAllocatedUnfairLock<Task<Void, Never>?>(uncheckedState: nil)

    /// Optional reference to the magnify-event suppressor. When set, the
    /// monitor drives its ``MagnifyEventSuppressor/flag`` based on the
    /// state machine's tracking state.
    weak var magnifySuppressor: MagnifyEventSuppressor?

    var configuration: Configuration {
        get { configurationBox.withLockUnchecked { $0 } }
        set { configurationBox.withLockUnchecked { $0 = newValue } }
    }

    init(configuration: Configuration, onTrigger: @escaping @Sendable (GestureTriggerAction) -> Void) {
        self.configurationBox = OSAllocatedUnfairLock(uncheckedState: configuration)
        self.onTrigger = onTrigger
    }

    deinit {
        stop()
    }

    func update(configuration newConfiguration: Configuration) {
        let previousConfiguration = configuration
        configuration = newConfiguration

        if !newConfiguration.isEnabled {
            stop()
            return
        }

        if monitorTaskBox.withLockUnchecked({ $0 != nil }), previousConfiguration != newConfiguration {
            stop()
        }

        let isListening = provider.isListening
        let hasTask = monitorTaskBox.withLockUnchecked({ $0 != nil })
        if !hasTask || !isListening {
            start()
        }
    }

    func start() {
        guard configuration.isEnabled else { return }
        guard monitorTaskBox.withLockUnchecked({ $0 == nil }) else { return }

        guard provider.startListening() else { return }
        let config = configuration
        let suppressor = self.magnifySuppressor
        let task = Task { [provider, onTrigger] in
            var machine = GestureStateMachine(configuration: config)
            for await samples in provider.touchDataStream {
                if Task.isCancelled { break }
                suppressor?.flag.withLockUnchecked { $0 = machine.isTracking }
                if let action = machine.consume(samples: samples) {
                    await MainActor.run {
                        onTrigger(action)
                    }
                }
            }
            suppressor?.flag.withLockUnchecked { $0 = false }
        }
        monitorTaskBox.withLockUnchecked { $0 = task }
    }

    func restart() {
        stop()
        start()
    }

    func stop() {
        monitorTaskBox.withLockUnchecked { $0?.cancel(); $0 = nil }
        _ = provider.stopListening()
        magnifySuppressor?.flag.withLockUnchecked { $0 = false }
    }
}
