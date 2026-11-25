import AppKit
@preconcurrency import CoreLocation
import Foundation

public enum WiFiLocationState: Equatable, Sendable {
    case servicesDisabled
    case notDetermined
    case denied
    case authorized
}

@MainActor
public protocol WiFiLocationProviding: AnyObject {
    var onChange: (@MainActor (WiFiLocationState) -> Void)? { get set }
    var state: WiFiLocationState { get }
    func request()
}

/// `state` is a cache filled by the authorization callback. A refresh must never ask
/// locationd synchronously: when it hangs, a main-thread query freezes the whole app.
@MainActor
public final class WiFiLocationPermission: NSObject, WiFiLocationProviding, @preconcurrency CLLocationManagerDelegate {
    public var onChange: (@MainActor (WiFiLocationState) -> Void)?
    public private(set) var state: WiFiLocationState = .notDetermined

    private let manager: CLLocationManager

    public override init() {
        manager = CLLocationManager()
        super.init()
        manager.delegate = self
    }

    public func request() {
        // An LSUIElement app that is not active may never get the system prompt on screen.
        NSApp.activate(ignoringOtherApps: true)
        manager.requestWhenInUseAuthorization()
        // A menu-bar app that only asks may get no prompt and never appear in the Location
        // Services list. Starting updates makes macOS ask; the callback stops it again.
        manager.startUpdatingLocation()
    }

    public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        if status != .notDetermined { manager.stopUpdatingLocation() }
        Task.detached(priority: .utility) { [weak self] in
            // Apple warns this one can block; it stays off the main thread.
            let servicesEnabled = CLLocationManager.locationServicesEnabled()
            await self?.apply(status: status, servicesEnabled: servicesEnabled)
        }
    }

    private func apply(status: CLAuthorizationStatus, servicesEnabled: Bool) {
        state = Self.state(status: status, servicesEnabled: servicesEnabled)
        onChange?(state)
    }

    private static func state(status: CLAuthorizationStatus, servicesEnabled: Bool) -> WiFiLocationState {
        guard servicesEnabled else { return .servicesDisabled }
        switch status {
        case .notDetermined: return .notDetermined
        case .authorized, .authorizedAlways: return .authorized
        case .denied, .restricted: return .denied
        @unknown default: return .denied
        }
    }
}
