import Foundation
import OSLog

actor HeadlessRefreshObservationRecorder {
    typealias LogHandler = @Sendable (_ message: String) -> Void

    private var snapshot: HeadlessRefreshSnapshot
    private var updateContinuations: [
        UUID: AsyncStream<HeadlessRefreshSnapshot>.Continuation
    ] = [:]
    private let log: LogHandler

    init(
        initialSnapshot: HeadlessRefreshSnapshot = .empty,
        log: @escaping LogHandler = { message in
            OpenASOLog.refresh.info("\(message, privacy: .public)")
        }
    ) {
        self.snapshot = initialSnapshot
        self.log = log
    }

    func record(_ observation: HeadlessRefreshObservation) {
        snapshot = observation.snapshot
        if let message = observation.event.redactedLogMessage {
            log(message)
        }
        var terminatedSubscriberIDs: [UUID] = []
        for (subscriberID, continuation) in updateContinuations {
            if case .terminated = continuation.yield(observation.snapshot) {
                terminatedSubscriberIDs.append(subscriberID)
            }
        }
        for subscriberID in terminatedSubscriberIDs {
            updateContinuations[subscriberID] = nil
        }
    }

    func updates() -> AsyncStream<HeadlessRefreshSnapshot> {
        let subscriberID = UUID()
        let (stream, continuation) = AsyncStream<HeadlessRefreshSnapshot>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        continuation.onTermination = { @Sendable [weak self] _ in
            Task { [weak self] in
                await self?.removeSubscriber(id: subscriberID)
            }
        }
        updateContinuations[subscriberID] = continuation
        continuation.yield(snapshot)
        return stream
    }

    func currentSnapshot() -> HeadlessRefreshSnapshot {
        snapshot
    }

    func subscriberCount() -> Int {
        updateContinuations.count
    }

    private func removeSubscriber(id: UUID) {
        updateContinuations[id] = nil
    }
}
