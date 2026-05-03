import LaunchNextCore
import Foundation

public struct GestureConfiguration: Equatable {
    public var isEnabled: Bool
    public var closeOnPinchOutEnabled: Bool = false
    public var tapEnabled: Bool = false
    public var tapTogglesWindow: Bool = false
    public var requiredFingerCount: Int = 4
    public var stableContactDuration: TimeInterval = 0.015
    public var openTriggerScaleRatio: Double = 0.84
    public var closeTriggerScaleRatio: Double = 1.10
    public var openPerFingerRadiusRatio: Double = 0.96
    public var closeLeadingFingerRadiusRatio: Double = 1.04
    public var minimumOpenParticipatingFingerCount: Int = 3
    public var minimumCloseLeadingGap: Double = 0.02
    public var maximumCloseSupportingSpread: Double = 0.30
    public var requiredConsecutiveMatches: Int = 1
    public var cooldownDuration: TimeInterval = 0.5
    public var maximumCentroidDriftRatio: Double = 0.55
    public var minimumBaselineScale: Double = 0.10
    public var tapMaxDuration: TimeInterval = 0.20
    public var tapMaxFingerMovement: Double = 0.045
    public var tapMaxScaleDeviation: Double = 0.10

    public init(
        isEnabled: Bool = true,
        closeOnPinchOutEnabled: Bool = false,
        tapEnabled: Bool = false,
        tapTogglesWindow: Bool = false,
        requiredFingerCount: Int = 4,
        stableContactDuration: TimeInterval = 0.015,
        openTriggerScaleRatio: Double = 0.84,
        closeTriggerScaleRatio: Double = 1.10,
        openPerFingerRadiusRatio: Double = 0.96,
        closeLeadingFingerRadiusRatio: Double = 1.04,
        minimumOpenParticipatingFingerCount: Int = 3,
        minimumCloseLeadingGap: Double = 0.02,
        maximumCloseSupportingSpread: Double = 0.30,
        requiredConsecutiveMatches: Int = 1,
        cooldownDuration: TimeInterval = 0.5,
        maximumCentroidDriftRatio: Double = 0.55,
        minimumBaselineScale: Double = 0.10,
        tapMaxDuration: TimeInterval = 0.20,
        tapMaxFingerMovement: Double = 0.045,
        tapMaxScaleDeviation: Double = 0.10
    ) {
        self.isEnabled = isEnabled
        self.closeOnPinchOutEnabled = closeOnPinchOutEnabled
        self.tapEnabled = tapEnabled
        self.tapTogglesWindow = tapTogglesWindow
        self.requiredFingerCount = requiredFingerCount
        self.stableContactDuration = stableContactDuration
        self.openTriggerScaleRatio = openTriggerScaleRatio
        self.closeTriggerScaleRatio = closeTriggerScaleRatio
        self.openPerFingerRadiusRatio = openPerFingerRadiusRatio
        self.closeLeadingFingerRadiusRatio = closeLeadingFingerRadiusRatio
        self.minimumOpenParticipatingFingerCount = minimumOpenParticipatingFingerCount
        self.minimumCloseLeadingGap = minimumCloseLeadingGap
        self.maximumCloseSupportingSpread = maximumCloseSupportingSpread
        self.requiredConsecutiveMatches = requiredConsecutiveMatches
        self.cooldownDuration = cooldownDuration
        self.maximumCentroidDriftRatio = maximumCentroidDriftRatio
        self.minimumBaselineScale = minimumBaselineScale
        self.tapMaxDuration = tapMaxDuration
        self.tapMaxFingerMovement = tapMaxFingerMovement
        self.tapMaxScaleDeviation = tapMaxScaleDeviation
    }
}
