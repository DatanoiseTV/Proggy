import SwiftUI

struct ZIFSocketView: View {
    var highlightMode: ZIFHighlight = .none

    enum ZIFHighlight {
        case none, spi, i2c
    }

    // DIP-16 pin layout (viewed from top):
    // Left: pins 1(top)..8(bottom), Right: pins 16(top)..9(bottom)
    // Top 8 pin positions (1-4 left, 16-13 right) → I2C EEPROM
    // Bottom 8 pin positions (5-8 left, 12-9 right) → SPI Flash

    private let pinCount = 8            // pins per side
    private let bodyWidth: CGFloat = 88
    private let bodyHeight: CGFloat = 160
    private let pinRadius: CGFloat = 4
    private let pinSpacing: CGFloat = 17
    private let pinInset: CGFloat = 10
    private let legLength: CGFloat = 14

    private var i2cColor: Color { highlightMode == .i2c ? .cyan : .cyan.opacity(0.5) }
    private var spiColor: Color { highlightMode == .spi ? .orange : .orange.opacity(0.5) }

    // Pin labels for I2C EEPROM (24Cxx, DIP-8 in top half)
    private let i2cLeftLabels  = ["A0", "A1", "A2", "GND"]
    private let i2cRightLabels = ["VCC", "WP", "SCL", "SDA"]

    // Pin labels for SPI Flash (25xx, DIP-8 in bottom half)
    private let spiLeftLabels  = ["/CS", "DO", "/WP", "GND"]
    private let spiRightLabels = ["VCC", "/HOLD", "CLK", "DI"]

    var body: some View {
        VStack(spacing: 6) {
            Canvas { context, size in
                let cx = size.width / 2
                let originY: CGFloat = 20

                drawBody(context: context, cx: cx, originY: originY)
                drawLever(context: context, cx: cx, originY: originY)
                drawNotch(context: context, cx: cx, originY: originY)
                drawZones(context: context, cx: cx, originY: originY)
                drawPins(context: context, cx: cx, originY: originY, size: size)
                drawPinLabels(context: context, cx: cx, originY: originY, size: size)
            }
            .frame(width: 200, height: 230)

            // Legend
            HStack(spacing: 12) {
                legendItem(color: .cyan, label: "I2C (24xx)")
                legendItem(color: .orange, label: "SPI (25xx)")
            }
            .font(.system(.caption2, design: .rounded))
        }
    }

    // MARK: - Body

    private func drawBody(context: GraphicsContext, cx: CGFloat, originY: CGFloat) {
        let bodyRect = CGRect(
            x: cx - bodyWidth / 2,
            y: originY,
            width: bodyWidth,
            height: bodyHeight
        )

        // Shadow
        var shadowCtx = context
        shadowCtx.addFilter(.shadow(color: .black.opacity(0.25), radius: 4, x: 0, y: 2))
        shadowCtx.fill(
            RoundedRectangle(cornerRadius: 6).path(in: bodyRect),
            with: .color(.init(white: 0.18))
        )

        // Body fill
        context.fill(
            RoundedRectangle(cornerRadius: 6).path(in: bodyRect),
            with: .linearGradient(
                Gradient(colors: [.init(white: 0.22), .init(white: 0.16)]),
                startPoint: CGPoint(x: cx, y: originY),
                endPoint: CGPoint(x: cx, y: originY + bodyHeight)
            )
        )

        // Body outline
        context.stroke(
            RoundedRectangle(cornerRadius: 6).path(in: bodyRect),
            with: .color(.init(white: 0.35)),
            lineWidth: 1
        )
    }

    // MARK: - ZIF Lever

