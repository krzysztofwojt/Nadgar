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
    private static let viewBoxSize: CGFloat = 1024
    private static let sourceBounds = CGRect(x: 160, y: 160, width: 704, height: 704)
    private static let blue = Color(red: 0.0 / 255.0, green: 75.0 / 255.0, blue: 252.0 / 255.0)

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
            let logoFrame = CGRect(
                x: bounds.minX + (195.50 - Self.sourceBounds.minX) * scale,
                y: bounds.minY + (197.50 - Self.sourceBounds.minY) * scale,
                width: 632.00 * scale,
                height: 627.00 * scale
            )

            ZStack {
                logoContents(transform: transform, logoFrame: logoFrame, scale: scale)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }

    @ViewBuilder
    private func logoContents(transform: CGAffineTransform, logoFrame: CGRect, scale: CGFloat) -> some View {
        switch widgetRenderingMode {
        case .fullColor:
            Self.bluePath()
                .applying(transform)
                .fill(Self.blue, style: FillStyle(eoFill: true))

            Self.whiteWavePath()
                .applying(transform)
                .fill(.white, style: FillStyle(eoFill: true))

            logoFrameStroke(frame: logoFrame, scale: scale)
                .foregroundStyle(.white)

        default:
            Self.bluePath()
                .applying(transform)
                .fill(.primary, style: FillStyle(eoFill: true))

            Self.whiteWavePath()
                .applying(transform)
                .fill(.primary, style: FillStyle(eoFill: true))

            logoFrameStroke(frame: logoFrame, scale: scale)
                .foregroundStyle(.primary)
        }
    }

    private func logoFrameStroke(frame: CGRect, scale: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 82.00 * scale, style: .continuous)
            .stroke(lineWidth: 29.00 * scale)
            .frame(width: frame.width, height: frame.height)
            .position(x: frame.midX, y: frame.midY)
    }

    private static func bluePath() -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 553.00, y: 633.00))
        path.addCurve(
            to: CGPoint(x: 720.00, y: 633.00),
            control1: CGPoint(x: 575.92, y: 631.92),
            control2: CGPoint(x: 698.28, y: 632.52)
        )
        path.addCurve(
            to: CGPoint(x: 734.00, y: 637.00),
            control1: CGPoint(x: 741.72, y: 633.48),
            control2: CGPoint(x: 730.28, y: 635.32)
        )
        path.addCurve(
            to: CGPoint(x: 751.00, y: 647.00),
            control1: CGPoint(x: 737.72, y: 638.68),
            control2: CGPoint(x: 746.80, y: 642.92)
        )
        path.addCurve(
            to: CGPoint(x: 769.00, y: 671.00),
            control1: CGPoint(x: 755.20, y: 651.08),
            control2: CGPoint(x: 766.24, y: 665.96)
        )
        path.addCurve(
            to: CGPoint(x: 774.00, y: 689.00),
            control1: CGPoint(x: 771.76, y: 676.04),
            control2: CGPoint(x: 773.40, y: 684.68)
        )
        path.addCurve(
            to: CGPoint(x: 774.00, y: 707.00),
            control1: CGPoint(x: 774.60, y: 693.32),
            control2: CGPoint(x: 774.48, y: 702.92)
        )
        path.addCurve(
            to: CGPoint(x: 770.00, y: 723.00),
            control1: CGPoint(x: 773.52, y: 711.08),
            control2: CGPoint(x: 771.32, y: 719.52)
        )
        path.addCurve(
            to: CGPoint(x: 763.00, y: 736.00),
            control1: CGPoint(x: 768.68, y: 726.48),
            control2: CGPoint(x: 765.40, y: 732.76)
        )
        path.addCurve(
            to: CGPoint(x: 750.00, y: 750.00),
            control1: CGPoint(x: 760.60, y: 739.24),
            control2: CGPoint(x: 754.80, y: 746.76)
        )
        path.addCurve(
            to: CGPoint(x: 723.00, y: 763.00),
            control1: CGPoint(x: 745.20, y: 753.24),
            control2: CGPoint(x: 746.16, y: 761.32)
        )
        path.addCurve(
            to: CGPoint(x: 557.00, y: 764.00),
            control1: CGPoint(x: 699.84, y: 764.68),
            control2: CGPoint(x: 579.56, y: 764.60)
        )
        path.addCurve(
            to: CGPoint(x: 535.00, y: 758.00),
            control1: CGPoint(x: 534.44, y: 763.40),
            control2: CGPoint(x: 538.84, y: 759.44)
        )
        path.addCurve(
            to: CGPoint(x: 525.00, y: 752.00),
            control1: CGPoint(x: 531.16, y: 756.56),
            control2: CGPoint(x: 528.48, y: 755.36)
        )
        path.addCurve(
            to: CGPoint(x: 506.00, y: 730.00),
            control1: CGPoint(x: 521.52, y: 748.64),
            control2: CGPoint(x: 509.12, y: 735.16)
        )
        path.addCurve(
            to: CGPoint(x: 499.00, y: 709.00),
            control1: CGPoint(x: 502.88, y: 724.84),
            control2: CGPoint(x: 499.84, y: 714.16)
        )
        path.addCurve(
            to: CGPoint(x: 499.00, y: 687.00),
            control1: CGPoint(x: 498.16, y: 703.84),
            control2: CGPoint(x: 498.52, y: 691.32)
        )
        path.addCurve(
            to: CGPoint(x: 503.00, y: 673.00),
            control1: CGPoint(x: 499.48, y: 682.68),
            control2: CGPoint(x: 501.32, y: 676.72)
        )
        path.addCurve(
            to: CGPoint(x: 513.00, y: 656.00),
            control1: CGPoint(x: 504.68, y: 669.28),
            control2: CGPoint(x: 509.88, y: 659.72)
        )
        path.addCurve(
            to: CGPoint(x: 529.00, y: 642.00),
            control1: CGPoint(x: 516.12, y: 652.28),
            control2: CGPoint(x: 524.20, y: 644.76)
        )
        path.addCurve(
            to: CGPoint(x: 553.00, y: 633.00),
            control1: CGPoint(x: 533.80, y: 639.24),
            control2: CGPoint(x: 530.08, y: 634.08)
        )
        path.closeSubpath()
        path.move(to: CGPoint(x: 546.00, y: 439.00))
        path.addCurve(
            to: CGPoint(x: 552.00, y: 462.00),
            control1: CGPoint(x: 549.24, y: 437.80),
            control2: CGPoint(x: 553.20, y: 456.36)
        )
        path.addCurve(
            to: CGPoint(x: 536.00, y: 486.00),
            control1: CGPoint(x: 550.80, y: 467.64),
            control2: CGPoint(x: 539.72, y: 481.68)
        )
        path.addCurve(
            to: CGPoint(x: 521.00, y: 498.00),
            control1: CGPoint(x: 532.28, y: 490.32),
            control2: CGPoint(x: 524.24, y: 496.32)
        )
        path.addCurve(
            to: CGPoint(x: 509.00, y: 500.00),
            control1: CGPoint(x: 517.76, y: 499.68),
            control2: CGPoint(x: 512.00, y: 500.36)
        )
        path.addCurve(
            to: CGPoint(x: 496.00, y: 495.00),
            control1: CGPoint(x: 506.00, y: 499.64),
            control2: CGPoint(x: 500.44, y: 499.20)
        )
        path.addCurve(
            to: CGPoint(x: 472.00, y: 465.00),
            control1: CGPoint(x: 491.56, y: 490.80),
            control2: CGPoint(x: 474.16, y: 471.48)
        )
        path.addCurve(
            to: CGPoint(x: 478.00, y: 441.00),
            control1: CGPoint(x: 469.84, y: 458.52),
            control2: CGPoint(x: 474.88, y: 440.16)
        )
        path.addCurve(
            to: CGPoint(x: 498.00, y: 472.00),
            control1: CGPoint(x: 481.12, y: 441.84),
            control2: CGPoint(x: 494.40, y: 467.32)
        )
        path.addCurve(
            to: CGPoint(x: 508.00, y: 480.00),
            control1: CGPoint(x: 501.60, y: 476.68),
            control2: CGPoint(x: 505.96, y: 479.04)
        )
        path.addCurve(
            to: CGPoint(x: 515.00, y: 480.00),
            control1: CGPoint(x: 510.04, y: 480.96),
            control2: CGPoint(x: 512.96, y: 480.96)
        )
        path.addCurve(
            to: CGPoint(x: 525.00, y: 472.00),
            control1: CGPoint(x: 517.04, y: 479.04),
            control2: CGPoint(x: 521.28, y: 476.92)
        )
        path.addCurve(
            to: CGPoint(x: 546.00, y: 439.00),
            control1: CGPoint(x: 528.72, y: 467.08),
            control2: CGPoint(x: 542.76, y: 440.20)
        )
        path.closeSubpath()
        path.move(to: CGPoint(x: 641.00, y: 442.00))
        path.addCurve(
            to: CGPoint(x: 663.00, y: 475.00),
            control1: CGPoint(x: 644.24, y: 443.08),
            control2: CGPoint(x: 659.64, y: 470.56)
        )
        path.addCurve(
            to: CGPoint(x: 669.00, y: 479.00),
            control1: CGPoint(x: 666.36, y: 479.44),
            control2: CGPoint(x: 666.96, y: 478.76)
        )
        path.addCurve(
            to: CGPoint(x: 680.00, y: 477.00),
            control1: CGPoint(x: 671.04, y: 479.24),
            control2: CGPoint(x: 676.52, y: 480.24)
        )
        path.addCurve(
            to: CGPoint(x: 698.00, y: 452.00),
            control1: CGPoint(x: 683.48, y: 473.76),
            control2: CGPoint(x: 694.76, y: 452.72)
        )
        path.addCurve(
            to: CGPoint(x: 707.00, y: 471.00),
            control1: CGPoint(x: 701.24, y: 451.28),
            control2: CGPoint(x: 708.44, y: 465.84)
        )
        path.addCurve(
            to: CGPoint(x: 686.00, y: 495.00),
            control1: CGPoint(x: 705.56, y: 476.16),
            control2: CGPoint(x: 690.08, y: 491.64)
        )
        path.addCurve(
            to: CGPoint(x: 673.00, y: 499.00),
            control1: CGPoint(x: 681.92, y: 498.36),
            control2: CGPoint(x: 675.76, y: 498.76)
        )
        path.addCurve(
            to: CGPoint(x: 663.00, y: 497.00),
            control1: CGPoint(x: 670.24, y: 499.24),
            control2: CGPoint(x: 665.76, y: 498.44)
        )
        path.addCurve(
            to: CGPoint(x: 650.00, y: 487.00),
            control1: CGPoint(x: 660.24, y: 495.56),
            control2: CGPoint(x: 653.24, y: 490.72)
        )
        path.addCurve(
            to: CGPoint(x: 636.00, y: 466.00),
            control1: CGPoint(x: 646.76, y: 483.28),
            control2: CGPoint(x: 637.08, y: 471.40)
        )
        path.addCurve(
            to: CGPoint(x: 641.00, y: 442.00),
            control1: CGPoint(x: 634.92, y: 460.60),
            control2: CGPoint(x: 637.76, y: 440.92)
        )
        path.closeSubpath()
        path.move(to: CGPoint(x: 381.00, y: 443.00))
        path.addCurve(
            to: CGPoint(x: 388.00, y: 465.00),
            control1: CGPoint(x: 383.64, y: 442.64),
            control2: CGPoint(x: 388.84, y: 459.84)
        )
        path.addCurve(
            to: CGPoint(x: 374.00, y: 486.00),
            control1: CGPoint(x: 387.16, y: 470.16),
            control2: CGPoint(x: 377.36, y: 482.16)
        )
        path.addCurve(
            to: CGPoint(x: 360.00, y: 497.00),
            control1: CGPoint(x: 370.64, y: 489.84),
            control2: CGPoint(x: 363.48, y: 495.56)
        )
        path.addCurve(
            to: CGPoint(x: 345.00, y: 498.00),
            control1: CGPoint(x: 356.52, y: 498.44),
            control2: CGPoint(x: 347.64, y: 498.24)
        )
        path.addCurve(
            to: CGPoint(x: 338.00, y: 495.00),
            control1: CGPoint(x: 342.36, y: 497.76),
            control2: CGPoint(x: 341.48, y: 498.36)
        )
        path.addCurve(
            to: CGPoint(x: 316.00, y: 470.00),
            control1: CGPoint(x: 334.52, y: 491.64),
            control2: CGPoint(x: 317.44, y: 475.28)
        )
        path.addCurve(
            to: CGPoint(x: 326.00, y: 451.00),
            control1: CGPoint(x: 314.56, y: 464.72),
            control2: CGPoint(x: 322.64, y: 450.16)
        )
        path.addCurve(
            to: CGPoint(x: 344.00, y: 477.00),
            control1: CGPoint(x: 329.36, y: 451.84),
            control2: CGPoint(x: 340.52, y: 473.64)
        )
        path.addCurve(
            to: CGPoint(x: 355.00, y: 479.00),
            control1: CGPoint(x: 347.48, y: 480.36),
            control2: CGPoint(x: 352.36, y: 480.08)
        )
        path.addCurve(
            to: CGPoint(x: 366.00, y: 468.00),
            control1: CGPoint(x: 357.64, y: 477.92),
            control2: CGPoint(x: 362.88, y: 472.32)
        )
        path.addCurve(
            to: CGPoint(x: 381.00, y: 443.00),
            control1: CGPoint(x: 369.12, y: 463.68),
            control2: CGPoint(x: 378.36, y: 443.36)
        )
        path.closeSubpath()
        path.move(to: CGPoint(x: 427.00, y: 393.00))
        path.addCurve(
            to: CGPoint(x: 445.00, y: 397.00),
            control1: CGPoint(x: 430.84, y: 392.64),
            control2: CGPoint(x: 440.44, y: 393.88)
        )
        path.addCurve(
            to: CGPoint(x: 465.00, y: 419.00),
            control1: CGPoint(x: 449.56, y: 400.12),
            control2: CGPoint(x: 463.32, y: 413.60)
        )
        path.addCurve(
            to: CGPoint(x: 459.00, y: 442.00),
            control1: CGPoint(x: 466.68, y: 424.40),
            control2: CGPoint(x: 462.24, y: 442.48)
        )
        path.addCurve(
            to: CGPoint(x: 438.00, y: 415.00),
            control1: CGPoint(x: 455.76, y: 441.52),
            control2: CGPoint(x: 441.84, y: 418.48)
        )
        path.addCurve(
            to: CGPoint(x: 427.00, y: 413.00),
            control1: CGPoint(x: 434.16, y: 411.52),
            control2: CGPoint(x: 429.40, y: 412.40)
        )
        path.addCurve(
            to: CGPoint(x: 418.00, y: 420.00),
            control1: CGPoint(x: 424.60, y: 413.60),
            control2: CGPoint(x: 421.12, y: 416.28)
        )
        path.addCurve(
            to: CGPoint(x: 401.00, y: 444.00),
            control1: CGPoint(x: 414.88, y: 423.72),
            control2: CGPoint(x: 403.64, y: 443.28)
        )
        path.addCurve(
            to: CGPoint(x: 396.00, y: 426.00),
            control1: CGPoint(x: 398.36, y: 444.72),
            control2: CGPoint(x: 396.48, y: 429.00)
        )
        path.addCurve(
            to: CGPoint(x: 397.00, y: 419.00),
            control1: CGPoint(x: 395.52, y: 423.00),
            control2: CGPoint(x: 394.96, y: 422.12)
        )
        path.addCurve(
            to: CGPoint(x: 413.00, y: 400.00),
            control1: CGPoint(x: 399.04, y: 415.88),
            control2: CGPoint(x: 409.40, y: 403.12)
        )
        path.addCurve(
            to: CGPoint(x: 427.00, y: 393.00),
            control1: CGPoint(x: 416.60, y: 396.88),
            control2: CGPoint(x: 423.16, y: 393.36)
        )
        path.closeSubpath()
        path.move(to: CGPoint(x: 589.00, y: 393.00))
        path.addCurve(
            to: CGPoint(x: 601.00, y: 394.00),
            control1: CGPoint(x: 592.48, y: 391.92),
            control2: CGPoint(x: 598.48, y: 393.28)
        )
        path.addCurve(
            to: CGPoint(x: 610.00, y: 399.00),
            control1: CGPoint(x: 603.52, y: 394.72),
            control2: CGPoint(x: 606.64, y: 395.76)
        )
        path.addCurve(
            to: CGPoint(x: 629.00, y: 421.00),
            control1: CGPoint(x: 613.36, y: 402.24),
            control2: CGPoint(x: 627.44, y: 415.60)
        )
        path.addCurve(
            to: CGPoint(x: 623.00, y: 444.00),
            control1: CGPoint(x: 630.56, y: 426.40),
            control2: CGPoint(x: 625.64, y: 444.00)
        )
        path.addCurve(
            to: CGPoint(x: 607.00, y: 421.00),
            control1: CGPoint(x: 620.36, y: 444.00),
            control2: CGPoint(x: 610.12, y: 424.72)
        )
        path.addCurve(
            to: CGPoint(x: 597.00, y: 413.00),
            control1: CGPoint(x: 603.88, y: 417.28),
            control2: CGPoint(x: 599.76, y: 413.60)
        )
        path.addCurve(
            to: CGPoint(x: 584.00, y: 416.00),
            control1: CGPoint(x: 594.24, y: 412.40),
            control2: CGPoint(x: 587.84, y: 412.64)
        )
        path.addCurve(
            to: CGPoint(x: 565.00, y: 441.00),
            control1: CGPoint(x: 580.16, y: 419.36),
            control2: CGPoint(x: 567.88, y: 440.76)
        )
        path.addCurve(
            to: CGPoint(x: 560.00, y: 418.00),
            control1: CGPoint(x: 562.12, y: 441.24),
            control2: CGPoint(x: 559.16, y: 422.56)
        )
        path.addCurve(
            to: CGPoint(x: 572.00, y: 403.00),
            control1: CGPoint(x: 560.84, y: 413.44),
            control2: CGPoint(x: 568.52, y: 406.00)
        )
        path.addCurve(
            to: CGPoint(x: 589.00, y: 393.00),
            control1: CGPoint(x: 575.48, y: 400.00),
            control2: CGPoint(x: 585.52, y: 394.08)
        )
        path.closeSubpath()
        return path
    }

    private static func whiteWavePath() -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 509.00, y: 320.00))
        path.addCurve(
            to: CGPoint(x: 525.00, y: 324.00),
            control1: CGPoint(x: 512.84, y: 318.92),
            control2: CGPoint(x: 521.40, y: 321.12)
        )
        path.addCurve(
            to: CGPoint(x: 539.00, y: 344.00),
            control1: CGPoint(x: 528.60, y: 326.88),
            control2: CGPoint(x: 532.16, y: 322.04)
        )
        path.addCurve(
            to: CGPoint(x: 582.00, y: 507.00),
            control1: CGPoint(x: 545.84, y: 365.96),
            control2: CGPoint(x: 575.52, y: 484.68)
        )
        path.addCurve(
            to: CGPoint(x: 593.00, y: 530.00),
            control1: CGPoint(x: 588.48, y: 529.32),
            control2: CGPoint(x: 590.72, y: 528.44)
        )
        path.addCurve(
            to: CGPoint(x: 601.00, y: 520.00),
            control1: CGPoint(x: 595.28, y: 531.56),
            control2: CGPoint(x: 599.08, y: 523.96)
        )
        path.addCurve(
            to: CGPoint(x: 609.00, y: 497.00),
            control1: CGPoint(x: 602.92, y: 516.04),
            control2: CGPoint(x: 604.56, y: 512.12)
        )
        path.addCurve(
            to: CGPoint(x: 638.00, y: 394.00),
            control1: CGPoint(x: 613.44, y: 481.88),
            control2: CGPoint(x: 633.08, y: 408.88)
        )
        path.addCurve(
            to: CGPoint(x: 650.00, y: 373.00),
            control1: CGPoint(x: 642.92, y: 379.12),
            control2: CGPoint(x: 647.36, y: 376.36)
        )
        path.addCurve(
            to: CGPoint(x: 660.00, y: 366.00),
            control1: CGPoint(x: 652.64, y: 369.64),
            control2: CGPoint(x: 657.24, y: 366.84)
        )
        path.addCurve(
            to: CGPoint(x: 673.00, y: 366.00),
            control1: CGPoint(x: 662.76, y: 365.16),
            control2: CGPoint(x: 669.88, y: 364.68)
        )
        path.addCurve(
            to: CGPoint(x: 686.00, y: 377.00),
            control1: CGPoint(x: 676.12, y: 367.32),
            control2: CGPoint(x: 681.08, y: 367.52)
        )
        path.addCurve(
            to: CGPoint(x: 714.00, y: 445.00),
            control1: CGPoint(x: 690.92, y: 386.48),
            control2: CGPoint(x: 709.08, y: 434.56)
        )
        path.addCurve(
            to: CGPoint(x: 727.00, y: 464.00),
            control1: CGPoint(x: 718.92, y: 455.44),
            control2: CGPoint(x: 724.00, y: 461.60)
        )
        path.addCurve(
            to: CGPoint(x: 739.00, y: 465.00),
            control1: CGPoint(x: 730.00, y: 466.40),
            control2: CGPoint(x: 736.12, y: 466.44)
        )
        path.addCurve(
            to: CGPoint(x: 751.00, y: 452.00),
            control1: CGPoint(x: 741.88, y: 463.56),
            control2: CGPoint(x: 748.36, y: 453.68)
        )
        path.addCurve(
            to: CGPoint(x: 761.00, y: 451.00),
            control1: CGPoint(x: 753.64, y: 450.32),
            control2: CGPoint(x: 759.08, y: 450.28)
        )
        path.addCurve(
            to: CGPoint(x: 767.00, y: 458.00),
            control1: CGPoint(x: 762.92, y: 451.72),
            control2: CGPoint(x: 766.52, y: 456.08)
        )
        path.addCurve(
            to: CGPoint(x: 765.00, y: 467.00),
            control1: CGPoint(x: 767.48, y: 459.92),
            control2: CGPoint(x: 766.32, y: 464.72)
        )
        path.addCurve(
            to: CGPoint(x: 756.00, y: 477.00),
            control1: CGPoint(x: 763.68, y: 469.28),
            control2: CGPoint(x: 758.88, y: 474.84)
        )
        path.addCurve(
            to: CGPoint(x: 741.00, y: 485.00),
            control1: CGPoint(x: 753.12, y: 479.16),
            control2: CGPoint(x: 744.48, y: 484.04)
        )
        path.addCurve(
            to: CGPoint(x: 727.00, y: 485.00),
            control1: CGPoint(x: 737.52, y: 485.96),
            control2: CGPoint(x: 730.12, y: 485.72)
        )
        path.addCurve(
            to: CGPoint(x: 715.00, y: 479.00),
            control1: CGPoint(x: 723.88, y: 484.28),
            control2: CGPoint(x: 718.72, y: 483.44)
        )
        path.addCurve(
            to: CGPoint(x: 696.00, y: 448.00),
            control1: CGPoint(x: 711.28, y: 474.56),
            control2: CGPoint(x: 700.80, y: 458.20)
        )
        path.addCurve(
            to: CGPoint(x: 675.00, y: 394.00),
            control1: CGPoint(x: 691.20, y: 437.80),
            control2: CGPoint(x: 678.84, y: 401.44)
        )
        path.addCurve(
            to: CGPoint(x: 664.00, y: 386.00),
            control1: CGPoint(x: 671.16, y: 386.56),
            control2: CGPoint(x: 666.52, y: 384.92)
        )
        path.addCurve(
            to: CGPoint(x: 654.00, y: 403.00),
            control1: CGPoint(x: 661.48, y: 387.08),
            control2: CGPoint(x: 656.88, y: 396.04)
        )
        path.addCurve(
            to: CGPoint(x: 640.00, y: 444.00),
            control1: CGPoint(x: 651.12, y: 409.96),
            control2: CGPoint(x: 644.32, y: 429.12)
        )
        path.addCurve(
            to: CGPoint(x: 618.00, y: 527.00),
            control1: CGPoint(x: 635.68, y: 458.88),
            control2: CGPoint(x: 622.08, y: 514.76)
        )
        path.addCurve(
            to: CGPoint(x: 606.00, y: 546.00),
            control1: CGPoint(x: 613.92, y: 539.24),
            control2: CGPoint(x: 608.76, y: 543.12)
        )
        path.addCurve(
            to: CGPoint(x: 595.00, y: 551.00),
            control1: CGPoint(x: 603.24, y: 548.88),
            control2: CGPoint(x: 597.16, y: 550.52)
        )
        path.addCurve(
            to: CGPoint(x: 588.00, y: 550.00),
            control1: CGPoint(x: 592.84, y: 551.48),
            control2: CGPoint(x: 590.04, y: 551.08)
        )
        path.addCurve(
            to: CGPoint(x: 578.00, y: 542.00),
            control1: CGPoint(x: 585.96, y: 548.92),
            control2: CGPoint(x: 580.40, y: 545.36)
        )
        path.addCurve(
            to: CGPoint(x: 568.00, y: 522.00),
            control1: CGPoint(x: 575.60, y: 538.64),
            control2: CGPoint(x: 573.88, y: 542.64)
        )
        path.addCurve(
            to: CGPoint(x: 529.00, y: 370.00),
            control1: CGPoint(x: 562.12, y: 501.36),
            control2: CGPoint(x: 534.64, y: 390.76)
        )
        path.addCurve(
            to: CGPoint(x: 521.00, y: 349.00),
            control1: CGPoint(x: 523.36, y: 349.24),
            control2: CGPoint(x: 522.68, y: 352.48)
        )
        path.addCurve(
            to: CGPoint(x: 515.00, y: 341.00),
            control1: CGPoint(x: 519.32, y: 345.52),
            control2: CGPoint(x: 516.20, y: 341.96)
        )
        path.addCurve(
            to: CGPoint(x: 511.00, y: 341.00),
            control1: CGPoint(x: 513.80, y: 340.04),
            control2: CGPoint(x: 513.52, y: 336.68)
        )
        path.addCurve(
            to: CGPoint(x: 494.00, y: 377.00),
            control1: CGPoint(x: 508.48, y: 345.32),
            control2: CGPoint(x: 500.48, y: 355.52)
        )
        path.addCurve(
            to: CGPoint(x: 457.00, y: 520.00),
            control1: CGPoint(x: 487.52, y: 398.48),
            control2: CGPoint(x: 462.28, y: 500.92)
        )
        path.addCurve(
            to: CGPoint(x: 450.00, y: 536.00),
            control1: CGPoint(x: 451.72, y: 539.08),
            control2: CGPoint(x: 452.28, y: 532.52)
        )
        path.addCurve(
            to: CGPoint(x: 438.00, y: 549.00),
            control1: CGPoint(x: 447.72, y: 539.48),
            control2: CGPoint(x: 441.36, y: 547.44)
        )
        path.addCurve(
            to: CGPoint(x: 422.00, y: 549.00),
            control1: CGPoint(x: 434.64, y: 550.56),
            control2: CGPoint(x: 425.72, y: 551.28)
        )
        path.addCurve(
            to: CGPoint(x: 407.00, y: 530.00),
            control1: CGPoint(x: 418.28, y: 546.72),
            control2: CGPoint(x: 412.40, y: 545.24)
        )
        path.addCurve(
            to: CGPoint(x: 377.00, y: 422.00),
            control1: CGPoint(x: 401.60, y: 514.76),
            control2: CGPoint(x: 382.64, y: 439.28)
        )
        path.addCurve(
            to: CGPoint(x: 360.00, y: 386.00),
            control1: CGPoint(x: 371.36, y: 404.72),
            control2: CGPoint(x: 362.52, y: 390.32)
        )
        path.addCurve(
            to: CGPoint(x: 356.00, y: 386.00),
            control1: CGPoint(x: 357.48, y: 381.68),
            control2: CGPoint(x: 357.56, y: 384.56)
        )
        path.addCurve(
            to: CGPoint(x: 347.00, y: 398.00),
            control1: CGPoint(x: 354.44, y: 387.44),
            control2: CGPoint(x: 352.04, y: 387.56)
        )
        path.addCurve(
            to: CGPoint(x: 314.00, y: 473.00),
            control1: CGPoint(x: 341.96, y: 408.44),
            control2: CGPoint(x: 320.12, y: 462.56)
        )
        path.addCurve(
            to: CGPoint(x: 296.00, y: 485.00),
            control1: CGPoint(x: 307.88, y: 483.44),
            control2: CGPoint(x: 300.68, y: 483.92)
        )
        path.addCurve(
            to: CGPoint(x: 275.00, y: 482.00),
            control1: CGPoint(x: 291.32, y: 486.08),
            control2: CGPoint(x: 279.56, y: 484.16)
        )
        path.addCurve(
            to: CGPoint(x: 258.00, y: 467.00),
            control1: CGPoint(x: 270.44, y: 479.84),
            control2: CGPoint(x: 260.16, y: 470.12)
        )
        path.addCurve(
            to: CGPoint(x: 257.00, y: 456.00),
            control1: CGPoint(x: 255.84, y: 463.88),
            control2: CGPoint(x: 256.52, y: 457.92)
        )
        path.addCurve(
            to: CGPoint(x: 262.00, y: 451.00),
            control1: CGPoint(x: 257.48, y: 454.08),
            control2: CGPoint(x: 260.32, y: 451.60)
        )
        path.addCurve(
            to: CGPoint(x: 271.00, y: 451.00),
            control1: CGPoint(x: 263.68, y: 450.40),
            control2: CGPoint(x: 268.72, y: 449.56)
        )
        path.addCurve(
            to: CGPoint(x: 281.00, y: 463.00),
            control1: CGPoint(x: 273.28, y: 452.44),
            control2: CGPoint(x: 278.96, y: 461.20)
        )
        path.addCurve(
            to: CGPoint(x: 288.00, y: 466.00),
            control1: CGPoint(x: 283.04, y: 464.80),
            control2: CGPoint(x: 286.20, y: 465.88)
        )
        path.addCurve(
            to: CGPoint(x: 296.00, y: 464.00),
            control1: CGPoint(x: 289.80, y: 466.12),
            control2: CGPoint(x: 293.36, y: 466.64)
        )
        path.addCurve(
            to: CGPoint(x: 310.00, y: 444.00),
            control1: CGPoint(x: 298.64, y: 461.36),
            control2: CGPoint(x: 304.96, y: 454.32)
        )
        path.addCurve(
            to: CGPoint(x: 338.00, y: 378.00),
            control1: CGPoint(x: 315.04, y: 433.68),
            control2: CGPoint(x: 333.20, y: 387.24)
        )
        path.addCurve(
            to: CGPoint(x: 350.00, y: 367.00),
            control1: CGPoint(x: 342.80, y: 368.76),
            control2: CGPoint(x: 346.88, y: 368.44)
        )
        path.addCurve(
            to: CGPoint(x: 364.00, y: 366.00),
            control1: CGPoint(x: 353.12, y: 365.56),
            control2: CGPoint(x: 360.88, y: 365.04)
        )
        path.addCurve(
            to: CGPoint(x: 376.00, y: 375.00),
            control1: CGPoint(x: 367.12, y: 366.96),
            control2: CGPoint(x: 373.48, y: 372.00)
        )
        path.addCurve(
            to: CGPoint(x: 385.00, y: 391.00),
            control1: CGPoint(x: 378.52, y: 378.00),
            control2: CGPoint(x: 380.08, y: 375.52)
        )
        path.addCurve(
            to: CGPoint(x: 417.00, y: 504.00),
            control1: CGPoint(x: 389.92, y: 406.48),
            control2: CGPoint(x: 412.32, y: 488.16)
        )
        path.addCurve(
            to: CGPoint(x: 424.00, y: 523.00),
            control1: CGPoint(x: 421.68, y: 519.84),
            control2: CGPoint(x: 422.32, y: 519.88)
        )
        path.addCurve(
            to: CGPoint(x: 431.00, y: 530.00),
            control1: CGPoint(x: 425.68, y: 526.12),
            control2: CGPoint(x: 428.72, y: 532.28)
        )
        path.addCurve(
            to: CGPoint(x: 443.00, y: 504.00),
            control1: CGPoint(x: 433.28, y: 527.72),
            control2: CGPoint(x: 436.88, y: 524.88)
        )
        path.addCurve(
            to: CGPoint(x: 482.00, y: 356.00),
            control1: CGPoint(x: 449.12, y: 483.12),
            control2: CGPoint(x: 476.00, y: 376.52)
        )
        path.addCurve(
            to: CGPoint(x: 493.00, y: 333.00),
            control1: CGPoint(x: 488.00, y: 335.48),
            control2: CGPoint(x: 489.76, y: 337.32)
        )
        path.addCurve(
            to: CGPoint(x: 509.00, y: 320.00),
            control1: CGPoint(x: 496.24, y: 328.68),
            control2: CGPoint(x: 505.16, y: 321.08)
        )
        path.closeSubpath()
        return path
    }
}
