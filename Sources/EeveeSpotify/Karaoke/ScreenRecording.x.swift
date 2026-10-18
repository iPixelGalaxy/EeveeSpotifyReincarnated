import Orion
import UIKit

/// Only Spotify's view of capture status changes; iOS recording itself remains untouched.
class AllowScreenRecordingHook: ClassHook<UIScreen> {
    func isCaptured() -> Bool {
        ScreenRecordingPreference.enabled ? false : orig.isCaptured()
    }
}

private enum ScreenRecordingPreference {
    private static var allowed = UserDefaults.karaokeOptions.allowScreenRecording
    private static let observer = NotificationCenter.default.addObserver(
        forName: .eeveeKaraokeOptionsChanged, object: nil, queue: .main
    ) { _ in
        let updated = UserDefaults.karaokeOptions.allowScreenRecording
        guard updated != allowed else { return }
        allowed = updated
        NotificationCenter.default.post(name: UIScreen.capturedDidChangeNotification, object: UIScreen.main)
    }

    static var enabled: Bool {
        _ = observer
        return allowed
    }
}
