// ============================================================
// AirliftService.swift — Bypassicl
// FULL FIX: continuous on-device pairing for StikPair / iOS 27
//
// Fixes:
//   • Background suspension of the Rust TCP accept loop
//   • PIN arrives before Settings connects (pre-staged)
//   • Bonjour TXT record carries pairing metadata
//   • Local Network re-prompt on foreground
//   • Manual fallback: Import Pairing File (PC-generated)
// ============================================================

import Foundation
import Combine
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

    // ============================================================
    // BACKGROUND SURVIVAL STATE
    // ============================================================
    private var localNetBrowser: NWBrowser?
    private var audioPlayer: AVAudioPlayer?
    private var bonjourPublisher: NetService?
    private var publishedServiceId: String = "Bypassicl"
    private var publishedPort: Int32 = 0
    private var watchdogTimer: Timer?
    private var backgroundTaskId: UIBackgroundTaskIdentifier = .invalid
    private var pairingHostActive = false
    private var preStagedPin: String? = nil   // PIN known before Settings connects

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

    private func log(_ message: String) {
        DispatchQueue.main.async {
            self.logs += message + "\n"
            print(message)
        }
    }

    // ============================================================
    // FFI CALLBACKS (PIN pre-staged)
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
        // PRE-STAGE: cache the PIN immediately so UI can show it even
        // if the app gets backgrounded before Settings connects.
        service.preStagedPin = pinStr
        DispatchQueue.main.async {
            service.currentPin = pinStr
            service.log("🔐 PIN READY: \(pinStr)")
            service.showPinNotification(pinStr)
        }
    }

    private static let readyCallback: ALPairReadyCb = { ctx, serviceId, port, _, _, _ in
        guard let ctx = ctx else { return }
        let service = Unmanaged<AirliftService>.fromOpaque(ctx).takeUnretainedValue()
        let sid = serviceId != nil ? String(cString: serviceId!) : "Bypassicl"
        let netPort = Int32(port)
        service.log("📡 Host ready: \(sid) : \(netPort)")
        DispatchQueue.main.async {
            service.startContinuousBonjourAdvertisement(serviceId: sid, port: netPort)
        }
    }

    // ============================================================
    // CONTINUOUS BONJOUR — WITH PIN IN TXT RECORD
    // ============================================================
    func startContinuousBonjourAdvertisement(serviceId: String, port: Int32) {
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
        // Carry the pre-staged PIN so the host can verify immediately.
        // Some iOS 27 builds read this during the Settings handshake.
        if let pin = preStagedPin {
            svc.setTXTRecord(NetService.data(fromTXTRecord: [
                "pin": pin.data(using: .utf8)!,
                "version": "1.0".data(using: .utf8)!,
                "host": "Bypassicl".data(using: .utf8)!
            ]))
        }

        svc.includesPeerToPeer = true
        svc.delegate = self
        svc.schedule(in: .main, forMode: .common)
        svc.publish()

        bonjourPublisher = svc
        log("🔊 Bonjour publishing: \(serviceId) @ \(port)")
        startBonjourWatchdog()
    }

    private func stopBonjourPublisherOnly() {
        watchdogTimer?.invalidate(); watchdogTimer = nil
        bonjourPublisher?.stop(); bonjourPublisher = nil
    }

    func stopContinuousBonjourAdvertisement() {
        stopBonjourPublisherOnly()
        log("🔇 Bonjour advertisement stopped")
    }

    private func startBonjourWatchdog() {
        watchdogTimer?.invalidate()
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            guard let self = self, self.pairingHostActive else { return }
            if self.bonjourPublisher == nil {
                self.log("🔄 Watchdog: republishing Bonjour")
                self.startContinuousBonjourAdvertisement(
                    serviceId: self.publishedServiceId,
                    port: self.publishedPort
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
                port: self.publishedPort
            )
        }
    }
    func netServiceDidStop(_ sender: NetService) {
        log("⏹ Bonjour stopped")
        if bonjourPublisher === sender { bonjourPublisher = nil }
    }

    // ============================================================
    // BACKGROUND SURVIVAL — TRIO LOCK
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
                port: publishedPort
            )
        }
        beginBackgroundTask()
        // Re-surface the PIN if it was pre-staged
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
    // PIN NOTIFICATION (Live Activity / Banner)
    // ============================================================
    private func showPinNotification(_ pin: String) {
        let content = UNMutableNotificationContent()
        content.title = "Pairing PIN Ready"
        content.body = "Enter \(pin) in Settings → Developer Mode → Pair with StikPair"
        content.sound = .defaultCritical
        let req = UNNotificationRequest(
            identifier: "pair-pin-\(pin)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(req) { [weak self] err in
            if let err = err {
                self?.log("⚠️ PIN notification failed: \(err.localizedDescription)")
            }
        }
    }

    // ============================================================
    // PAIR ON DEVICE — ENTRY POINT
    // ============================================================
    func startPairingOnDevice() {
        guard !isPairing else { return }
        isPairing = true
        currentPin = nil
        preStagedPin = nil
        pairingHostActive = true
        log("[*] Starting Pair on Device...")
        log("👉 Enable Background Activity in this app before leaving!")

        try? FileManager.default.createDirectory(at: documentsDir, withIntermediateDirectories: true)
        let outPath = documentsDir.appendingPathComponent("pairingRecord.mobiledevicepairing").path
        let ctx = Unmanaged.passUnretained(self).toOpaque()

        DispatchQueue.main.async {
            self.startKeepAliveAudio()
            self.beginBackgroundTask()
            self.triggerLocalNetworkPrompt()
            self.requestNotificationPermission()
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

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            if !granted { self.log("⚠️ Notifications denied — PIN may not surface") }
        }
    }

    // ============================================================
    // LOCAL NETWORK PERMISSION HOLD
    // ============================================================
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
    // AUDIO KEEP-ALIVE
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
    // FALLBACK: IMPORT PAIRING FILE (PC-generated)
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
}