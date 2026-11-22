import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var airlift = AirliftService.shared
    @State private var isImporting = false
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    
                    // 1. HEADER
                    VStack(alignment: .leading, spacing: 12) {
                        Text("BypassLS")
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                            .foregroundColor(.primary)
                        
                        // Trạng thái & Nút Xoá file
                        HStack(alignment: .top, spacing: 8) {
                            Circle()
                                .fill(airlift.pairingFilePath != nil ? Color.green : Color.red)
                                .frame(width: 10, height: 10)
                                .padding(.top, 6)
                            
                            VStack(alignment: .leading, spacing: 4) {
                                Text(airlift.pairingFilePath != nil ? "Đã có file Pairing" : "Chưa có Pairing File")
                                    .font(.headline)
                                    .foregroundColor(airlift.pairingFilePath != nil ? .primary : .secondary)
                                
                                if airlift.pairingFilePath != nil {
                                    Button(action: { airlift.deletePairingFile() }) {
                                        Text("Xoá File")
                                            .font(.caption.bold())
                                            .foregroundColor(.red)
                                            .padding(.vertical, 2)
                                    }
                                }
                            }
                            Spacer()
                        }
                        
                        // Nút Pair on Device
                        Button(action: { airlift.startPairingOnDevice() }) {
                            Text("Pair on Device (iOS 27+)")
                                .font(.subheadline.bold())
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding()
                                .background(Color.orange.opacity(0.15))
                                .foregroundColor(.orange)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .disabled(airlift.isPairing || airlift.isProcessing)
                        
                        // NÚT IMPORT PAIRING FILE (Luôn hiển thị)
                        Button(action: { isImporting = true }) {
                            Text("Import Pairing File (iOS < 27)")
                                .font(.subheadline.bold())
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding()
                                .background(Color.blue.opacity(0.15))
                                .foregroundColor(.blue)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .disabled(airlift.isPairing || airlift.isProcessing)
                        
                        // VPN Local
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
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
                                .animation(.easeInOut, value: airlift.isVPNConnected)
                        }
                        .padding()
                        .background(Color(UIColor.tertiarySystemFill))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .padding()
                    .background(Color(UIColor.secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .shadow(color: Color.black.opacity(0.05), radius: 10, x: 0, y: 5)
                    
                    // 2. NÚT HÀNH ĐỘNG
                    VStack(spacing: 16) {
                        // Bypass Button
                        Button(action: { airlift.bypassICloud() }) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Bypass")
                                    .font(.headline)
                                Text("Log in acc khác + chặn fmi , lock máy")
                                    .font(.caption)
                                    .opacity(0.9)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                            .background(LinearGradient(colors: [Color.orange, Color.orange.opacity(0.8)], startPoint: .topLeading, endPoint: .bottomTrailing))
                            .foregroundColor(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .shadow(color: Color.orange.opacity(0.4), radius: 8, x: 0, y: 4)
                        }
                        .disabled(airlift.isProcessing || airlift.isPairing)
                        
                        // Restore Button
                        Button(action: { airlift.restoreOriginalAccounts() }) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Restore")
                                    .font(.headline)
                                Text("Đưa máy về trạng thái sạch nhất")
                                    .font(.caption)
                                    .opacity(0.9)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                            .background(LinearGradient(colors: [Color.blue, Color.blue.opacity(0.8)], startPoint: .topLeading, endPoint: .bottomTrailing))
                            .foregroundColor(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .shadow(color: Color.blue.opacity(0.4), radius: 8, x: 0, y: 4)
                        }
                        .disabled(airlift.isProcessing || airlift.isPairing)
                    }
                    
                    // 3. LOG
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Tiến trình").font(.headline)
                            Spacer()
                            Text(airlift.isProcessing ? "RUNNING" : "READY")
                                .font(.caption.bold())
                                .foregroundColor(airlift.isProcessing ? .orange : .secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(airlift.isProcessing ? Color.orange.opacity(0.15) : Color.clear)
                                .clipShape(Capsule())
                        }
                        
                        ScrollViewReader { proxy in
                            ScrollView {
                                Text(airlift.logs)
                                    .font(.system(size: 13, design: .monospaced))
                                    .foregroundColor(.primary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(12)
                                    .id("LogBottom")
                            }
                            .frame(height: 180)
                            .background(Color(UIColor.secondarySystemGroupedBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .stroke(Color.gray.opacity(0.1), lineWidth: 1)
                            )
                            .onChange(of: airlift.logs) { _ in
                                withAnimation { proxy.scrollTo("LogBottom", anchor: .bottom) }
                            }
                        }
                    }
                }
                .padding()
            }
            .background(Color(UIColor.systemGroupedBackground).ignoresSafeArea())
            .navigationBarHidden(true)
            .onAppear { _ = airlift.connect() }
            .fileImporter(
                isPresented: $isImporting,
                allowedContentTypes: [.data, .item],
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