    private func drawLever(context: GraphicsContext, cx: CGFloat, originY: CGFloat) {
        let leverWidth: CGFloat = 10
        let leverX = cx + bodyWidth / 2 - 2

        // Lever track
        let trackRect = CGRect(
            x: leverX,
            y: originY + 8,
            width: leverWidth,
            height: bodyHeight - 16
        )
        context.fill(
            RoundedRectangle(cornerRadius: 3).path(in: trackRect),
            with: .color(.init(white: 0.12))
        )
        context.stroke(
            RoundedRectangle(cornerRadius: 3).path(in: trackRect),
            with: .color(.init(white: 0.3)),
            lineWidth: 0.5
        )

        // Lever handle (at top = open position)
        let handleRect = CGRect(
            x: leverX - 1,
            y: originY + 6,
            width: leverWidth + 6,
            height: 18
        )
        context.fill(
            RoundedRectangle(cornerRadius: 3).path(in: handleRect),
            with: .linearGradient(
                Gradient(colors: [.init(white: 0.4), .init(white: 0.28)]),
                startPoint: CGPoint(x: leverX, y: originY + 6),
                endPoint: CGPoint(x: leverX, y: originY + 24)
            )
        )
        context.stroke(
            RoundedRectangle(cornerRadius: 3).path(in: handleRect),
            with: .color(.init(white: 0.5)),
            lineWidth: 0.5
        )
    }

    // MARK: - Notch

    private func drawNotch(context: GraphicsContext, cx: CGFloat, originY: CGFloat) {
        let notchRadius: CGFloat = 8
        let notchCenter = CGPoint(x: cx, y: originY)

        let notchPath = Path { p in
            p.addArc(
                center: notchCenter,
                radius: notchRadius,
                startAngle: .degrees(0),
                endAngle: .degrees(180),
                clockwise: false
            )
        }
        context.fill(notchPath, with: .color(.init(white: 0.12)))
        context.stroke(notchPath, with: .color(.init(white: 0.35)), lineWidth: 1)
    }

    // MARK: - Zone Highlights

    private func drawZones(context: GraphicsContext, cx: CGFloat, originY: CGFloat) {
        let zoneInset: CGFloat = 3
        let halfH = bodyHeight / 2

        // I2C zone (top half)
        let i2cRect = CGRect(
            x: cx - bodyWidth / 2 + zoneInset,
            y: originY + zoneInset,
            width: bodyWidth - zoneInset * 2,
            height: halfH - zoneInset
        )
        context.fill(
            RoundedRectangle(cornerRadius: 4).path(in: i2cRect),
            with: .color(i2cColor.opacity(highlightMode == .i2c ? 0.15 : 0.06))
        )

        // SPI zone (bottom half)
        let spiRect = CGRect(
            x: cx - bodyWidth / 2 + zoneInset,
            y: originY + halfH,
            width: bodyWidth - zoneInset * 2,
            height: halfH - zoneInset
        )
        context.fill(
            RoundedRectangle(cornerRadius: 4).path(in: spiRect),
            with: .color(spiColor.opacity(highlightMode == .spi ? 0.15 : 0.06))
        )

        // Zone labels
        let i2cText = Text("I2C").font(.system(size: 9, weight: .bold, design: .rounded)).foregroundColor(i2cColor.opacity(0.7))
        context.draw(context.resolve(i2cText), at: CGPoint(x: cx, y: originY + halfH / 2), anchor: .center)

        let spiText = Text("SPI").font(.system(size: 9, weight: .bold, design: .rounded)).foregroundColor(spiColor.opacity(0.7))
        context.draw(context.resolve(spiText), at: CGPoint(x: cx, y: originY + halfH + halfH / 2), anchor: .center)

        // Divider line
        let divY = originY + halfH
        context.stroke(
            Path { p in
                p.move(to: CGPoint(x: cx - bodyWidth / 2 + 8, y: divY))
                p.addLine(to: CGPoint(x: cx + bodyWidth / 2 - 8, y: divY))
            },
            with: .color(.init(white: 0.4)),
            style: StrokeStyle(lineWidth: 0.5, dash: [3, 2])
        )
    }

    // MARK: - Pins

