import SwiftUI

struct MacRootView: View {
    var body: some View {
        TabView {
            GeotagView()
                .tabItem { Label("照片 Geotag", systemImage: "photo.on.rectangle") }
            FormatConvertView()
                .tabItem { Label("格式互轉", systemImage: "arrow.left.arrow.right") }
        }
        .padding()
        .frame(minWidth: 720, minHeight: 560)
    }
}
