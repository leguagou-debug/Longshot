import SwiftUI
import Photos

struct ResultView: View {
    @Environment(StitchViewModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var toast: String?
    @State private var saving = false

    var body: some View {
        @Bindable var m = model
        ZStack {
            Color.black.ignoresSafeArea()
            if let img = model.resultImage {
                ScrollView([.vertical, .horizontal]) {
                    Image(uiImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: min(UIScreen.main.bounds.width, 440))
                        .padding(.vertical, 12)
                }
                .safeAreaInset(edge: .top) { infoBar(img) }
                .safeAreaInset(edge: .bottom) { actionBar }
            } else {
                ProgressView("正在生成…").tint(.white)
            }

            if let toast {
                VStack {
                    Spacer()
                    Text(toast)
                        .font(.footnote)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 11)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.bottom, 110)
                }
                .transition(.opacity)
            }
        }
        .navigationTitle("长图")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.visible, for: .navigationBar)
    }

    private func infoBar(_ img: UIImage) -> some View {
        HStack(spacing: 14) {
            Text("尺寸 \(Int(img.size.width))×\(Int(img.size.height))")
            Text("来源 \(model.items.count) 张")
            Spacer()
            let low = model.items.filter { $0.lowConfidence }.count
            if low > 0 {
                Text("\(low) 处待确认").foregroundStyle(Theme.orange)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var actionBar: some View {
        HStack(spacing: 10) {
            Button {
                Task { await doSave() }
            } label: {
                Label(saving ? "保存中" : "存到相册", systemImage: "square.and.arrow.down")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.bordered)
            .disabled(saving)

            if let url = model.shareFileURL() {
                ShareLink(item: url) {
                    Label("分享", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func doSave() async {
        saving = true
        let r = await model.saveToPhotos()
        saving = false
        switch r {
        case .success:
            showToast("已保存到相册")
        case .failure(let e):
            showToast(e.localizedDescription)
        }
    }

    private func showToast(_ s: String) {
        withAnimation { toast = s }
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation { toast = nil }
        }
    }
}
