import UIKit
import ARKit
import SceneKit

/// View: owns the AR scene + controls, forwards input to the ViewModel and
/// renders whatever the ViewModel publishes through its closures.
class ViewController: UIViewController {

    private let vm = ScannerViewModel()

    private let sceneView = ARSCNView()
    private let statusLabel = UILabel()
    private let dimsLabel = UILabel()
    private let actionButton = UIButton(type: .system)
    private let resetButton = UIButton(type: .system)
    private let radiusSlider = UISlider()
    private let heightSlider = UISlider()

    private var boxNode: SCNNode?
    private var markerNodes: [SCNNode] = []

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        setupSceneView()
        setupUI()
        bindViewModel()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        guard ARWorldTrackingConfiguration.isSupported else {
            statusLabel.text = "ARKit not supported on this device"
            return
        }
        startSession()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        sceneView.session.pause()
    }

    private func startSession() {
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal]
        if vm.isLiDAR {
            config.frameSemantics =
                ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth)
                ? .smoothedSceneDepth : .sceneDepth
        }
        sceneView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
        vm.start()
    }

    // MARK: - Binding

    private func bindViewModel() {
        vm.onStatus = { [weak self] text in
            self?.statusLabel.text = text
        }
        vm.onMeasurement = { [weak self] m in
            guard let self else { return }
            self.boxNode?.removeFromParentNode()
            if let node = BoxNodeFactory.make(m) {
                self.sceneView.scene.rootNode.addChildNode(node)
                self.boxNode = node
            }
        }
        vm.onDims = { [weak self] l, w, h in
            guard let self else { return }
            self.dimsLabel.text = String(format: "Length: %.1f cm\nWidth:  %.1f cm\nHeight: %.1f cm",
                                         l * 100, w * 100, h * 100)
            if self.dimsLabel.alpha == 0 {
                UIView.animate(withDuration: 0.2) { self.dimsLabel.alpha = 1 }
            }
        }
        vm.onClearBox = { [weak self] in
            guard let self else { return }
            self.boxNode?.removeFromParentNode(); self.boxNode = nil
            UIView.animate(withDuration: 0.25) { self.dimsLabel.alpha = 0 }
        }
        vm.onAddMarker = { [weak self] pos in
            guard let self else { return }
            let n = BoxNodeFactory.marker(at: pos)
            self.sceneView.scene.rootNode.addChildNode(n)
            self.markerNodes.append(n)
        }
        vm.onClearMarkers = { [weak self] in
            self?.markerNodes.forEach { $0.removeFromParentNode() }
            self?.markerNodes.removeAll()
        }
        vm.onUIState = { [weak self] s in
            guard let self else { return }
            self.actionButton.setTitle(s.actionTitle, for: .normal)
            self.actionButton.isEnabled = s.actionEnabled
            self.radiusSlider.isHidden = s.radiusSliderHidden
            self.heightSlider.isHidden = s.heightSliderHidden
        }
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

    private func setupUI() {
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.textColor = .white
        statusLabel.font = .systemFont(ofSize: 15, weight: .medium)
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 2
        statusLabel.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        statusLabel.layer.cornerRadius = 10
        statusLabel.clipsToBounds = true
        view.addSubview(statusLabel)

        dimsLabel.translatesAutoresizingMaskIntoConstraints = false
        dimsLabel.textColor = .white
        dimsLabel.font = .monospacedSystemFont(ofSize: 22, weight: .bold)
        dimsLabel.textAlignment = .center
        dimsLabel.numberOfLines = 3
        dimsLabel.backgroundColor = UIColor.black.withAlphaComponent(0.7)
        dimsLabel.layer.cornerRadius = 14
        dimsLabel.clipsToBounds = true
        dimsLabel.alpha = 0
        view.addSubview(dimsLabel)

        actionButton.translatesAutoresizingMaskIntoConstraints = false
        actionButton.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        actionButton.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.9)
        actionButton.setTitleColor(.white, for: .normal)
        actionButton.layer.cornerRadius = 26
        actionButton.addTarget(self, action: #selector(actionTapped), for: .touchUpInside)
        view.addSubview(actionButton)

        resetButton.translatesAutoresizingMaskIntoConstraints = false
        resetButton.setTitle("Reset", for: .normal)
        resetButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .medium)
        resetButton.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        resetButton.setTitleColor(.white, for: .normal)
        resetButton.layer.cornerRadius = 18
        resetButton.addTarget(self, action: #selector(resetTapped), for: .touchUpInside)
        view.addSubview(resetButton)

        radiusSlider.translatesAutoresizingMaskIntoConstraints = false
        radiusSlider.minimumValue = 0.10
        radiusSlider.maximumValue = 2.00
        radiusSlider.value = vm.captureRadius
        radiusSlider.isHidden = true
        radiusSlider.addTarget(self, action: #selector(radiusChanged), for: .valueChanged)
        view.addSubview(radiusSlider)

        heightSlider.translatesAutoresizingMaskIntoConstraints = false
        heightSlider.minimumValue = 0.01
        heightSlider.maximumValue = 2.0
        heightSlider.value = vm.manualHeight
        heightSlider.isHidden = true
        heightSlider.addTarget(self, action: #selector(heightChanged), for: .valueChanged)
        view.addSubview(heightSlider)

        NSLayoutConstraint.activate([
            statusLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            statusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 16),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -16),
            statusLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),

            dimsLabel.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 12),
            dimsLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            dimsLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 220),
            dimsLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 96),

            radiusSlider.bottomAnchor.constraint(equalTo: heightSlider.topAnchor, constant: -16),
            radiusSlider.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 40),
            radiusSlider.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -40),

            heightSlider.bottomAnchor.constraint(equalTo: actionButton.topAnchor, constant: -20),
            heightSlider.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 40),
            heightSlider.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -40),

            actionButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
            actionButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            actionButton.widthAnchor.constraint(equalToConstant: 220),
            actionButton.heightAnchor.constraint(equalToConstant: 52),

            resetButton.centerYAnchor.constraint(equalTo: actionButton.centerYAnchor),
            resetButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            resetButton.widthAnchor.constraint(equalToConstant: 72),
            resetButton.heightAnchor.constraint(equalToConstant: 36),
        ])
    }

    // MARK: - Control actions → ViewModel

    @objc private func actionTapped() { vm.actionTapped() }
    @objc private func resetTapped() { vm.reset() }
    @objc private func radiusChanged() { vm.setRadius(radiusSlider.value) }
    @objc private func heightChanged() { vm.setManualHeight(heightSlider.value) }

    // MARK: - Aim raycast (needs the scene, so it lives in the View)

    private func centerWorldPoint() -> SIMD3<Float>? {
        let center = CGPoint(x: sceneView.bounds.midX, y: sceneView.bounds.midY)
        for target: ARRaycastQuery.Target in [.existingPlaneGeometry, .estimatedPlane] {
            if let q = sceneView.raycastQuery(from: center, allowing: target, alignment: .horizontal),
               let r = sceneView.session.raycast(q).first {
                let c = r.worldTransform.columns.3
                return SIMD3(c.x, c.y, c.z)
            }
        }
        return nil
    }
}

