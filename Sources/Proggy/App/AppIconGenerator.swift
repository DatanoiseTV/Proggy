import AppKit

enum AppIconGenerator {
    static func setAppIcon() {
        guard let app = NSApp else { return }

        let size: CGFloat = 256
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }

            let inset: CGFloat = 12
            let body = rect.insetBy(dx: inset, dy: inset)

            // Background
            ctx.setFillColor(NSColor(calibratedRed: 0.11, green: 0.11, blue: 0.14, alpha: 1).cgColor)
            let bgPath = CGPath(roundedRect: body, cornerWidth: 40, cornerHeight: 40, transform: nil)
            ctx.addPath(bgPath)
            ctx.fillPath()

            // Border
            ctx.setStrokeColor(NSColor(white: 0.3, alpha: 0.6).cgColor)
            ctx.setLineWidth(2)
            ctx.addPath(bgPath)
            ctx.strokePath()

            // DIP chip body
            let chipW: CGFloat = 100
            let chipH: CGFloat = 140
            let chipX = body.midX - chipW / 2
            let chipY = body.midY - chipH / 2
            let chipRect = CGRect(x: chipX, y: chipY, width: chipW, height: chipH)

            ctx.setFillColor(NSColor(calibratedRed: 0.18, green: 0.18, blue: 0.22, alpha: 1).cgColor)
            let chipPath = CGPath(roundedRect: chipRect, cornerWidth: 6, cornerHeight: 6, transform: nil)
            ctx.addPath(chipPath)
            ctx.fillPath()

            ctx.setStrokeColor(NSColor(white: 0.4, alpha: 1).cgColor)
            ctx.setLineWidth(1.5)
            ctx.addPath(chipPath)
            ctx.strokePath()

            // Notch
            ctx.setFillColor(NSColor(calibratedRed: 0.11, green: 0.11, blue: 0.14, alpha: 1).cgColor)
            ctx.addArc(center: CGPoint(x: chipRect.midX, y: chipRect.maxY),
                       radius: 8, startAngle: .pi, endAngle: 0, clockwise: false)
            ctx.fillPath()

            // Pins (4 per side, top=cyan, bottom=orange)
            let pinColors: [CGColor] = [
                NSColor.systemCyan.cgColor, NSColor.systemCyan.cgColor,
                NSColor.systemOrange.cgColor, NSColor.systemOrange.cgColor,
            ]
            for i in 0..<4 {
                let y = chipRect.minY + 18 + CGFloat(i) * 30
                let pinH: CGFloat = 4

                // Left pins
                ctx.setFillColor(pinColors[i])
                ctx.fill(CGRect(x: chipRect.minX - 16, y: y - pinH/2, width: 16, height: pinH))
                // Right pins
                ctx.fill(CGRect(x: chipRect.maxX, y: y - pinH/2, width: 16, height: pinH))
            }

            // "P" on chip
            let font = NSFont.systemFont(ofSize: 64, weight: .bold)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.white.withAlphaComponent(0.9),
            ]
            let str = NSAttributedString(string: "P", attributes: attrs)
            let strSize = str.size()
            str.draw(at: NSPoint(x: chipRect.midX - strSize.width / 2,
                                 y: chipRect.midY - strSize.height / 2))

            // Lightning bolt
            ctx.setFillColor(NSColor.systemYellow.withAlphaComponent(0.85).cgColor)
            ctx.beginPath()
            ctx.move(to: CGPoint(x: 190, y: 180))
            ctx.addLine(to: CGPoint(x: 176, y: 145))
            ctx.addLine(to: CGPoint(x: 188, y: 150))
            ctx.addLine(to: CGPoint(x: 178, y: 115))
            ctx.addLine(to: CGPoint(x: 200, y: 158))
            ctx.addLine(to: CGPoint(x: 188, y: 153))
            ctx.closePath()
            ctx.fillPath()

            return true
        }

        app.applicationIconImage = image
    }
}
