//
//  AppDelegate.swift
//  Concord
//
//  Created by Remy Ochei on 10/21/25.
//

import UIKit
import FirebaseCore
import GoogleSignIn
import UserNotifications
import FirebaseMessaging

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Configure Firebase
        FirebaseApp.configure()
        
        if let o = FirebaseApp.app()?.options {
            print("projectID:", o.projectID ?? "nil")
        }
        
        // Set up notification delegates
        UNUserNotificationCenter.current().delegate = self
        Messaging.messaging().delegate = self
        
        return true
    }
    
    // Handle Google Sign-In URL
    // Suppress deprecation warning for iOS 26 (we're targeting iOS 17)
    @available(iOS, deprecated: 26.0, message: "Use UIScene lifecycle instead")
    func application(_ application: UIApplication,
                     open url: URL,
                     options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        return GIDSignIn.sharedInstance.handle(url)
    }
}

// MARK: - UNUserNotificationCenterDelegate
extension AppDelegate: UNUserNotificationCenterDelegate {
    // Called when app receives notification in foreground
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let userInfo = notification.request.content.userInfo
        
        print("Received notification in foreground:", userInfo)
        
        // Show notification even when app is in foreground
        completionHandler([.banner, .sound, .badge])
    }
    
    // Called when user taps on notification
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo
        
        print("User tapped notification:", userInfo)
        
        // Extract conversation ID and post notification to open it
        if let conversationId = userInfo["conversationId"] as? String {
            // Post notification after a small delay to ensure app is ready
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                NotificationCenter.default.post(
                    name: .openConversation,
                    object: nil,
                    userInfo: ["conversationId": conversationId]
                )
            }
        }
        
        completionHandler()
    }
}

// MARK: - MessagingDelegate
extension AppDelegate: MessagingDelegate {
    // Called when FCM token is refreshed
    func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        print("FCM Token refreshed: \(fcmToken ?? "nil")")
        
        // Store token in UserDefaults for access by NotificationService
        if let token = fcmToken {
            UserDefaults.standard.set(token, forKey: "fcmToken")
        }
        
        // Post notification so NotificationService can save it
        NotificationCenter.default.post(
            name: .fcmTokenRefreshed,
            object: nil,
            userInfo: ["token": fcmToken as Any]
        )
    }
}

// MARK: - Remote Notification Registration
extension AppDelegate {
    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        print("Registered for remote notifications")
        
        // Pass device token to Firebase Messaging
        Messaging.messaging().apnsToken = deviceToken
        
        // Convert to string for logging
        let tokenParts = deviceToken.map { data in String(format: "%02.2hhx", data) }
        let token = tokenParts.joined()
        print("Device Token: \(token)")
    }
    
    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("Failed to register for remote notifications: \(error.localizedDescription)")
    }
}

// MARK: - Notification Names Extension
extension Notification.Name {
    static let openConversation = Notification.Name("openConversation")
    static let fcmTokenRefreshed = Notification.Name("fcmTokenRefreshed")
}
