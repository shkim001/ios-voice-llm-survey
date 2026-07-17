import UIKit

class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        // Ensure the scene is a UIWindowScene
        guard let windowScene = (scene as? UIWindowScene) else { return }
        
        // Create the application window
        window = UIWindow(windowScene: windowScene)
        
        // Instantiate the main view controller
        let storyboard = UIStoryboard(name: "Main", bundle: nil)
        let viewController = storyboard.instantiateInitialViewController()
        
        // Wrap in navigation controller to show navigation bar with settings button
        let navigationController = UINavigationController(rootViewController: viewController!)
        
        // Assign the root view controller
        window?.rootViewController = navigationController
        window?.makeKeyAndVisible()
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        // Called when the scene disconnects
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        // Recording and location services start only from explicit foreground UI actions.
    }

    func sceneWillResignActive(_ scene: UIScene) {
        // Called when the scene is about to become inactive
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        // Called as the scene transitions to the foreground
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        // No background execution mode is requested by this release.
    }
}
