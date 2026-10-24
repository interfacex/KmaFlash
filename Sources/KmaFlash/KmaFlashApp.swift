import SwiftUI
import AppKit
import FlashCore

@main
struct KmaFlashApp: App {
    @StateObject private var model = AppModel()
    var body: some Scene {
        WindowGroup("同页") {
            RootView().environmentObject(model).frame(minWidth: 1060, minHeight: 720)
                .onAppear { NSApplication.shared.setActivationPolicy(.regular); NSApplication.shared.activate(ignoringOtherApps: true) }
        }
        .defaultSize(width: 1380, height: 900)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("导入阅读材料") { model.showImport = true }.keyboardShortcut("n")
                Button("从文件导入") { model.importFiles() }.keyboardShortcut("o")
            }
            CommandGroup(replacing: .appSettings) { Button("模型设置…") { model.showSettings = true }.keyboardShortcut(",") }
        }
    }
}
