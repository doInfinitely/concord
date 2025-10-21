//
//  ConcordApp.swift
//  Concord
//
//  Created by Remy Ochei on 10/20/25.
//

import SwiftUI

@main
struct ConcordApp: App {
  @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

  var body: some Scene {
    WindowGroup { ContentView() }
  }
}

