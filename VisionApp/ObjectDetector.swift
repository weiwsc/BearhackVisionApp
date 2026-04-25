//
//  ObjectDetector.swift
//  ar_test1
//

import SwiftUI
import Combine
import ARKit
import RealityKit
import Vision
import CoreML
import CoreImage

// MARK: - Raw detection result

struct DetectedObject: Identifiable {
    let id = UUID()
    let label: String
    let confidence: Float
    let boundingBox: CGRect  // Vision normalized, origin bottom-left
}

// MARK: - Shared frame buffer (read on tap, not observed for UI)

final class FrameCapture: ObservableObject {
    var latestBuffer: CVPixelBuffer?
}

// MARK: - Stable object tracker with smoothed positions

final class ObjectTracker: ObservableObject {
    @Published private(set) var objects: [TrackedObject] = []

    private let smoothFactor: CGFloat = 0.3
    private let minIoU: CGFloat      = 0.15
    private let maxAge: TimeInterval = 1.2

    struct TrackedObject: Identifiable {
        let id: UUID              // stable across frames → ForEach won't recreate views
        var label: String
        var confidence: Float
        var smoothedBox: CGRect   // lerp'd toward each new detection
        var lastSeen: Date
    }

    func update(with detections: [DetectedObject]) {
        let now = Date()
        var updated = objects
        var usedIndices = IndexSet()

        for det in detections {
            // Find the closest existing track for this label
            var bestIdx: Int?
            var bestScore: CGFloat = minIoU

            for i in updated.indices where !usedIndices.contains(i) && updated[i].label == det.label {
                let score = iou(updated[i].smoothedBox, det.boundingBox)
                if score > bestScore { bestScore = score; bestIdx = i }
            }

            if let idx = bestIdx {
                updated[idx].smoothedBox = lerp(updated[idx].smoothedBox, det.boundingBox, t: smoothFactor)
                updated[idx].confidence  = det.confidence
                updated[idx].lastSeen    = now
                usedIndices.insert(idx)
            } else {
                updated.append(TrackedObject(id: UUID(), label: det.label,
                                             confidence: det.confidence,
                                             smoothedBox: det.boundingBox, lastSeen: now))
            }
        }

        // Drop objects not seen recently
        updated = updated.filter { -$0.lastSeen.timeIntervalSinceNow < maxAge }

        withAnimation(.easeOut(duration: 0.15)) { objects = updated }
    }

    private func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let inter = a.intersection(b)
        guard !inter.isNull else { return 0 }
        let i = inter.width * inter.height
        let u = a.width * a.height + b.width * b.height - i
        return u > 0 ? i / u : 0
    }

    private func lerp(_ a: CGRect, _ b: CGRect, t: CGFloat) -> CGRect {
        CGRect(x: a.minX + (b.minX - a.minX) * t,
               y: a.minY + (b.minY - a.minY) * t,
               width:  a.width  + (b.width  - a.width)  * t,
               height: a.height + (b.height - a.height) * t)
    }
}

// MARK: - Crop helper (used when a label is tapped)

func cropObjectImage(from buffer: CVPixelBuffer, visionBox: CGRect) -> UIImage? {
    // .oriented(.right) rotates the landscape camera frame to portrait
    let ci = CIImage(cvPixelBuffer: buffer).oriented(.right)
    let ex = ci.extent
    let crop = CGRect(x: ex.origin.x + visionBox.minX * ex.width,
                      y: ex.origin.y + visionBox.minY * ex.height,
                      width:  visionBox.width  * ex.width,
                      height: visionBox.height * ex.height)
    let cropped = ci.cropped(to: crop)
    guard let cg = CIContext().createCGImage(cropped, from: cropped.extent) else { return nil }
    return UIImage(cgImage: cg)
}

// MARK: - ARSession delegate / detection coordinator

final class ObjectDetectionCoordinator: NSObject, ARSessionDelegate {
    let tracker: ObjectTracker
    let frameCapture: FrameCapture

