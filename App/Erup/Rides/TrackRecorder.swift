import CoreLocation
import Foundation

@MainActor
final class TrackRecorder {
    private static let maximumAccuracyMeters = 30.0

    private var task: Task<Void, Never>?
    private var serviceSession: CLServiceSession?
    private var backgroundSession: CLBackgroundActivitySession?
    private var points: [TrackPoint] = []
    var onError: (@MainActor (String) -> Void)?

    func start() {
        guard task == nil else { return }
        points = []
        serviceSession = CLServiceSession(authorization: .whenInUse)
        backgroundSession = CLBackgroundActivitySession()
        task = Task {
            do {
                for try await update in CLLocationUpdate.liveUpdates(.otherNavigation) {
                    if update.authorizationDenied {
                        self.onError?("Location access is off, so this ride has no route. Allow it in Settings.")
                        return
                    }
                    guard let location = update.location,
                          location.horizontalAccuracy >= 0,
                          location.horizontalAccuracy <= Self.maximumAccuracyMeters else { continue }
                    self.points.append(TrackPoint(
                        latitude: location.coordinate.latitude,
                        longitude: location.coordinate.longitude,
                        timestamp: location.timestamp
                    ))
                }
            } catch is CancellationError {
                return
            } catch {
                self.onError?("Route recording stopped: \(error.localizedDescription)")
            }
        }
    }

    func stop() -> [TrackPoint] {
        task?.cancel()
        task = nil
        serviceSession?.invalidate()
        backgroundSession?.invalidate()
        serviceSession = nil
        backgroundSession = nil
        defer { points = [] }
        return points
    }
}
