import UIKit
import ARKit
import Vision

class ViewController: UIViewController {

    private let sceneView = ARSCNView()
    private let overlayLayer = CAShapeLayer()
    private let measurementLabel = UILabel()
    private let statusLabel = UILabel()
    private var detectionRequest: VNDetectRectanglesRequest!
    private var isProcessingFrame = false

    override func viewDidLoad() {
        super.viewDidLoad()
        setupSceneView()
        setupOverlay()
        setupLabels()
        setupVision()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        overlayLayer.frame = view.bounds
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        guard ARWorldTrackingConfiguration.isSupported else {
            statusLabel.text = "ARKit not supported on this device"
            return
        }
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal, .vertical]
        sceneView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        sceneView.session.pause()
    }

    // MARK: - Setup

    private func setupSceneView() {
        sceneView.frame = view.bounds
        sceneView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        sceneView.delegate = self
        sceneView.session.delegate = self
        sceneView.automaticallyUpdatesLighting = true
        view.addSubview(sceneView)
    }

    private func setupOverlay() {
        overlayLayer.strokeColor = UIColor.systemGreen.cgColor
        overlayLayer.fillColor = UIColor.systemGreen.withAlphaComponent(0.15).cgColor
        overlayLayer.lineWidth = 3
        overlayLayer.lineCap = .round
        overlayLayer.lineJoin = .round
        view.layer.addSublayer(overlayLayer)
    }

    private func setupLabels() {
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.text = "Point camera at a flat rectangular object"
        statusLabel.textColor = .white
        statusLabel.font = .systemFont(ofSize: 15, weight: .medium)
        statusLabel.textAlignment = .center
        statusLabel.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        statusLabel.layer.cornerRadius = 10
        statusLabel.clipsToBounds = true
        view.addSubview(statusLabel)

        measurementLabel.translatesAutoresizingMaskIntoConstraints = false
        measurementLabel.textColor = .white
        measurementLabel.font = .monospacedSystemFont(ofSize: 26, weight: .bold)
        measurementLabel.textAlignment = .center
        measurementLabel.backgroundColor = UIColor.black.withAlphaComponent(0.7)
        measurementLabel.layer.cornerRadius = 14
        measurementLabel.clipsToBounds = true
        measurementLabel.numberOfLines = 2
        measurementLabel.alpha = 0
        view.addSubview(measurementLabel)

        NSLayoutConstraint.activate([
            statusLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            statusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 20),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -20),
            statusLabel.heightAnchor.constraint(equalToConstant: 44),

            measurementLabel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -28),
            measurementLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            measurementLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            measurementLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
        ])
    }

    private func setupVision() {
        detectionRequest = VNDetectRectanglesRequest(completionHandler: handleDetection)
        detectionRequest.minimumConfidence = 0.75
        detectionRequest.minimumAspectRatio = 0.2
        detectionRequest.maximumObservations = 1
        detectionRequest.minimumSize = 0.08
    }

    // MARK: - Frame processing

    private func processFrame(_ frame: ARFrame) {
        guard !isProcessingFrame else { return }
        isProcessingFrame = true

        let pixelBuffer = frame.capturedImage
        // .right tells Vision that the pixel buffer is in landscape with top on the right
        // (standard ARKit capture orientation when device is held in portrait)
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer,
                                            orientation: .right,
                                            options: [:])
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            try? handler.perform([self.detectionRequest])
            self.isProcessingFrame = false
        }
    }

    // MARK: - Detection handler

    private func handleDetection(request: VNRequest, error: Error?) {
        guard let observations = request.results as? [VNRectangleObservation],
              let rect = observations.first else {
            DispatchQueue.main.async { [weak self] in
                self?.clearOverlay()
            }
            return
        }

        DispatchQueue.main.async { [weak self] in
            self?.processObservation(rect)
        }
    }

    // MARK: - Overlay & measurement

    private func processObservation(_ observation: VNRectangleObservation) {
        let bounds = sceneView.bounds

        // Vision uses bottom-left origin; UIKit uses top-left origin.
        // With .right orientation the x/y axes already match portrait display axes.
        func toScreen(_ p: CGPoint) -> CGPoint {
            CGPoint(x: p.x * bounds.width, y: (1 - p.y) * bounds.height)
        }

        let tl = toScreen(observation.topLeft)
        let tr = toScreen(observation.topRight)
        let br = toScreen(observation.bottomRight)
        let bl = toScreen(observation.bottomLeft)

        drawOverlay(tl: tl, tr: tr, br: br, bl: bl)
        measure(tl: tl, tr: tr, bl: bl)
    }

    private func drawOverlay(tl: CGPoint, tr: CGPoint, br: CGPoint, bl: CGPoint) {
        let path = UIBezierPath()
        path.move(to: tl)
        path.addLine(to: tr)
        path.addLine(to: br)
        path.addLine(to: bl)
        path.close()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        overlayLayer.path = path.cgPath
        CATransaction.commit()
    }

    private func measure(tl: CGPoint, tr: CGPoint, bl: CGPoint) {
        func raycast(_ screenPoint: CGPoint) -> SIMD3<Float>? {
            guard let query = sceneView.raycastQuery(from: screenPoint,
                                                     allowing: .estimatedPlane,
                                                     alignment: .any) else { return nil }
            guard let result = sceneView.session.raycast(query).first else { return nil }
            let col = result.worldTransform.columns.3
            return SIMD3(col.x, col.y, col.z)
        }

        guard let p0 = raycast(tl),
              let p1 = raycast(tr),
              let p2 = raycast(bl) else {
            statusLabel.text = "Move closer to a flat surface"
            measurementLabel.alpha = 0
            return
        }

        let widthCm  = simd_distance(p0, p1) * 100
        let heightCm = simd_distance(p0, p2) * 100

        statusLabel.text = "Object detected"
        measurementLabel.text = String(format: "W: %.1f cm\nH: %.1f cm", widthCm, heightCm)
        UIView.animate(withDuration: 0.2) { self.measurementLabel.alpha = 1 }
    }

    private func clearOverlay() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        overlayLayer.path = nil
        CATransaction.commit()
        statusLabel.text = "Point camera at a flat rectangular object"
        UIView.animate(withDuration: 0.3) { self.measurementLabel.alpha = 0 }
    }
}

// MARK: - ARSCNViewDelegate

extension ViewController: ARSCNViewDelegate {}

// MARK: - ARSessionDelegate

extension ViewController: ARSessionDelegate {
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        processFrame(frame)
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            self?.statusLabel.text = "AR session error — restart the app"
        }
    }

    func sessionWasInterrupted(_ session: ARSession) {
        DispatchQueue.main.async { [weak self] in
            self?.statusLabel.text = "Session interrupted"
        }
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal, .vertical]
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
    }
}
