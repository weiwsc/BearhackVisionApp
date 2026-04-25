//
//  ContentView.swift
//  vision app
//
//

import SwiftUI

var uiColor: Color = Color(red: 139/255, green: 206/255, blue: 81/255)

// MARK: - Root view

struct ContentView: View {
    @StateObject private var tracker      = ObjectTracker()
    @StateObject private var frameCapture = FrameCapture()

    @State private var selectedObject: ObjectTracker.TrackedObject?
    @State private var selectedImage:  UIImage?

    var body: some View {
        ZStack {
            ARViewContainer(tracker: tracker, frameCapture: frameCapture)
                .edgesIgnoringSafeArea(.all)

            DetectionOverlay(objects: tracker.objects) { tapped in
                if let buf = frameCapture.latestBuffer {
                    selectedImage = cropObjectImage(from: buf, visionBox: tapped.smoothedBox)
                }
                selectedObject = tapped
            }
            .edgesIgnoringSafeArea(.all)
        }
        .fullScreenCover(item: $selectedObject) { obj in
            DetailView(object: obj, image: selectedImage) {
                selectedObject = nil
                selectedImage  = nil
            }
        }
    }
}

// MARK: - Detection overlay (lines + labels)

struct DetectionOverlay: View {
    let objects: [ObjectTracker.TrackedObject]
    let onTap: (ObjectTracker.TrackedObject) -> Void

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                for obj in objects {
                    let from = center(obj, size: size)
                    let to   = lineEnd(obj, size: size)
                    var line = Path()
                    line.move(to: from); line.addLine(to: to)
                    ctx.stroke(line, with: .color(uiColor.opacity(0.25)),
                               style: StrokeStyle(lineWidth: 5))
                    ctx.stroke(line, with: .color(uiColor.opacity(0.9)),
                               style: StrokeStyle(lineWidth: 1))

                    let d: CGFloat = 5
                    var diamond = Path()
                    diamond.move(to: .init(x: from.x,     y: from.y - d))
                    diamond.addLine(to: .init(x: from.x + d, y: from.y))
                    diamond.addLine(to: .init(x: from.x,     y: from.y + d))
                    diamond.addLine(to: .init(x: from.x - d, y: from.y))
                    diamond.closeSubpath()
                    ctx.fill(diamond, with: .color(uiColor))
                    ctx.stroke(diamond, with: .color(.white.opacity(0.6)), lineWidth: 0.5)
                }
            }

            ForEach(objects) { obj in
                FantasyLabel(object: obj)
                    .frame(width: 170)
                    .position(labelPos(obj, size: geo.size))
                    .onTapGesture { onTap(obj) }
            }
        }
    }

    // MARK: Geometry helpers

    private func center(_ obj: ObjectTracker.TrackedObject, size: CGSize) -> CGPoint {
        CGPoint(x: obj.smoothedBox.midX * size.width,
                y: (1 - obj.smoothedBox.midY) * size.height)
    }

    private func labelPos(_ obj: ObjectTracker.TrackedObject, size: CGSize) -> CGPoint {
        let c = center(obj, size: size)
        let goRight = c.x < size.width / 2
        let x = min(max(c.x + (goRight ? 170 : -170), 90), size.width - 90)
        let y = min(max(c.y, 70), size.height - 70)
        return CGPoint(x: x, y: y)
    }

    private func lineEnd(_ obj: ObjectTracker.TrackedObject, size: CGSize) -> CGPoint {
        let lp = labelPos(obj, size: size)
        let c  = center(obj, size: size)
        return CGPoint(x: lp.x + (c.x < size.width / 2 ? -85 : 85), y: lp.y)
    }
}

// MARK: - Compact fantasy label

struct FantasyLabel: View {
    let object: ObjectTracker.TrackedObject

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // Header
            HStack(spacing: 5) {
                Image(systemName: "diamond.fill")
                    .font(.system(size: 7))
                    .foregroundColor(uiColor)
                Text(object.label.uppercased())
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
                    .tracking(2)
                Spacer()
                Text("\(Int(object.confidence * 100))%")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(uiColor.opacity(0.8))
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 6)

            // Divider
            HStack(spacing: 3) {
                Rectangle().frame(width: 4, height: 1)
                Rectangle().frame(height: 1)
                Rectangle().frame(width: 4, height: 1)
            }
            .foregroundColor(uiColor.opacity(0.6))
            .padding(.horizontal, 8)

            // Body
            VStack(alignment: .leading, spacing: 4) {
                Text("[ ENTITY DETECTED ]")
                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                    .foregroundColor(uiColor.opacity(0.7))
                    .tracking(1)
                Text("Origin: Unknown\nClass: \(object.label)\nThreat level: —")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.white.opacity(0.55))
                    .lineSpacing(3)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            // Footer
            Rectangle()
                .fill(uiColor.opacity(0.15))
                .frame(height: 18)
                .overlay(
                    Text("▸ TAP TO INSPECT")
                        .font(.system(size: 7, weight: .medium, design: .monospaced))
                        .foregroundColor(uiColor.opacity(0.6))
                        .tracking(1.5)
                )
        }
        .background(Color.black.opacity(0.78))
        .overlay(
            ZStack {
                Rectangle().stroke(uiColor.opacity(0.55), lineWidth: 1)
                CornerAccents().stroke(uiColor, lineWidth: 1.5)
            }
        )
        .shadow(color: uiColor.opacity(0.5), radius: 6)
        .shadow(color: uiColor.opacity(0.2), radius: 14)
    }
}

// MARK: - Full-screen detail view

