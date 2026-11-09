import SwiftUI
import AppKit

@main
struct TzoneConfigApp: App {
    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    var body: some Scene {
        WindowGroup("Tzone Configuration Tool") {
            ContentView().fixedSize()
        }
    }
}

final class ViewModel: ObservableObject {
    @Published var model = ""
    @Published var firmware = ""
    @Published var deviceID = ""
    @Published var deviceTime = ""
    @Published var ssid = ""
    @Published var wifiPassword = ""
    @Published var status = "Plug in the logger and press Read."
    @Published var busy = false
    @Published var canSave = false
    @Published var errorMessage: String?

    private func timeString(_ d: Date?) -> String {
        guard let d = d else { return "" }
        let f = DateFormatter(); f.dateFormat = "yyyy/MM/dd HH:mm:ss"
        return f.string(from: d)
    }

    private func background(_ work: @escaping () throws -> Void, done: @escaping () -> Void) {
        busy = true
        DispatchQueue.global(qos: .userInitiated).async {
            var failure: String?
            do { try work() } catch { failure = error.localizedDescription }
            DispatchQueue.main.async {
                self.busy = false
                if let failure = failure { self.errorMessage = failure; self.status = "Failed." } else { done() }
            }
        }
    }

    func read() {
        status = "Reading device…"
        canSave = false
        var info = DeviceInfo(); var cfg: WifiConfig?
        background({
            let link = try ScsiLink()
            defer { link.close() }
            let s = LoggerSession(link: link)
            info = try s.info()
            if info.isWifiModel { cfg = try s.wifiConfig() }
        }, done: {
            self.model = info.hardware; self.firmware = info.firmware; self.deviceID = info.deviceID
            if let c = cfg {
                self.deviceTime = self.timeString(c.deviceTimeUTC)
                self.ssid = c.ssid; self.wifiPassword = c.password
                self.canSave = true
                self.status = "Read OK."
            } else {
                self.deviceTime = ""; self.ssid = ""; self.wifiPassword = ""
                self.status = "Device read OK. WiFi settings are only available for WF501/WF502 models."
            }
        })
    }

    func save() {
        status = "Writing device…"
        let name = ssid.trimmingCharacters(in: .whitespaces), pw = wifiPassword.trimmingCharacters(in: .whitespaces)
        var cfg: WifiConfig?
        background({
            let link = try ScsiLink()
            defer { link.close() }
            let s = LoggerSession(link: link)
            try s.saveWifi(ssid: name, password: pw)
            cfg = try s.wifiConfig()
        }, done: {
            if let c = cfg { self.deviceTime = self.timeString(c.deviceTimeUTC); self.ssid = c.ssid; self.wifiPassword = c.password }
            self.status = "Saved. The device clock was set to the current time."
        })
    }

    func copyID() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(deviceID, forType: .string)
        status = "ID copied to clipboard."
    }
}

struct ContentView: View {
    @StateObject private var vm = ViewModel()

    private func row(_ label: String, _ value: Binding<String>, editable: Bool = false) -> some View {
        HStack {
            Text(label).frame(width: 100, alignment: .trailing)
            TextField("", text: value).textFieldStyle(.roundedBorder).disabled(!editable).frame(width: 280)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            row("Model", $vm.model)
            row("Firmware", $vm.firmware)
            HStack {
                row("Device ID", $vm.deviceID)
                Button("Copy ID") { vm.copyID() }.disabled(vm.deviceID.isEmpty)
            }
            row("Device time", $vm.deviceTime)
            Divider()
            row("WiFi name", $vm.ssid, editable: vm.canSave)
            row("WiFi password", $vm.wifiPassword, editable: vm.canSave)
            HStack {
                if vm.busy { ProgressView().controlSize(.small) }
                Text(vm.status).font(.callout).foregroundColor(.secondary).frame(maxWidth: 260, alignment: .leading)
                Spacer()
                Button("Read") { vm.read() }.disabled(vm.busy)
                Button("Save") { vm.save() }.disabled(vm.busy || !vm.canSave)
            }
        }
        .padding(20)
        .alert("Something went wrong", isPresented: Binding(get: { vm.errorMessage != nil },
                                                           set: { if !$0 { vm.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(vm.errorMessage ?? "") }
    }
}
