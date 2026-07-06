import SwiftUI
import WidgetKit

@main
struct NadgarComplicationBundle: WidgetBundle {
    var body: some Widget {
        NadgarComplication()
    }
}

struct NadgarComplication: Widget {
    private let kind = "NadgarComplication"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: NadgarComplicationProvider()) { entry in
            NadgarComplicationView(entry: entry)
                .containerBackground(for: .widget) {
                    Color.clear
                }
                .widgetURL(URL(string: "nadgar://open"))
        }
        .configurationDisplayName("Nadgar")
        .description("Open Nadgar from your watch face.")
        .supportedFamilies([
            .accessoryCircular,
            .accessoryCorner,
            .accessoryRectangular,
            .accessoryInline
        ])
    }
}

private struct NadgarComplicationEntry: TimelineEntry {
    let date: Date
}

private struct NadgarComplicationProvider: TimelineProvider {
    func placeholder(in context: Context) -> NadgarComplicationEntry {
        NadgarComplicationEntry(date: Date())
    }

    func getSnapshot(
        in context: Context,
        completion: @escaping (NadgarComplicationEntry) -> Void
    ) {
        completion(NadgarComplicationEntry(date: Date()))
    }

    func getTimeline(
        in context: Context,
        completion: @escaping (Timeline<NadgarComplicationEntry>) -> Void
    ) {
        completion(Timeline(entries: [NadgarComplicationEntry(date: Date())], policy: .never))
    }
}

private struct NadgarComplicationView: View {
    let entry: NadgarComplicationEntry

    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryRectangular:
            HStack(spacing: 6) {
                icon
                    .frame(width: 20, height: 20)
                    .accessibilityHidden(true)

                Text("Nadgar")
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .padding(.horizontal, 2)

        case .accessoryInline:
            Text("Nadgar")

        case .accessoryCircular:
            icon
                .frame(width: 30, height: 30)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel("Nadgar")

        case .accessoryCorner:
            icon
                .frame(width: 28, height: 28)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel("Nadgar")

        default:
            icon
                .frame(width: 30, height: 30)
                .accessibilityLabel("Nadgar")
        }
    }

    private var icon: some View {
        NadgarLogoMark()
            .aspectRatio(1, contentMode: .fit)
            .widgetAccentable()
    }
}

private struct NadgarLogoMark: View {
    private static let sourceBounds = CGRect(x: 160, y: 160, width: 704, height: 704)
    private static let frameRect = CGRect(x: 194, y: 196, width: 635, height: 630)
    private static let frameCornerRadius: CGFloat = 90
    private static let frameLineWidth: CGFloat = 44
    private static let buttonRect = CGRect(x: 414, y: 631, width: 360, height: 134)
    private static let buttonCornerRadius: CGFloat = 67
    private static let blue = Color(red: 40.0 / 255.0, green: 99.0 / 255.0, blue: 254.0 / 255.0)

    @Environment(\.widgetRenderingMode) private var widgetRenderingMode

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let bounds = CGRect(
                x: (proxy.size.width - side) / 2,
                y: (proxy.size.height - side) / 2,
                width: side,
                height: side
            )
            let scale = side / Self.sourceBounds.width
            let transform = CGAffineTransform(
                a: scale,
                b: 0,
                c: 0,
                d: scale,
                tx: bounds.minX - Self.sourceBounds.minX * scale,
                ty: bounds.minY - Self.sourceBounds.minY * scale
            )

            ZStack {
                logoContents(transform: transform, scale: scale)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }

    @ViewBuilder
    private func logoContents(transform: CGAffineTransform, scale: CGFloat) -> some View {
        switch widgetRenderingMode {
        case .fullColor:
            logoShape(transform: transform, scale: scale, frameColor: .white, buttonColor: Self.blue)

        default:
            logoShape(transform: transform, scale: scale, frameColor: .primary, buttonColor: .primary)
        }
    }

    @ViewBuilder
    private func logoShape(
        transform: CGAffineTransform,
        scale: CGFloat,
        frameColor: Color,
        buttonColor: Color
    ) -> some View {
        let frame = Self.frameRect.applying(transform)
        let button = Self.buttonRect.applying(transform)

        RoundedRectangle(cornerRadius: Self.frameCornerRadius * scale, style: .continuous)
            .stroke(frameColor, lineWidth: Self.frameLineWidth * scale)
            .frame(width: frame.width, height: frame.height)
            .position(x: frame.midX, y: frame.midY)

        RoundedRectangle(cornerRadius: Self.buttonCornerRadius * scale, style: .continuous)
            .fill(buttonColor)
            .frame(width: button.width, height: button.height)
            .position(x: button.midX, y: button.midY)
    }
}
