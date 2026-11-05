import CoreLocation

/// One-shot "where am I" via CoreLocation (city-level accuracy is enough for prayer times).
@MainActor
final class LocationFinder: NSObject, CLLocationManagerDelegate {
    enum Failure: LocalizedError {
        case denied, timeout, other(String)
        var errorDescription: String? {
            switch self {
            case .denied: "Нет доступа к геолокации"
            case .timeout: "Не удалось определить место"
            case .other(let s): s
            }
        }
    }

    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocation, Error>?
    private var timeoutTask: Task<Void, Never>?

    func locate() async throws -> CLLocation {
        if let c = continuation { c.resume(throwing: Failure.other("Отменено")); continuation = nil }
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
        return try await withCheckedThrowingContinuation { c in
            continuation = c
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(20))
                guard !Task.isCancelled else { return }
                self?.finish(.failure(Failure.timeout))
            }
            proceed()
        }
    }

    private func proceed() {
        guard continuation != nil else { return }
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .denied, .restricted: finish(.failure(Failure.denied))
        default: manager.requestLocation()
        }
    }

    private func finish(_ r: Result<CLLocation, Error>) {
        timeoutTask?.cancel()
        guard let c = continuation else { return }
        continuation = nil
        c.resume(with: r)
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated { proceed() }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        MainActor.assumeIsolated { finish(.success(loc)) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let denied = (error as? CLError)?.code == .denied
        MainActor.assumeIsolated {
            // kCLErrorLocationUnknown is transient; CoreLocation keeps trying.
            if (error as? CLError)?.code == .locationUnknown { return }
            finish(.failure(denied ? Failure.denied : Failure.other(error.localizedDescription)))
        }
    }
}