struct DetailView: View {
    let object:    ObjectTracker.TrackedObject
    let image:     UIImage?
    let onDismiss: () -> Void

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.edgesIgnoringSafeArea(.all)

            VStack(spacing: 0) {
                Color.clear.frame(height: 48)

                // Captured image
                ZStack {
                    Color(white: 0.06)
                    if let img = image {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFit()
                    } else {
                        VStack(spacing: 8) {
                            Image(systemName: "viewfinder")
                                .font(.system(size: 40))
                                .foregroundColor(uiColor.opacity(0.35))
                            Text("NO CAPTURE")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(uiColor.opacity(0.35))
                                .tracking(2)
                        }
                    }
                    CornerAccents(length: 20)
                        .stroke(uiColor, lineWidth: 2)
                        .padding(10)
                        .shadow(color: uiColor.opacity(0.7), radius: 8)
                }
                .frame(maxWidth: .infinity)
                .frame(height: UIScreen.main.bounds.height * 0.42)

                Rectangle()
                    .fill(uiColor.opacity(0.35))
                    .frame(height: 1)

                // Scrollable info
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {

                        InfoSection(title: "IDENTIFICATION") {
                            InfoRow(key: "Entity",     value: object.label.uppercased())
                            InfoRow(key: "Confidence", value: "\(Int(object.confidence * 100))%")
                            InfoRow(key: "Status",     value: "Active")
                            InfoRow(key: "Origin",     value: "Unknown")
                        }

                        sectionDivider

                        InfoSection(title: "CLASSIFICATION") {
                            InfoRow(key: "Type",         value: "—")
                            InfoRow(key: "Class",        value: object.label.uppercased())
                            InfoRow(key: "Subclass",     value: "Unknown")
                            InfoRow(key: "Threat level", value: "—")
                        }

                        sectionDivider

                        InfoSection(title: "ANALYSIS") {
                            InfoRow(key: "Dimensions", value: "—")
                            InfoRow(key: "Material",   value: "—")
                            InfoRow(key: "Condition",  value: "—")
                            InfoRow(key: "Est. mass",  value: "—")
                        }

                        sectionDivider

                        InfoSection(title: "NOTES") {
                            Text("No additional data available.\nScanning database...")
                                .font(.system(size: 10, design: .monospaced))
                                .italic()
                                .foregroundColor(.white.opacity(0.35))
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                        }

                        sectionDivider

                        // API button (placeholder)
                        Button(action: {}) {
                            HStack(spacing: 8) {
                                Image(systemName: "arrow.up.circle")
                                Text("SEND TO API")
                                    .tracking(2)
                            }
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundColor(.black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                            .background(uiColor.opacity(0.85))
                            .overlay(CornerAccents(length: 6).stroke(Color.white.opacity(0.4), lineWidth: 1))
                        }
                        .padding(16)
                        .shadow(color: uiColor.opacity(0.5), radius: 8)

                        Color.clear.frame(height: 20)
                    }
                }
            }

            // Top bar
            HStack(spacing: 8) {
                Image(systemName: "diamond.fill")
                    .font(.system(size: 8))
                    .foregroundColor(uiColor)
                Text("ENTITY ANALYSIS")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(uiColor)
                    .tracking(2)
                Spacer()
                Button(action: onDismiss) {
                    ZStack {
                        Rectangle()
                            .fill(uiColor.opacity(0.15))
                            .frame(width: 36, height: 36)
                            .overlay(Rectangle().stroke(uiColor.opacity(0.5), lineWidth: 1))
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(uiColor)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(Color.black.opacity(0.9))
            .overlay(Rectangle().stroke(uiColor.opacity(0.2), lineWidth: 1), alignment: .bottom)
        }
    }

    private var sectionDivider: some View {
        HStack(spacing: 4) {
            Rectangle().frame(width: 8, height: 1)
            Rectangle().frame(height: 1)
            Rectangle().frame(width: 8, height: 1)
        }
        .foregroundColor(uiColor.opacity(0.2))
        .padding(.horizontal, 16)
    }
}

// MARK: - Reusable info components

struct InfoSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("[ \(title) ]")
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundColor(uiColor.opacity(0.75))
                .tracking(1.5)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 6)
            content()
        }
    }
}

struct InfoRow: View {
    let key:   String
    let value: String

    var body: some View {
        HStack {
            Text(key)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.white.opacity(0.4))
            Spacer()
            Text(value)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(.white.opacity(0.85))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }
}

// MARK: - Corner accents shape

struct CornerAccents: Shape {
    var length: CGFloat = 8

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let l = length
        p.move(to: .init(x: rect.minX,     y: rect.minY + l)); p.addLine(to: .init(x: rect.minX,     y: rect.minY)); p.addLine(to: .init(x: rect.minX + l, y: rect.minY))
        p.move(to: .init(x: rect.maxX - l, y: rect.minY));     p.addLine(to: .init(x: rect.maxX,     y: rect.minY)); p.addLine(to: .init(x: rect.maxX,     y: rect.minY + l))
        p.move(to: .init(x: rect.maxX,     y: rect.maxY - l)); p.addLine(to: .init(x: rect.maxX,     y: rect.maxY)); p.addLine(to: .init(x: rect.maxX - l, y: rect.maxY))
        p.move(to: .init(x: rect.minX + l, y: rect.maxY));     p.addLine(to: .init(x: rect.minX,     y: rect.maxY)); p.addLine(to: .init(x: rect.minX,     y: rect.maxY - l))
        return p
    }
}

#Preview {
    ContentView()
}
