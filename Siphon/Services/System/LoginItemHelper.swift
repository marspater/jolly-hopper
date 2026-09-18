import Foundation
import ServiceManagement

@MainActor
class LoginItemHelper {
    static let shared = LoginItemHelper()
    
    private init() {
        // Private initializer for singleton instance
    }
    
    var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }
    
    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            LoggerService.shared.log("Failed to update login item status: \(error.localizedDescription)", level: .error)
        }
        
        UserDefaults.standard.set(enabled, forKey: UserDefaultsKeys.launchAtLogin)
    }
}