    private func drawPins(context: GraphicsContext, cx: CGFloat, originY: CGFloat, size: CGSize) {
        let leftX = cx - bodyWidth / 2
        let rightX = cx + bodyWidth / 2
        let startY = originY + 18

        for i in 0..<pinCount {
            let y = startY + CGFloat(i) * pinSpacing
            let isI2C = i < 4
            let pinColor = isI2C ? i2cColor : spiColor

            // Left pin (1-8)
            drawSinglePin(context: context, x: leftX, y: y, isLeft: true, color: pinColor, number: i + 1)

            // Right pin (16 down to 9)
            drawSinglePin(context: context, x: rightX, y: y, isLeft: false, color: pinColor, number: 16 - i)
        }
    }

    private func drawSinglePin(context: GraphicsContext, x: CGFloat, y: CGFloat, isLeft: Bool, color: Color, number: Int) {
        let dir: CGFloat = isLeft ? -1 : 1
        let legEnd = x + dir * legLength

        // Pin leg
        context.stroke(
            Path { p in
                p.move(to: CGPoint(x: x, y: y))
                p.addLine(to: CGPoint(x: legEnd, y: y))
            },
            with: .color(.init(white: 0.55)),
            lineWidth: 1.5
        )

        // Pin hole in body
        let holeCenter = CGPoint(x: x + (isLeft ? 1 : -1) * pinInset, y: y)
        context.fill(
            Circle().path(in: CGRect(
                x: holeCenter.x - pinRadius,
                y: holeCenter.y - pinRadius,
                width: pinRadius * 2,
                height: pinRadius * 2
            )),
            with: .color(.init(white: 0.08))
        )
        context.stroke(
            Circle().path(in: CGRect(
                x: holeCenter.x - pinRadius,
                y: holeCenter.y - pinRadius,
                width: pinRadius * 2,
                height: pinRadius * 2
            )),
            with: .color(color.opacity(0.6)),
            lineWidth: 1
        )

        // Pin number
        let numText = Text("\(number)")
            .font(.system(size: 7, weight: .medium, design: .monospaced))
            .foregroundColor(.init(white: 0.6))
        let numX = legEnd + dir * 8
        context.draw(context.resolve(numText), at: CGPoint(x: numX, y: y), anchor: .center)
    }

    // MARK: - Pin Function Labels

    private func drawPinLabels(context: GraphicsContext, cx: CGFloat, originY: CGFloat, size: CGSize) {
        let leftX = cx - bodyWidth / 2 - legLength
        let rightX = cx + bodyWidth / 2 + legLength
        let startY = originY + 18

        // Left side labels (pins 1-4 = I2C, 5-8 = SPI)
        let leftLabels = i2cLeftLabels + spiLeftLabels
        let rightLabels = i2cRightLabels + spiRightLabels

        for i in 0..<pinCount {
            let y = startY + CGFloat(i) * pinSpacing
            let isI2C = i < 4
            let color = isI2C ? i2cColor : spiColor

            // Left label
            let lText = Text(leftLabels[i])
                .font(.system(size: 7, weight: .medium, design: .monospaced))
                .foregroundColor(color.opacity(0.8))
            context.draw(context.resolve(lText), at: CGPoint(x: leftX - 14, y: y), anchor: .trailing)

            // Right label
            let rText = Text(rightLabels[i])
                .font(.system(size: 7, weight: .medium, design: .monospaced))
                .foregroundColor(color.opacity(0.8))
            context.draw(context.resolve(rText), at: CGPoint(x: rightX + 14, y: y), anchor: .leading)
        }
    }

    // MARK: - Legend

    @ViewBuilder
    private func legendItem(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color.opacity(0.5))
                .frame(width: 10, height: 10)
            Text(label)
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    VStack(spacing: 20) {
        ZIFSocketView(highlightMode: .none)
        HStack(spacing: 30) {
            ZIFSocketView(highlightMode: .i2c)
            ZIFSocketView(highlightMode: .spi)
        }
    }
    .padding(30)
    .background(.black)
    .preferredColorScheme(.dark)
}
