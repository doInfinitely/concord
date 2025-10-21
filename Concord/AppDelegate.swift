//
//  AppDelegate.swift
//  Concord
//
//  Created by Remy Ochei on 10/21/25.
//

import UIKit
import FirebaseCore

final class AppDelegate: NSObject, UIApplicationDelegate {
  func application(_ application: UIApplication,
                   didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
    FirebaseApp.configure()
    if let o = FirebaseApp.app()?.options { print("projectID:", o.projectID ?? "nil")
    }
    return true
  }
}
