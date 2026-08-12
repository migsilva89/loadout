import CoreGraphics

/// A small, fixed set of spacing values, used everywhere instead of paddings tuned by eye.
/// Four steps are enough for a window this size: `xs` for the gap between a label and what
/// sits right next to it, `sm` for the padding inside a row, `md` for the margin around a
/// pane's content, `lg` for the outermost edge of the detail pane.
enum Metrics {
    static let xs: CGFloat = 6
    static let sm: CGFloat = 10
    static let md: CGFloat = 16
    static let lg: CGFloat = 22
}
