import SwiftUI
import UIKit

struct LocalMealImage<Content: View>: View {
    let url: URL?
    @ViewBuilder let content: (AsyncImagePhase) -> Content
    var body: some View {
        if let url, url.scheme == "data",
           let encoded = url.absoluteString.split(separator: ",", maxSplits: 1).last,
           let data = Data(base64Encoded: String(encoded)), let image = UIImage(data: data) {
            content(.success(Image(uiImage: image)))
        } else if let url, url.isFileURL, let image = UIImage(contentsOfFile: url.path) {
            content(.success(Image(uiImage: image)))
        } else {
            content(.empty)
        }
    }
}
