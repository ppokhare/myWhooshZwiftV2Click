import AppKit
import SwiftUI

@main
struct ClickBridgeApp: App {
    @NSApplicationDelegateAdaptor(BridgeDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            BridgeMenu(click: delegate.click, server: delegate.server)
        } label: {
            BridgeStatusLabel(click: delegate.click, server: delegate.server)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class BridgeDelegate: NSObject, NSApplicationDelegate {
    let click = ClickConnection()
    let server = OpenBikeControlServer()

    func applicationDidFinishLaunching(_ notification: Notification) {
        click.onButton = { [server] button, down in server.send(button, down: down) }
        click.onReset = { [server] in server.releaseAll() }
        server.start()
        click.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        click.stop()
        server.stop()
    }
}

private struct BridgeStatusLabel: View {
    @ObservedObject var click: ClickConnection
    @ObservedObject var server: OpenBikeControlServer

    var body: some View {
        BridgeIndicator(clickReady: click.ready, clientConnected: server.connectedClients > 0)
    }
}

private struct BridgeMenu: View {
    @ObservedObject var click: ClickConnection
    @ObservedObject var server: OpenBikeControlServer
    @FocusState private var quitFocused: Bool

    var body: some View {
        let myWhooshConnected = server.connectedClients > 0
        let ready = click.ready && myWhooshConnected

        VStack(alignment: .leading, spacing: 12) {
            statusRow("Click V2", detail: click.status,
                      icon: "dot.radiowaves.left.and.right",
                      connected: click.ready, ready: ready)
            statusRow("MyWhoosh", detail: myWhooshConnected ? "Connected" : server.status, icon: "link", connected: myWhooshConnected, ready: ready)
            if let keepAwakeStatus = click.keepAwakeStatus {
                statusRow("Experimental keep-awake", detail: keepAwakeStatus.rawValue,
                          icon: "moon", connected: keepAwakeStatus == .active, ready: ready)
            }
            if !server.running {
                Button("Retry connection") { server.start() }
            }
            VStack(alignment: .leading, spacing: 5) {
                Divider()
                quitButton
            }
        }
        .padding(12)
        .frame(width: 208)
    }

    @ViewBuilder
    private var quitButton: some View {
        let button = Button {
            NSApp.terminate(nil)
        } label: {
            Text("Quit Click Bridge")
                .font(.callout)
                .foregroundStyle(quitFocused ? Color.primary : Color.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focused($quitFocused)
        .help("⌘Q")
        .keyboardShortcut("q")

        if #available(macOS 14, *) {
            button.focusEffectDisabled()
        } else {
            button
        }
    }

    private func statusRow(_ title: String, detail: String, icon: String, connected: Bool, ready: Bool) -> some View {
        HStack(spacing: 9) {
            Image(systemName: connected ? "checkmark.circle.fill" : icon)
                .foregroundStyle(ready ? Color.primary : Color.gray)
                .frame(width: 21)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .fontWeight(.medium)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
