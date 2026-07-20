import Foundation

enum ProviderRequestGateMode: Sendable {
    case disabled
    case enabled(ProviderRequestPolicies)

    static let enabledDefaultsKey = "network.providerRequestGate.enabled"

    static func production(defaults: UserDefaults) -> ProviderRequestGateMode {
        if defaults.object(forKey: enabledDefaultsKey) != nil,
           !defaults.bool(forKey: enabledDefaultsKey) {
            return .disabled
        }
        return .enabled(.production)
    }
}

enum ProviderHTTPClientPipeline {
    static func make(
        transport: any HTTPClient,
        mode: ProviderRequestGateMode,
        refreshMetricsRecorder: RefreshMetricsRecorder,
        refreshObservationClock: RefreshObservationClock = .live,
        providerRequestClock: ProviderRequestClock = .live,
        providerRequestRandomness: ProviderRequestRandomness = .live
    ) -> any HTTPClient {
        let observedClient = ObservedHTTPClient(
            base: transport,
            recorder: refreshMetricsRecorder,
            clock: refreshObservationClock
        )
        guard case .enabled(let policies) = mode else {
            return observedClient
        }
        return ProviderRequestGate(
            base: observedClient,
            policies: policies,
            clock: providerRequestClock,
            randomness: providerRequestRandomness,
            cancellationObserver: {
                guard let runID = RefreshObservationScope.runID else { return }
                await refreshMetricsRecorder.recordCancellation(runID: runID)
            }
        )
    }
}
