import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var airlift = AirliftService.shared
    @State private var isVPNLocalOn = false
    @State private var isImporting = false
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    
                    // 1. KHỐI TRẠNG THÁI (HEADER)
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Bypass iCloud LSNguyen")
                            .font(.largeTitle)
                            .fontWeight(.bold)
                            .foregroundColor(.primary)
                        
                        HStack(spacing: 8) {
                            Circle()
                                .fill(airlift.pairingFilePath != nil ? Color.green : Color.red)
                                .frame(width: 10, height: 10)
                            
                            Text(airlift.pairingFilePath != nil ? "iPhone đã sẵn sàng" : "Chưa có Pairing File")
                                .font(.headline)
                                .foregroundColor(airlift.pairingFilePath != nil ? .primary : .secondary)
                            
                            Spacer()
                            
                            if airlift.pairingFilePath == nil {
                                Button(action: { isImporting = true }) {
                                    Text("Ghép đôi")
                                        .font(.subheadline.bold())
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 6)
                                        .background(Color.blue)
                                        .cornerRadius(8)
                                }
                            }
                        }
                        
                        // Nút Pair on Device (Dành cho iOS 27)
                        Button(action: {
                            airlift.log("📡 Bắt đầu Pair on Device...")
                            airlift.startPairingOnDevice()
                        }) {
                            Text("Pair on Device (iOS 27+)")
                                .font(.subheadline.bold())
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding()
                                .background(Color.orange.opacity(0.15))
                                .foregroundColor(.orange)
                                .cornerRadius(12)
                        }
                        .disabled(airlift.isPairing || airlift.isProcessing)
                        
                        // Nút VPN Local trong suốt
                        Button(action: { isVPNLocalOn.toggle() }) {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text("VPN local")
                                        .font(.subheadline.bold())
                                        .foregroundColor(.primary)
                                    Text("Peer 10.7.0.1")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Image(systemName: isVPNLocalOn ? "checkmark" : "xmark")
                                    .foregroundColor(isVPNLocalOn ? .green : .red)
                                    .font(.title3.bold())
                            }
                            .padding()
                            .background(Color.clear)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        
                        if airlift.isProcessing && !isVPNLocalOn {
                            Text("⚠️ Vui lòng bật VPN Local để quá trình chạy ổn định!")
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                    }
                    .padding()
                    .background(Color(UIColor.secondarySystemGroupedBackground))
                    .cornerRadius(16) // Bo tròn card
                    
                    // 2. CHỌN CHỨC NĂNG
                    Text("Chọn chức năng")
                        .font(.headline)
                        .padding(.horizontal, 4)
                    
                    HStack {
                        Text("Bypass Apple ID")
                            .font(.body)
                            .foregroundColor(.primary)
                        Spacer()
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.orange)
                    }
                    .padding()
                    .background(Color(UIColor.secondarySystemGroupedBackground))
                    .cornerRadius(12) // Bo tròn nút chọn
                    
                    // 3. NÚT HÀNH ĐỘNG
                    VStack(spacing: 12) {
                        Button(action: {
                            airlift.log("🔥 Bắt đầu chạy Bypass Apple ID...")
                            airlift.bypassICloud()
                        }) {
                            Text("Bắt đầu chạy")
                                .font(.headline)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding()
                                .background(Color.orange.opacity(0.8))
                                .foregroundColor(.white)
                                .cornerRadius(16) // Bo tròn nút
                        }
                        .disabled(airlift.isProcessing || airlift.isPairing)
                        
                        Button(action: {
                            airlift.log("🔄 Bắt đầu Restore toàn bộ...")
                            airlift.restoreOriginalAccounts()
                        }) {
                            Text("Khôi phục toàn bộ")
                                .font(.headline)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding()
                                .background(Color.orange.opacity(0.8))
                                .foregroundColor(.white)
                                .cornerRadius(16) // Bo tròn nút
                        }
                        .disabled(airlift.isProcessing || airlift.isPairing)
                    }
                    
                    // 4. LOG
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Tiến trình")
                                .font(.headline)
                            Spacer()
                            if airlift.isProcessing {
                                Text("RUNNING")
                                    .font(.caption.bold())
                                    .foregroundColor(.orange)
                            } else {
                                Text("READY")
                                    .font(.caption.bold())
                                    .foregroundColor(.secondary)
                            }
                        }
                        
                        ScrollViewReader { proxy in
                            ScrollView {
                                Text(airlift.logs)
                                    .font(.system(size: 13, design: .monospaced))
                                    .foregroundColor(.primary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(10)
                                    .id("LogBottom")
                            }
                            .frame(height: 200)
                            .background(Color(UIColor.secondarySystemGroupedBackground))
                            .cornerRadius(16) // Bo tròn khung log
                            .onChange(of: airlift.logs) { _ in
                                withAnimation {
                                    proxy.scrollTo("LogBottom", anchor: .bottom)
                                }
                            }
                        }
                    }
                }
                .padding()
            }
            .background(Color(UIColor.systemGroupedBackground))
            .navigationBarHidden(true)
            .fileImporter(
                isPresented: $isImporting,
                allowedContentTypes: [.data],
                allowsMultipleSelection: false
            ) { result in
                if case .success(let urls) = result, let url = urls.first {
                    airlift.importPairingFile(from: url)
                }
            }
            .alert("Thông Báo", isPresented: $airlift.showAlert) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(airlift.alertMessage)
            }
        }
    }
}