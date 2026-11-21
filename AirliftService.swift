import Foundation
import Combine

class AirliftService: ObservableObject {
    static let shared = AirliftService()
    
    @Published var logs: String = "=== Bypassicl Log ===\n"
    
    // Đường dẫn hệ thống
    private let accountsDir = "/var/mobile/Library/Accounts"
    private let targetFiles = ["Accounts3.sqlite", "Accounts3.sqlite-shm", "Accounts3.sqlite-wal"]
    
    // Thư mục Backup trong sandbox của App
    var backupDir: URL {
        let docDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docDir.appendingPathComponent("AccountsBackup")
    }
    
    private init() {}
    
    // MARK: - Hàm Log
    private func log(_ message: String) {
        DispatchQueue.main.async {
            self.logs += message + "\n"
            print(message)
        }
    }
    
    // MARK: - FFI Wrappers (Cần đối chiếu với AirliftFFI.h của AirBeep)
    // Ghi chú: Tên hàm dưới đây là chuẩn phổ biến của AirBeep/AirliftFFI. 
    // Nếu build lỗi "cannot find in scope", bạn mở file header C ra và sửa lại tên hàm cho khớp.
    
    private func ffi_init() -> Bool {
        // Thường AirBeep dùng hàm al_init() hoặc airlift_init()
        let result = al_init() 
        return result == 0
    }
    
    private func ffi_read_file(_ path: String) -> Data? {
        var outBuffer: UnsafeMutablePointer<UInt8>? = nil
        var outLength: Int = 0
        
        // Giả định signature: int al_read_file(const char* path, uint8_t** buffer, size_t* length)
        let result = al_read_file(path, &outBuffer, &outLength)
        
        guard result == 0, let buffer = outBuffer else { return nil }
        defer { free(buffer) } // Giải phóng bộ nhớ C cấp phát
        
        return Data(bytes: buffer, count: outLength)
    }
    
    private func ffi_write_file(_ path: String, data: Data) -> Bool {
        return data.withUnsafeBytes { (rawBuffer: UnsafeRawBufferPointer) -> Bool in
            guard let baseAddress = rawBuffer.baseAddress else { return false }
            let uint8Ptr = baseAddress.assumingMemoryBound(to: UInt8.self)
            
            // Giả định signature: int al_write_file(const char* path, const uint8_t* data, size_t length)
            let result = al_write_file(path, uint8Ptr, data.count)
            return result == 0
        }
    }
    
    private func ffi_delete_file(_ path: String) -> Bool {
        // Giả định signature: int al_delete_file(const char* path)
        let result = al_delete_file(path)
        return result == 0
    }
    
    // MARK: - Nghiệp vụ chính
    
    func connect() {
        log("[*] Đang khởi tạo kết nối Airlift...")
        if ffi_init() {
            log("✅ Kết nối Airlift thành công (qua LocalDevVPN).")
        } else {
            log("❌ Lỗi khởi tạo Airlift. Hãy kiểm tra LocalDevVPN và file Pairing.")
        }
    }
    
    func backupAccounts() -> Bool {
        log("[*] Bắt đầu quá trình Backup...")
        
        // Kiểm tra xem đã backup chưa để tránh ghi đè bản gốc
        let fm = FileManager.default
        let firstFileBackup = backupDir.appendingPathComponent(targetFiles[0])
        if fm.fileExists(atPath: firstFileBackup.path) {
            log("✅ Bản backup đã tồn tại. Bỏ qua bước Backup.")
            return true
        }
        
        do {
            try fm.createDirectory(at: backupDir, withIntermediateDirectories: true)
        } catch {
            log("❌ Không thể tạo thư mục Backup: \(error.localizedDescription)")
            return false
        }
        
        var success = true
        for file in targetFiles {
            let fullPath = "\(accountsDir)/\(file)"
            guard let data = ffi_read_file(fullPath) else {
                log("❌ Không thể đọc \(file) từ hệ thống.")
                success = false
                continue
            }
            
            let backupPath = backupDir.appendingPathComponent(file)
            do {
                try data.write(to: backupPath)
                log("✅ Đã backup: \(file) (\(data.count) bytes)")
            } catch {
                log("❌ Lỗi ghi file backup \(file): \(error.localizedDescription)")
                success = false
            }
        }
        return success
    }
    
    func bypassICloud() {
        log("[*] Bắt đầu Bypass iCloud...")
        
        // Bắt buộc Backup trước khi xóa
        guard backupAccounts() else {
            log("❌ HỦY BYPASS: Quá trình Backup thất bại.")
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
            log("🎉 BYPASS THÀNH CÔNG! Vui lòng khởi động lại thiết bị (Reboot) để áp dụng.")
        } else if successCount > 0 {
            log("⚠️ Xóa không hoàn toàn (\(successCount)/3 file). Có thể do tiến trình Accounts đang chạy.")
        }
    }
    
    func restoreAccounts() {
        log("[*] Bắt đầu Restore từ Backup...")
        var successCount = 0
        
        for file in targetFiles {
            let backupPath = backupDir.appendingPathComponent(file)
            guard let data = try? Data(contentsOf: backupPath) else {
                log("⚠️ Không tìm thấy bản backup của \(file).")
                continue
            }
            
            let fullPath = "\(accountsDir)/\(file)"
            if ffi_write_file(fullPath, data: data) {
                log("✅ Đã khôi phục: \(file)")
                successCount += 1
            } else {
                log("❌ Lỗi khôi phục: \(file)")
            }
        }
        
        if successCount == targetFiles.count {
            log("🎉 RESTORE THÀNH CÔNG! Vui lòng khởi động lại thiết bị.")
        }
    }
}
