//
//  AppGlideApp.swift
//  AppGlide
//
//  Created by Nicholas Hershy on 7/21/26.
//

import SwiftUI

@main
struct AppGlideApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("AppGlide", systemImage: "hand.draw") {
            MenuBarView()
        }
    }
}
