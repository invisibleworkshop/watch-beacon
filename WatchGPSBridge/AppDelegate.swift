import UIKit

/// Process-level delegate only (matches LedgerApp). UI is owned by SwiftUI `WindowGroup`.
final class AppDelegate: NSObject, UIApplicationDelegate {
    private static var sceneConnectOrder: [String] = []

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        NotificationCenter.default.addObserver(
            forName: UIScene.didActivateNotification,
            object: nil,
            queue: .main
        ) { _ in
            Self.collapseExtraScenes()
        }
        NotificationCenter.default.addObserver(
            forName: UIScene.willConnectNotification,
            object: nil,
            queue: .main
        ) { note in
            guard let scene = note.object as? UIWindowScene else { return }
            let id = scene.session.persistentIdentifier
            if !Self.sceneConnectOrder.contains(id) {
                Self.sceneConnectOrder.append(id)
            }
            Self.collapseExtraScenes()
        }
        NotificationCenter.default.addObserver(
            forName: UIScene.didDisconnectNotification,
            object: nil,
            queue: .main
        ) { note in
            guard let scene = note.object as? UIWindowScene else { return }
            Self.sceneConnectOrder.removeAll { $0 == scene.session.persistentIdentifier }
        }

        if let url = launchOptions?[.url] as? URL {
            URLRouter.handle(url)
        }
        return true
    }

    func application(
        _ app: UIApplication,
        open url: URL,
        options: [UIApplication.OpenURLOptionsKey: Any] = [:]
    ) -> Bool {
        URLRouter.handle(url)
        return true
    }

    /// Belt-and-suspenders: if Shortcuts still creates a 2nd scene, drop the newer one.
    static func collapseExtraScenes() {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.session.role == .windowApplication }
        guard scenes.count > 1 else { return }

        let primary = scenes.min { a, b in
            let ia = sceneConnectOrder.firstIndex(of: a.session.persistentIdentifier) ?? .max
            let ib = sceneConnectOrder.firstIndex(of: b.session.persistentIdentifier) ?? .max
            return ia < ib
        } ?? scenes[0]

        for scene in scenes where scene.session.persistentIdentifier != primary.session.persistentIdentifier {
            UIApplication.shared.requestSceneSessionDestruction(scene.session, options: nil)
        }
        UIApplication.shared.requestSceneSessionActivation(
            primary.session,
            userActivity: nil,
            options: nil
        )
    }
}