    private var lastProcessingTime: TimeInterval = 0
    private let processingInterval: TimeInterval = 0.3
    private let visionModel: VNCoreMLModel

    init(tracker: ObjectTracker, frameCapture: FrameCapture) {
        self.tracker      = tracker
        self.frameCapture = frameCapture
        let cfg = MLModelConfiguration()
        cfg.computeUnits = .all
        self.visionModel = try! VNCoreMLModel(for: YOLOv3Int8LUT(configuration: cfg).model)
        super.init()
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        frameCapture.latestBuffer = frame.capturedImage   // always store latest

        let now = frame.timestamp
        guard now - lastProcessingTime >= processingInterval else { return }
        lastProcessingTime = now
        detect(frame.capturedImage)
    }

    private func detect(_ pixelBuffer: CVPixelBuffer) {
        let req = VNCoreMLRequest(model: visionModel) { [weak self] r, _ in
            guard let self,
                  let results = r.results as? [VNRecognizedObjectObservation] else { return }

            // 1. Filter by confidence
            let filtered = results
                .filter { $0.confidence > 0.4 }
                .compactMap { obs -> DetectedObject? in
                    guard let top = obs.labels.first else { return nil }
                    return DetectedObject(label: top.identifier.capitalized,
                                         confidence: obs.confidence,
                                         boundingBox: obs.boundingBox)
                }

            // 2. Cross-class NMS: drop boxes that overlap heavily with a higher-confidence box
            let sorted = filtered.sorted { $0.confidence > $1.confidence }
            var kept: [DetectedObject] = []
            for candidate in sorted {
                let overlapsKept = kept.contains {
                    self.iou($0.boundingBox, candidate.boundingBox) > 0.85
                }
                if !overlapsKept { kept.append(candidate) }
            }

            // 3. Drop objects that are mostly out of frame
            //    Person/Face are allowed to be up to 50% out of frame (common at edges)
            //    Everything else must be at least 75% visible
            let frame = CGRect(x: 0, y: 0, width: 1, height: 1)
            let edgeLabels: Set<String> = ["Person", "Face"]
            let inFrame = kept.filter { obj in
                let inter = obj.boundingBox.intersection(frame)
                guard !inter.isNull else { return false }
                let visible = (inter.width * inter.height) / (obj.boundingBox.width * obj.boundingBox.height)
                let threshold: CGFloat = edgeLabels.contains(obj.label) ? 0.5 : 0.75
                return visible >= threshold
            }

            // 4. Keep only the top 4 most confident
            let items = Array(inFrame.prefix(4))

            DispatchQueue.main.async { self.tracker.update(with: items) }
        }
        req.imageCropAndScaleOption = .scaleFill
        try? VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right).perform([req])
    }

    private func iou(_ a: CGRect, _ b: CGRect) -> Float {
        let inter = a.intersection(b)
        guard !inter.isNull else { return 0 }
        let i = Float(inter.width * inter.height)
        let u = Float(a.width * a.height + b.width * b.height) - i
        return u > 0 ? i / u : 0
    }
}

// MARK: - UIViewRepresentable wrapper

struct ARViewContainer: UIViewRepresentable {
    let tracker: ObjectTracker
    let frameCapture: FrameCapture

    func makeCoordinator() -> ObjectDetectionCoordinator {
        ObjectDetectionCoordinator(tracker: tracker, frameCapture: frameCapture)
    }

    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero)
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal]
        arView.session.delegate = context.coordinator
        arView.session.run(config)

        let anchor = AnchorEntity(.plane(.horizontal, classification: .any,
                                        minimumBounds: SIMD2<Float>(0.2, 0.2)))
        let mesh     = MeshResource.generateBox(size: 0.1, cornerRadius: 0.005)
        let material = SimpleMaterial(color: .gray, roughness: 0.15, isMetallic: true)
        let model    = ModelEntity(mesh: mesh, materials: [material])
        model.position = [0, 0.05, 0]
        anchor.addChild(model)
        arView.scene.addAnchor(anchor)
        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {}
}