// MARK: - ARSCNViewDelegate

extension ViewController: ARSCNViewDelegate {

    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        DispatchQueue.main.async {
            guard self.vm.isAiming else { return }
            self.vm.provideAimPoint(self.centerWorldPoint())
        }
    }

    func renderer(_ renderer: SCNSceneRenderer, didAdd node: SCNNode, for anchor: ARAnchor) {
        guard let p = anchor as? ARPlaneAnchor, p.alignment == .horizontal else { return }
        vm.planeAdded(id: p.identifier, y: p.transform.columns.3.y)
    }

    func renderer(_ renderer: SCNSceneRenderer, didUpdate node: SCNNode, for anchor: ARAnchor) {
        guard let p = anchor as? ARPlaneAnchor, p.alignment == .horizontal else { return }
        vm.planeUpdated(id: p.identifier, y: p.transform.columns.3.y)
    }

    func renderer(_ renderer: SCNSceneRenderer, didRemove node: SCNNode, for anchor: ARAnchor) {
        if let p = anchor as? ARPlaneAnchor { vm.planeRemoved(id: p.identifier) }
    }
}

// MARK: - ARSessionDelegate

extension ViewController: ARSessionDelegate {

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard let depth = frame.smoothedSceneDepth ?? frame.sceneDepth else { return }
        vm.ingestDepth(depthMap: depth.depthMap,
                       confidence: depth.confidenceMap,
                       cameraTransform: frame.camera.transform,
                       intrinsics: frame.camera.intrinsics,
                       resolution: frame.camera.imageResolution)
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        DispatchQueue.main.async { self.statusLabel.text = "AR error — restart the app" }
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        startSession()
    }
}
