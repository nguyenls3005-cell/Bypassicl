import SwiftUI
import UniformTypeIdentifiers
import UIKit

private struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.965 : 1.0)
            .opacity(configuration.isPressed ? 0.88 : 1.0)
            .animation(.spring(response: 0.22, dampingFraction: 0.68), value: configuration.isPressed)
    }
}

private struct DocumentPickerSheet: UIViewControllerRepresentable {
    let onPick: (URL) -> Void
    let onCancel: () -> Void
    
    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick, onCancel: onCancel)
    }
    
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item, .data], asCopy: true)
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
    @ObservedObject var airlift = AirliftService.shared
    @State private var isImporting = false
    @State private var showAboutSheet = false
    
    private let repoURL = URL(string: "https://tinyurl.com/4kbsas4r")!
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    
                    // 1. HEADER
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .center) {
                            Text("BypassLS")
                                .font(.system(size: 34, weight: .bold, design: .rounded))
                                .foregroundColor(.primary)
                            
                            Spacer()
                            
                            Button {
                                showAboutSheet = true
                            } label: {
                                Label("Giới thiệu", systemImage: "info.circle")
                                    .font(.caption.bold())
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(Color.primary.opacity(0.06))
                                    .foregroundColor(.primary)
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(PressableButtonStyle())
                        }
                        
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
                                    .buttonStyle(PressableButtonStyle())
                                }
                            }
                            Spacer()
                        }
                        
                        // Nút Pair on Device
                        Button(action: { airlift.startPairingOnDevice() }) {
                            Text(airlift.isPairing ? "Đang Pair on Device (iOS 27+)..." : "Pair on Device (iOS 27+)")
                                .font(.subheadline.bold())
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding()
                                .background(Color.orange.opacity(0.15))
                                .foregroundColor(.orange)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(PressableButtonStyle())
                        .disabled(airlift.isPairing || airlift.isProcessing)
                        
                        // Mã PIN hiện ngay dưới nút Pair on Device (không đưa vào log)
                        if let pin = airlift.currentPin, !pin.isEmpty {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Mã PIN ghép đôi")
                                        .font(.caption.bold())
                                        .foregroundColor(.secondary)
                                    Text("Nhập trong Settings → Developer Mode")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Text(pin)
                                    .font(.system(size: 26, weight: .bold, design: .monospaced))
                                    .foregroundColor(.orange)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(Color.orange.opacity(0.12))
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color(UIColor.tertiarySystemFill))
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                        
                        // NÚT IMPORT PAIRING FILE (dùng UIDocumentPickerViewController)
                        Button(action: { isImporting = true }) {
                            Text("Import Pairing File (iOS < 27)")
                                .font(.subheadline.bold())
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding()
                                .background(Color.blue.opacity(0.15))
                                .foregroundColor(.blue)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(PressableButtonStyle())
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
                    .animation(.easeInOut(duration: 0.2), value: airlift.currentPin)
                    
                    // 2. NÚT HÀNH ĐỘNG (Bypass nhỏ + trong suốt | Repo riêng ở giữa | Restore đỏ dịu liquid glass)
                    VStack(spacing: 10) {
                        // Bypass Button (nhỏ hơn + nền trong suốt)
                        Button(action: { airlift.bypassICloud() }) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Bypass")
                                    .font(.subheadline.bold())
                                Text("Ghi đè Accounts3.sqlite cục bộ")
                                    .font(.caption2)
                                    .opacity(0.85)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(Color.orange.opacity(0.06))
                            .foregroundColor(.orange)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(Color.orange.opacity(0.35), lineWidth: 1)
                            )
                        }
                        .buttonStyle(PressableButtonStyle())
                        .disabled(airlift.isProcessing || airlift.isPairing)
                        
                        // Repo Button riêng ở giữa (trong suốt, mở Safari)
                        Button(action: { openRepoInSafari() }) {
                            HStack(spacing: 8) {
                                Image(systemName: "arrow.up.right.square")
                                    .font(.subheadline)
                                Text("DNS chặn FMI , Apple Server")
                                    .font(.subheadline.weight(.medium))
                                Spacer()
                                Text("NextDns")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .background(Color.clear)
                            .foregroundColor(.primary)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(Color.primary.opacity(0.18), lineWidth: 1)
                            )
                        }
                        .buttonStyle(PressableButtonStyle())
                        
                        // Restore Button (nhỏ hơn + đỏ dịu + liquid glass)
                        Button(action: { airlift.restoreOriginalAccounts() }) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Restore")
                                    .font(.subheadline.bold())
                                Text("Khôi phục 3 file sqlite từ bản backup")
                                    .font(.caption2)
                                    .opacity(0.9)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(
                                ZStack {
                                    Color.clear.background(.ultraThinMaterial)
                                    LinearGradient(
                                        colors: [
                                            Color(red: 0.85, green: 0.28, blue: 0.30).opacity(0.34),
                                            Color(red: 0.72, green: 0.20, blue: 0.24).opacity(0.24)
                                        ],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                }
                            )
                            .foregroundColor(Color(red: 0.96, green: 0.38, blue: 0.40))
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(
                                        LinearGradient(
                                            colors: [
                                                Color.white.opacity(0.55),
                                                Color(red: 0.92, green: 0.35, blue: 0.38).opacity(0.45)
                                            ],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        ),
                                        lineWidth: 1
                                    )
                            )
                            .shadow(color: Color(red: 0.85, green: 0.28, blue: 0.30).opacity(0.16), radius: 8, x: 0, y: 4)
                        }
                        .buttonStyle(PressableButtonStyle())
                        .disabled(airlift.isProcessing || airlift.isPairing)
                    }
                    
                    // 3. LOG (không in PIN vào đây nữa)
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
                                Text(filteredLogs)
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
            .sheet(isPresented: $isImporting) {
                DocumentPickerSheet(
                    onPick: { url in
                        isImporting = false
                        airlift.importPairingFile(from: url)
                    },
                    onCancel: {
                        isImporting = false
                    }
                )
            }
            .sheet(isPresented: $showAboutSheet) {
                AboutAppView(repoURL: repoURL, onOpenRepo: { openRepoInSafari() })
            }
            .alert("Thông Báo", isPresented: $airlift.showAlert) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(airlift.alertMessage)
            }
        }
    }
    
    private var filteredLogs: String {
        airlift.logs
            .components(separatedBy: .newlines)
            .filter { line in
                !line.contains("🔐 PIN:") && !line.contains("nhập PIN này")
            }
            .joined(separator: "\n")
    }
    
    private func openRepoInSafari() {
        UIApplication.shared.open(repoURL)
    }
}

private struct AboutAppView: View {
    let repoURL: URL
    let onOpenRepo: () -> Void
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 16) {
                Text("BypassLS")
                    .font(.title2.bold())
                
                Text("Công cụ quản lý pairing, tự động backup lần đầu khi bypass, restore 3 file sqlite gốc và kết nối Airlift.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                Button(action: onOpenRepo) {
                    HStack {
                        Image(systemName: "link")
                        Text("Link Repo: https://github.com/nguyenls3005-cell/Bypassicl")
                            .font(.footnote.weight(.medium))
                            .lineLimit(1)
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.caption)
                    }
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(Color(UIColor.secondarySystemGroupedBackground))
                    .foregroundColor(.primary)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(PressableButtonStyle())
                
                Spacer()
            }
            .padding()
            .background(Color(UIColor.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("Giới thiệu")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Đóng") { dismiss() }
                }
            }
        }
    }
}
