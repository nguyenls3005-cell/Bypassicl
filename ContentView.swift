import SwiftUI
import UniformTypeIdentifiers
import UIKit

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
                                Text("Tunnel Connection")
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
                    
                    // 2. NÚT HÀNH ĐỘNG (Bypass nhỏ + trong suốt | Repo trong suốt ở giữa | Restore đỏ dịu liquid glass)
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
                        .disabled(airlift.isProcessing || airlift.isPairing)
                        
                        // Repo Button ở giữa (nền trong suốt, mở Safari)
                        Button(action: { openRepoInSafari() }) {
                            HStack(spacing: 8) {
                                Image(systemName: "arrow.up.right.square")
                                    .font(.subheadline)
                                Text("Repo của app (GitHub)")
                                    .font(.subheadline.weight(.medium))
                                Spacer()
                                Text("Safari")
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
                        .disabled(airlift.isProcessing || airlift.isPairing)
                        
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
                Text("BypassLS / Bypassicl")
                    .font(.title2.bold())
                
                Text("Công cụ thao tác pairing, backup/restore file Accounts3.sqlite cục bộ và theo dõi tiến trình qua Airlift.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                VStack(alignment: .leading, spacing: 6) {
                    Text("Repository")
                        .font(.caption.bold())
                        .foregroundColor(.secondary)
                    Text(repoURL.absoluteString)
                        .font(.footnote.monospaced())
                        .foregroundColor(.primary)
                        .textSelection(.enabled)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(UIColor.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                
                Button(action: onOpenRepo) {
                    Label("Mở Repo bằng Safari", systemImage: "safari")
                        .font(.subheadline.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                
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
