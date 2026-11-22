import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var airlift = AirliftService.shared
    @State private var isImporting = false
    
    var body: some View {
        NavigationView {
            VStack(spacing: 16) {
                
                // Vùng hiển thị PIN (Chỉ hiện khi đang có mã)
                if let pin = airlift.currentPin {
                    VStack(spacing: 4) {
                        Text("PAIRING CODE")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(pin)
                            .font(.system(size: 42, weight: .bold, design: .monospaced))
                            .foregroundColor(.red)
                            .tracking(8)
                    }
                    .padding(.vertical, 10)
                }
                
                // Khung Log Console
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(airlift.logs)
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundColor(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .id("LogBottom")
                    }
                    .background(Color(UIColor.secondarySystemBackground))
                    .cornerRadius(8)
                    .onChange(of: airlift.logs) { _ in
                        withAnimation {
                            proxy.scrollTo("LogBottom", anchor: .bottom)
                        }
                    }
                }
                .frame(maxHeight: .infinity)
                
                // Khối Buttons
                VStack(spacing: 12) {
                    
                    Button(action: { isImporting = true }) {
                        Text("Import Pairing File")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    
                    Button(action: { airlift.startPairingOnDevice() }) {
                        Text("Pair on Device")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    
                    Button(action: {
                        if airlift.connect() {
                            airlift.alertMessage = "Kết nối Airlift thành công!"
                            airlift.showAlert = true
                        }
                    }) {
                        Text("Connect Airlift")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    
                    HStack(spacing: 12) {
                        Button(action: { airlift.restoreOriginalAccounts() }) {
                            Text("Restore Gốc")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        
                        Button(action: { airlift.bypassICloud() }) {
                            Text("Bypass iCloud")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                    }
                }
                .disabled(airlift.isProcessing || airlift.isPairing) // Khóa nút khi đang chạy
            }
            .padding()
            .navigationTitle("LSTool")
            .navigationBarTitleDisplayMode(.inline)
            .fileImporter(
                isPresented: $isImporting,
                allowedContentTypes: [.data],
                allowsMultipleSelection: false
            ) { result in
                if case .success(let urls) = result, let url = urls.first {
                    airlift.importPairingFile(from: url)
                }
            }
            // Popup thông báo
            .alert("Thông Báo", isPresented: $airlift.showAlert) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(airlift.alertMessage)
            }
            // Vòng xoay loading khi đang xử lý
            .overlay {
                if airlift.isProcessing {
                    ProgressView("Đang xử lý...")
                        .padding()
                        .background(Color(UIColor.secondarySystemBackground))
                        .cornerRadius(8)
                        .shadow(radius: 5)
                }
            }
        }
    }
}