import AppKit
import SwiftUI
import TidyCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    var window: NSWindow!
    var statusItem: NSStatusItem!
    var model: AppModel!
    var demoRoot: URL?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--demo"), args.count > i + 1 { demoRoot = URL(fileURLWithPath: args[i + 1]) }
        model = AppModel(root: demoRoot, storage: demoRoot?.appendingPathComponent(".tidy-test-state"))
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1190, height: 800), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = demoRoot == nil ? "다운정리" : "다운정리 · 테스트 폴더"
        window.minSize = NSSize(width: 1020, height: 720)
        window.contentView = NSHostingView(rootView: MainView(model: model))
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.center()
        if demoRoot == nil { window.setFrameAutosaveName("DownloadTidyMain") }
        createMenus()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func createMenus() {
        let menu = NSMenu()
        let app = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "다운정리 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        app.submenu = appMenu; menu.addItem(app)
        let edit = NSMenuItem(title: "편집", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "편집")
        for (title, action, key) in [("잘라내기", "cut:", "x"), ("복사", "copy:", "c"), ("붙여넣기", "paste:", "v"), ("모두 선택", "selectAll:", "a")] {
            editMenu.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        edit.submenu = editMenu; menu.addItem(edit)
        NSApp.mainMenu = menu
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "tray.and.arrow.down", accessibilityDescription: "다운정리")
        let statusMenu = NSMenu(); statusMenu.delegate = self; statusItem.menu = statusMenu
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let show = menu.addItem(withTitle: "다운정리 열기", action: #selector(showMain), keyEquivalent: "")
        show.target = self
        menu.addItem(.separator())
        let title = menu.addItem(withTitle: "최근 추가한 파일", action: nil, keyEquivalent: ""); title.isEnabled = false
        for entry in model.entries.filter({ $0.kind != .folder }).prefix(8) {
            let item = menu.addItem(withTitle: entry.name, action: #selector(openRecent(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = entry.url
            let icon = NSWorkspace.shared.icon(forFile: entry.url.path); icon.size = NSSize(width: 16, height: 16); item.image = icon
            item.toolTip = entry.url.path
        }
        menu.addItem(.separator())
        let history = menu.addItem(withTitle: "정리 기록 보기", action: #selector(showHistory), keyEquivalent: ""); history.target = self
        menu.addItem(withTitle: "종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }
    @objc func showMain() { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    @objc func showHistory() { showMain(); model.showHistory = true }
    @objc func openRecent(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        if !NSWorkspace.shared.open(url) { showMain(); model.error = "파일을 열 수 없습니다. 새로고침 후 다시 확인해 주세요." }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showMain(); return true }
}
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
