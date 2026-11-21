import SwiftUI

struct ContentView: View {
    @StateObject private var airlift = AirliftService.shared
    @State private var isConnected = false
    @State private var isProcessing = false
    
    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                
                ScrollView {
                    Text(airlift.logs)
                        .font(.system(.footnote, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .background(Color.black.opacity(0.8))
                .foregroundColor(.green)
                .cornerRadius(10)
                .padding(.horizontal)
                
                VStack(spacing: 12) {
                    Button(action: {
                        isProcessing = true
                        DispatchQueue.global(qos: .userInitiated).async {
                            let ok = airlift.connect()
                            DispatchQueue.main.async {
                                isConnected = ok
                                isProcessing = false
                            }
                        }
                    }) {
                        Text(isConnected ? "✅ Đã kết nối" : "🔌 Kết nối Airlift")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(isConnected ? .green : .blue)
                    .disabled(isProcessing)
                    
                    Button(action: {
                        isProcessing = true
                        DispatchQueue.global(qos: .userInitiated).async {
                            airlift.backupAccounts()
                            DispatchQueue.main.async { isProcessing = false }
                        }
                    }) {
                        Text("📦 Chỉ Backup (An toàn)")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(.orange)
                    .disabled(isProcessing || !isConnected)
                    
                    Button(action: {
                        isProcessing = true
                        DispatchQueue.global(qos: .userInitiated).async {
                            airlift.bypassICloud()
                            DispatchQueue.main.async { isProcessing = false }
                        }
                    }) {
                        Text("🚀 BYPASS iCLOUD (Xóa Accounts3)")
                            .frame(maxWidth: .infinity)
                            .bold()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(isProcessing || !isConnected)
                }
                .padding(.horizontal)
                .padding(.bottom)
            }
            .navigationTitle("Bypassicl")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}