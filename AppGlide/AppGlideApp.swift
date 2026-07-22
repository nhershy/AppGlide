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
        MenuBarExtra {
            MenuBarView()
        } label: {
            // Template glyph of the app-icon hand and motion streaks
            // (design/menubar-icon.svg); 16x18 pt.
            Image("MenuBarIcon")
        }
    }
}
