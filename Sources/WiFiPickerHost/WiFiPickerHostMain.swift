import AppKit
import ServiceManagement

@main
@MainActor
struct WiFiPickerHostMain {
    static func main() {
        if CommandLine.arguments.contains("--login-item-status") {
            switch SMAppService.mainApp.status {
            case .enabled: print("enabled")
            case .notRegistered: print("not-registered")
            case .requiresApproval: print("requires-approval")
            case .notFound: print("not-found")
            @unknown default: print("unknown")
            }
            return
        }
        if CommandLine.arguments.contains("--unregister-login-item") {
            let service = SMAppService.mainApp
            switch service.status {
            case .notRegistered, .notFound:
                print("not-registered")
            case .enabled, .requiresApproval:
                do {
                    try service.unregister()
                    print("unregistered")
                } catch {
                    fputs("Could not unregister the main-app login item: \(error)\n", stderr)
                    exit(1)
                }
            @unknown default:
                do {
                    try service.unregister()
                    print("unregistered")
                } catch {
                    fputs("Could not unregister an unknown main-app login item state: \(error)\n", stderr)
                    exit(1)
                }
            }
            return
        }
        let launchedByFallbackAgent = CommandLine.arguments.contains("--login-launch")
        guard let instanceLock = ProcessSingleInstanceLock.acquire(
            waitForAvailability: launchedByFallbackAgent
        ) else {
            return
        }
        let application = NSApplication.shared
        let delegate = AppDelegate(
            launchedByFallbackAgent: launchedByFallbackAgent
        )
        application.delegate = delegate
        withExtendedLifetime(instanceLock) {
            application.run()
        }
    }
}
