import SwiftUI

struct ContentView: View {
    @StateObject private var airlift = AirliftService.shared
    @State private var isProcessing = false
    
    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                
                // Khung hiển thị Log
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
                
                // Các nút chức năng
                VStack(spacing: 12) {
                    Button(action: {
                        airlift.connect()
                    }) {
                        Text("Kết nối Airlift")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                    
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
                    .disabled(isProcessing)
                    
                    Button(action: {
                        isProcessing = true
                        DispatchQueue.global(qos: .userInitiated).async {
                            airlift.restoreAccounts()
                            DispatchQueue.main.async { isProcessing = false }
                        }
                    }) {
                        Text("♻️ Restore (Khôi phục từ Backup)")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(.green)
                    .disabled(isProcessing)
                }
                .padding(.horizontal)
                .padding(.bottom)
            }
            .navigationTitle("Bypassicl")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
