import SwiftUI

/// A vertical `ScrollView` for the columns of a `NavigationSplitView` (sidebar, detail, inspector) under a
/// toolbar.
///
/// Works around a SwiftUI layout bug (seen on macOS 26/27): a plain `ScrollView` in such a column is placed
/// below the toolbar *and* still given the toolbar's height as a top safe area, so AppKit insets its content
/// a second time when drawing while SwiftUI hit-tests it without that inset. The content showed a toolbar's
/// height too low, and hovers and clicks landed on the row below the pointer.
///
/// Here the scroll view ignores the top safe area (it then reaches under the toolbar, where content scrolls
/// behind the glass like in native lists) and the toolbar's height is added as padding inside the content
/// instead, which SwiftUI draws and hit-tests alike.
struct ColumnScrollView<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @State private var topInset: CGFloat = 0

    var body: some View {
        ScrollView {
            content().padding(.top, topInset)
        }
        .ignoresSafeArea(.container, edges: .top)
        .background {
            // Reaching under the toolbar, this view's top safe area is the toolbar's height.
            Color.clear.onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.top } action: { topInset = $0 }
        }
    }
}
