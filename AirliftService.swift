import Foundation
import Combine

class AirliftService: ObservableObject {
    static let shared = AirliftService()
    
    @Published var logs: String = "=== Bypassicl Log ===\n"
    
    private let accountsDir = "/var/mobile/Library/Accounts"
    private let targetFiles = ["Accounts3.sqlite", "Accounts3.sqlite-shm", "Accounts3.sqlite-wal"]
    
    var backupDir: URL {
        let docDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docDir.appendingPathComponent("AccountsBackup")
    }
    
    // Hàm log ra UI
    private func log(_ message: String) {
        DispatchQueue.main.async {
            self.logs += message + "\n"
            print(message)
        }
    }
    
    // MARK: - Khởi tạo kết nối (Pairing + Grappa + Airlift)
    
    func connect() -> Bool {
        log("[*] Đang khởi tạo kết nối Airlift...")
        
        // 1. Lấy Grappa Token
        guard let grappaToken = generateGrappaToken() else {
            log("❌ Lỗi: Không thể tạo Grappa Token.")
            return false
        }
        log("✅ Đã tạo Grappa Token (\(grappaToken.count) bytes)")
        
        // 2. Đọc file Pairing (Yêu cầu bạn copy file pairingRecord.mobiledevicepairing vào thư mục Documents của app qua iTunes/Files)
        guard let pairingData = loadPairingFile() else {
            log("❌ Lỗi: Không tìm thấy file Pairing trong Documents.")
            log("👉 Hãy copy file pairingRecord.mobiledevicepairing vào thư mục Documents của app.")
            return false
        }
        log("✅ Đã tìm thấy Pairing file (\(pairingData.count) bytes)")
        
        // 3. Gọi AirliftFFI để Init (TÊN HÀM CẦN SỬA THEO HEADER THỰC TẾ CỦA BẠN)
        // Giả định AirliftFFI có hàm: al_init(grappa_ptr, grappa_len, pairing_ptr, pairing_len)
        let initResult = grappaToken.withUnsafeBytes { gPtr -> Int32 in
            pairingData.withUnsafeBytes { pPtr -> Int32 in
                // SỬA al_init THÀNH HÀM THỰC TẾ TRONG AirliftFFI.h
                // Ví dụ: al_start_airlift(...) hoặc al_connect(...)
                return al_init(
                    gPtr.baseAddress?.assumingMemoryBound(to: UInt8.self), grappaToken.count,
                    pPtr.baseAddress?.assumingMemoryBound(to: UInt8.self), pairingData.count
                )
            }
        }
        
        if initResult == 0 {
            log("✅ Kết nối Airlift thành công (qua LocalDevVPN).")
            return true
        } else {
            log("❌ Lỗi khởi tạo Airlift (Code: \(initResult))")
            return false
        }
    }
    
    private func generateGrappaToken() -> Data? {
        let maxLen = 1024
        var buffer = [UInt8](repeating: 0, count: maxLen)
        var outLen = 0
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
    
    private func loadPairingFile() -> Data? {
        let docDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let possiblePaths = [
            docDir.appendingPathComponent("pairingRecord.mobiledevicepairing"),
            docDir.appendingPathComponent("pairingRecord.plist")
        ]
        
        for path in possiblePaths {
            if let data = try? Data(contentsOf: path) {
                return data
            }
        }
        return nil
    }
    
    // MARK: - FFI Wrappers (File Operations)
    // BẠN CẦN ĐỐI CHIẾU TÊN HÀM VỚI FILE AirliftFFI.h THỰC TẾ
    
    private func ffi_read_file(_ path: String) -> Data? {
        var outBuffer: UnsafeMutablePointer<UInt8>? = nil
        var outLength: Int = 0
        let result = al_read_file(path, &outBuffer, &outLength)
        guard result == 0, let buffer = outBuffer else { return nil }
        defer { al_free_buffer(buffer) }
        return Data(bytes: buffer, count: outLength)
    }
    
    private func ffi_delete_file(_ path: String) -> Bool {
        return al_delete_file(path) == 0
    }
    
    // MARK: - Nghiệp vụ
    
    func backupAccounts() -> Bool {
        log("[*] Bắt đầu Backup...")
        let fm = FileManager.default
        if fm.fileExists(atPath: backupDir.appendingPathComponent(targetFiles[0]).path) {
            log("✅ Bản backup đã tồn tại. Bỏ qua.")
            return true
        }
        
        try? fm.createDirectory(at: backupDir, withIntermediateDirectories: true)
        var success = true
        
        for file in targetFiles {
            let fullPath = "\(accountsDir)/\(file)"
            guard let data = ffi_read_file(fullPath) else {
                log("❌ Không thể đọc \(file) từ hệ thống.")
                success = false
                continue
            }
            do {
                try data.write(to: backupDir.appendingPathComponent(file))
                log("✅ Đã backup: \(file) (\(data.count) bytes)")
            } catch {
                log("❌ Lỗi ghi backup: \(error.localizedDescription)")
                success = false
            }
        }
        return success
    }
    
    func bypassICloud() {
        log("[*] Bắt đầu Bypass iCloud...")
        guard backupAccounts() else {
            log("❌ HỦY: Backup thất bại, không thể xóa an toàn.")
            return
        }
        
        var successCount = 0
        for file in targetFiles {
            let fullPath = "\(accountsDir)/\(file)"
            if ffi_delete_file(fullPath) {
                log("🗑️ Đã xóa thành công: \(file)")
                successCount += 1
            } else {
                log("❌ Lỗi khi xóa: \(file)")
            }
        }
        
        if successCount == targetFiles.count {
            log("🎉 BYPASS THÀNH CÔNG! Hãy Reboot thiết bị.")
        } else {
            log("⚠️ Xóa không hoàn toàn (\(successCount)/3 file). Có thể tiến trình accountsd đang chạy.")
        }
    }
}