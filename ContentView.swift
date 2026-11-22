import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var airlift = AirliftService.shared
    @State private var isImporting = false
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    
                    // 1. HEADER
                    VStack(alignment: .leading, spacing: 12) {
                        Text("BypassLS")
                            .font(.largeTitle.bold())
                        
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
                                        .clipShape(Capsule())
                                }
                            }
                        }
                        
                        // Nút Pair on Device
                        Button(action: { airlift.startPairingOnDevice() }) {
                            Text("Pair on Device (iOS 27+)")
                                .font(.subheadline.bold())
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding()
                                .background(Color.orange.opacity(0.2))
                                .foregroundColor(.orange)
                                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                        .disabled(airlift.isPairing || airlift.isProcessing)
                        
                        // VPN Local
                        HStack {
                            VStack(alignment: .leading) {
                                Text("VPN local")
                                    .font(.subheadline.bold())
                                Text("Peer 10.7.0.1")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Image(systemName: airlift.isVPNConnected ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundColor(airlift.isVPNConnected ? .green : .red)
                                .font(.title2)
                        }
                        .padding()
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .padding()
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    
                    // 2. CHỨC NĂNG
                    Text("Chọn chức năng")
                        .font(.headline)
                        .padding(.horizontal, 4)
                    
                    HStack {
                        Text("Bypass Apple ID")
                            .font(.body)
                        Spacer()
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.orange)
                    }
                    .padding()
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    
                    // 3. NÚT CHẠY
                    VStack(spacing: 12) {
                        Button(action: { airlift.bypassICloud() }) {
                            Text("Bắt đầu chạy")
                                .font(.headline)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding()
                                .background(Color.orange.opacity(0.8))
                                .foregroundColor(.white)
                                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                        .disabled(airlift.isProcessing || airlift.isPairing)
                        
                        Button(action: { airlift.restoreOriginalAccounts() }) {
                            Text("Khôi phục toàn bộ")
                                .font(.headline)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding()
                                .background(Color.orange.opacity(0.8))
                                .foregroundColor(.white)
                                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                        .disabled(airlift.isProcessing || airlift.isPairing)
                    }
                    
                    // 4. LOG
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Tiến trình").font(.headline)
                            Spacer()
                            Text(airlift.isProcessing ? "RUNNING" : "READY")
                                .font(.caption.bold())
                                .foregroundColor(airlift.isProcessing ? .orange : .secondary)
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
                            .background(.ultraThinMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .onChange(of: airlift.logs) { _ in
                                withAnimation { proxy.scrollTo("LogBottom", anchor: .bottom) }
                            }
                        }
                    }
                }
                .padding()
            }
            .background(Color(UIColor.systemGroupedBackground))
            .navigationBarHidden(true)
            .onAppear {
                // FIX: Gọi lại connect khi View hiện lên để load đúng trạng thái Pairing File
                _ = airlift.connect()
            }
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