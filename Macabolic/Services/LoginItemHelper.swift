import Foundation
import ServiceManagement

@MainActor
class LoginItemHelper {
    static let shared = LoginItemHelper()
    
    private init() {}
    
    var isEnabled: Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        } else {
            // Fallback for older macOS versions if needed, but SMAppService is preferred for 13+
            // For 12.0 we would normally use SMLoginItemSetEnabled which is deprecated
            return UserDefaults.standard.bool(forKey: "launchAtLogin")
        }
    }
    
    func setEnabled(_ enabled: Bool) {
        if #available(macOS 13.0, *) {
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                print("Failed to update login item status: \(error.localizedDescription)")
            }
        }
        
        UserDefaults.standard.set(enabled, forKey: "launchAtLogin")
    }
}
