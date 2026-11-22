import SwiftUI
import UniformTypeIdentifiers

struct DocumentPickerView: UIViewControllerRepresentable {
    let onPick: (URL) -> Void
    let onCancel: () -> Void
    
    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick, onCancel: onCancel)
    }
    
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }
    
    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}
    
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let onPick: (URL) -> Void
        private let onCancel: () -> Void
        
        init(onPick: @escaping (URL) -> Void, onCancel: @escaping () -> Void) {
            self.onPick = onPick
            self.onCancel = onCancel
        }
        
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let url = urls.first {
                onPick(url)
            }
        }
        
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onCancel()
        }
    }
}

struct ContentView: View {
    @StateObject private var airlift = AirliftService.shared
    @State private var isConnected = false
    @State private var isProcessing = false
    @State private var showImporter = false
    
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
                    Button {
                        airlift.logs += "[*] Mở Document Picker...\n"
                        showImporter = true
                    } label: {
                        Label("Import Pairing File", systemImage: "doc.badge.plus")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(.purple)
                    .disabled(isProcessing || airlift.isPairing)
                    
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
            .sheet(isPresented: $showImporter) {
                DocumentPickerView(
                    onPick: { url in
                        showImporter = false
                        airlift.importPairingFile(from: url)
                    },
                    onCancel: {
                        showImporter = false
                        airlift.logs += "⏹ Đã hủy chọn file\n"
                    }
                )
            }
        }
    }
}
