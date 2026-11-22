import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var airlift = AirliftService.shared
    @State private var isConnected = false
    @State private var isProcessing = false
    @State private var showImporter = false
    @State private var showManualPathAlert = false
    @State private var manualPathInput = ""
    
    var body: some View {
        NavigationView {
            VStack(spacing: 16) {
                
                // MARK: - Log
                ScrollView {
                    Text(airlift.logs)
                        .font(.system(.footnote, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .background(Color.black.opacity(0.85))
                .foregroundColor(.green)
                .cornerRadius(10)
                .padding(.horizontal)
                
                // MARK: - PIN hiển thị khi đang pair
                if let pin = airlift.currentPin {
                    VStack(spacing: 6) {
                        Text("Nhập PIN này trên máy target")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(pin)
                            .font(.system(size: 42, weight: .bold, design: .monospaced))
                            .foregroundColor(.green)
                    }
                    .padding(.vertical, 8)
                }
                
                // MARK: - Nút chức năng
                VStack(spacing: 10) {
                    
                    // 1. Import Pairing File
                    HStack(spacing: 8) {
                        Button {
                            airlift.logs += "[*] Đang mở trình chọn file...\n"
                            showImporter = true
                        } label: {
                            Label("Import Pairing File", systemImage: "doc.badge.plus")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .tint(.purple)
                        .disabled(isProcessing || airlift.isPairing)
                        
                        Button {
                            manualPathInput = ""
                            showManualPathAlert = true
                        } label: {
                            Image(systemName: "doc.on.clipboard")
                        }
                        .buttonStyle(.bordered)
                        .tint(.purple)
                        .disabled(isProcessing || airlift.isPairing)
                    }
                    
                    // 2. Pair on Device (iOS 27) - Bonjour
                    Button {
                        airlift.startPairingOnDevice()
                    } label: {
                        Label(
                            airlift.isPairing ? "Đang Pairing... (chờ PIN)" : "Pair on Device (iOS 27)",
                            systemImage: airlift.isPairing ? "antenna.radiowaves.left.and.right" : "link"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(airlift.isPairing ? .orange : .cyan)
                    .disabled(isProcessing || airlift.isPairing)
                    
                    // 3. Kết nối
                    Button {
                        isProcessing = true
                        DispatchQueue.global(qos: .userInitiated).async {
                            let ok = airlift.connect()
                            DispatchQueue.main.async {
                                isConnected = ok
                                isProcessing = false
                            }
                        }
                    } label: {
                        Label(
                            isConnected ? "Đã kết nối" : "Kết nối Airlift",
                            systemImage: isConnected ? "checkmark.circle.fill" : "bolt.horizontal.circle"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(isConnected ? .green : .blue)
                    .disabled(isProcessing || airlift.isPairing)
                    
                    // 4. Chỉ Backup
                    Button {
                        isProcessing = true
                        DispatchQueue.global(qos: .userInitiated).async {
                            _ = airlift.backupAccounts()
                            DispatchQueue.main.async { isProcessing = false }
                        }
                    } label: {
                        Label("Chỉ Backup (An toàn)", systemImage: "externaldrive.badge.timemachine")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(.orange)
                    .disabled(isProcessing || !isConnected || airlift.isPairing)
                    
                    // 5. Bypass
                    Button {
                        isProcessing = true
                        DispatchQueue.global(qos: .userInitiated).async {
                            airlift.bypassICloud()
                            DispatchQueue.main.async { isProcessing = false }
                        }
                    } label: {
                        Label("BYPASS iCLOUD (Ghi đè Accounts)", systemImage: "flame.fill")
                            .frame(maxWidth: .infinity)
                            .fontWeight(.bold)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(isProcessing || !isConnected || airlift.isPairing)
                }
                .padding(.horizontal)
                .padding(.bottom, 12)
            }
            .navigationTitle("Bypassicl")
            .navigationBarTitleDisplayMode(.inline)
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: [.item],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    if let url = urls.first {
                        airlift.importPairingFile(from: url)
                    }
                case .failure(let error):
                    airlift.logs += "❌ File picker error: \(error.localizedDescription)\n"
                }
            }
            .alert("Nhập Pairing Thủ Công", isPresented: $showManualPathAlert) {
                TextField("Dán đường dẫn file hoặc nội dung plist/xml", text: $manualPathInput)
                Button("Dán từ Clipboard") {
                    if let clip = UIPasteboard.general.string {
                        airlift.importPairingFromTextOrPath(clip)
                    } else {
                        airlift.logs += "❌ Clipboard trống\n"
                    }
                }
                Button("Xác nhận") {
                    airlift.importPairingFromTextOrPath(manualPathInput)
                }
                Button("Hủy", role: .cancel) {}
            }
        }
    }
}
