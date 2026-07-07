import SwiftUI

struct VideoThumbnailView: View {
    let id: UUID
    let url: URL
    let fallbackSymbol: String
    let midpointSeconds: Double
    let cornerRadius: CGFloat
    let iconFont: Font

    @EnvironmentObject private var viewModel: VideoSplitterViewModel
    @State private var loadedImage: UIImage?

    init(
        id: UUID,
        url: URL,
        fallbackSymbol: String,
        midpointSeconds: Double = 0,
        cornerRadius: CGFloat = 14,
        iconFont: Font = .title.weight(.black)
    ) {
        self.id = id
        self.url = url
        self.fallbackSymbol = fallbackSymbol
        self.midpointSeconds = midpointSeconds
        self.cornerRadius = cornerRadius
        self.iconFont = iconFont
    }

    private var resolvedImage: UIImage? {
        loadedImage ?? viewModel.cachedThumbnail(for: id)
    }

    var body: some View {
        // The ZStack needs an explicit frame that matches the parent's size,
        // otherwise `Image(uiImage:)` with `.aspectRatio(.fill)` will drive the
        // stack to the image's natural resolution (e.g. 1920×1080) and overflow
        // the card. `GeometryReader` reads the exact size the parent gave us
        // and we use it for both the ZStack frame and the Image frame so the
        // clip paths line up exactly.
        GeometryReader { proxy in
            ZStack {
                AppPalette.mediaWell
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))

                if let image = resolvedImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                } else {
                    Image(systemName: fallbackSymbol)
                        .font(iconFont)
                        .foregroundStyle(AppPalette.accent)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(AppPalette.hairline, lineWidth: 1)
        }
        .task(id: id) {
            await viewModel.loadThumbnail(id: id, url: url, midpointSeconds: midpointSeconds)
            if let cached = viewModel.cachedThumbnail(for: id) {
                loadedImage = cached
            }
        }
    }
}