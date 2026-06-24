import SwiftUI
import WidgetKit

@main
struct WristAssistComplicationBundle: WidgetBundle {
    var body: some Widget {
        WristAssistComplication()
    }
}

struct WristAssistComplication: Widget {
    private let kind = "WristAssistComplication"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: WristAssistComplicationProvider()) { entry in
            WristAssistComplicationView(entry: entry)
                .containerBackground(for: .widget) {
                    Color.clear
                }
                .widgetURL(URL(string: "wristassist://open"))
        }
        .configurationDisplayName("WristAssist")
        .description("Open WristAssist from your watch face.")
        .supportedFamilies([
            .accessoryCircular,
            .accessoryCorner,
            .accessoryRectangular,
            .accessoryInline
        ])
    }
}

private struct WristAssistComplicationEntry: TimelineEntry {
    let date: Date
}

private struct WristAssistComplicationProvider: TimelineProvider {
    func placeholder(in context: Context) -> WristAssistComplicationEntry {
        WristAssistComplicationEntry(date: Date())
    }

    func getSnapshot(
        in context: Context,
        completion: @escaping (WristAssistComplicationEntry) -> Void
    ) {
        completion(WristAssistComplicationEntry(date: Date()))
    }

    func getTimeline(
        in context: Context,
        completion: @escaping (Timeline<WristAssistComplicationEntry>) -> Void
    ) {
        completion(Timeline(entries: [WristAssistComplicationEntry(date: Date())], policy: .never))
    }
}

private struct WristAssistComplicationView: View {
    let entry: WristAssistComplicationEntry

    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryRectangular:
            HStack(spacing: 6) {
                icon
                    .frame(width: 22, height: 22)

                Text("WristAssist")
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .padding(.horizontal, 2)

        case .accessoryInline:
            Text("WristAssist")

        default:
            ZStack {
                AccessoryWidgetBackground()

                icon
                    .padding(4)
            }
        }
    }

    private var icon: some View {
        Image("ComplicationIcon")
            .resizable()
            .renderingMode(.original)
            .scaledToFit()
    }
}
