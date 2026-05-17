import ARKit
import simd

/// ViewModel: owns scan state, temporal smoothing and the mode/stage machine.
/// Communicates with the View through closures only — no UIKit / scene graph.
final class ScannerViewModel {

    enum Mode { case lidarAuto, interactive }
    enum Stage { case findingPlane, placeCorner1, placeCorner2, placeCorner3, setHeight, done }

    struct UIState {
        let actionTitle: String
        let actionEnabled: Bool
        let radiusSliderHidden: Bool
        let heightSliderHidden: Bool
    }

    // MARK: - Outputs (the View assigns these)

    var onStatus: ((String) -> Void)?
    var onMeasurement: ((BoxMeasurement) -> Void)?
    var onDims: ((Float, Float, Float) -> Void)?
    var onClearBox: (() -> Void)?
    var onAddMarker: ((SIMD3<Float>) -> Void)?
    var onClearMarkers: (() -> Void)?
    var onUIState: ((UIState) -> Void)?

    // MARK: - State

    let mode: Mode = ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
        ? .lidarAuto : .interactive
    var isLiDAR: Bool { mode == .lidarAuto }

    private var planeFound = false
    private var locked = false
    private var stage: Stage = .findingPlane

    var captureRadius: Float = 0.6
    var manualHeight: Float = 0.10

    private var lastAim: SIMD3<Float>?
    private var p1, p2, p3: SIMD3<Float>?

    private var planeAnchorY: [UUID: Float] = [:]
    private let planeLock = NSLock()
    private var planeYs: [Float] {
        planeLock.lock(); defer { planeLock.unlock() }
        return Array(planeAnchorY.values)
    }

    private typealias Sample = (l: Float, w: Float, h: Float,
                                c: SIMD3<Float>, x: SIMD3<Float>, z: SIMD3<Float>)
    private var history: [Sample] = []
    private let historyMax = 8

    private var processing = false
    private let scanQueue = DispatchQueue(label: "objectsize.scan", qos: .userInitiated)

    // MARK: - Lifecycle

    func start() {
        planeFound = false
        locked = false
        stage = .findingPlane
        history.removeAll()
        emitUI()
        onStatus?(initialStatus())
    }

    var isAiming: Bool {
        (mode == .lidarAuto && planeFound && !locked)
            || stage == .placeCorner1 || stage == .placeCorner2 || stage == .placeCorner3
    }

    func provideAimPoint(_ p: SIMD3<Float>?) { if let p { lastAim = p } }

    // MARK: - Plane tracking (called from the render thread)

    func planeAdded(id: UUID, y: Float) {
        planeLock.lock(); planeAnchorY[id] = y; planeLock.unlock()
        let first = !planeFound
        planeFound = true
        guard first else { return }
        DispatchQueue.main.async {
            if self.mode == .interactive, self.stage == .findingPlane {
                self.stage = .placeCorner1
            }
            self.emitUI()
            self.onStatus?(self.stageStatus())
        }
    }

    func planeUpdated(id: UUID, y: Float) {
        planeLock.lock(); planeAnchorY[id] = y; planeLock.unlock()
    }

    func planeRemoved(id: UUID) {
        planeLock.lock(); planeAnchorY[id] = nil; planeLock.unlock()
    }

    // MARK: - Depth ingest (called from the ARSession queue)

    func ingestDepth(depthMap: CVPixelBuffer, confidence: CVPixelBuffer?,
                     cameraTransform: simd_float4x4, intrinsics: simd_float3x3,
                     resolution: CGSize) {
        guard mode == .lidarAuto, planeFound, !locked, !processing else { return }
        processing = true
        let input = DepthFrameInput(
            depthMap: depthMap, confidenceMap: confidence,
            cameraTransform: cameraTransform, intrinsics: intrinsics,
            imageResolution: resolution, planeYs: planeYs,
            fallbackFloorY: lastAim?.y, maxSize: captureRadius)

        scanQueue.async { [weak self] in
            guard let self else { return }
            let outcome = ObjectScanner.scan(input)
            DispatchQueue.main.async {
                self.processing = false
                guard !self.locked else { return }
                switch outcome {
                case .failure(let msg): self.onStatus?(msg)
                case .measurement(let m): self.smoothAndEmit(m)
                }
            }
        }
    }

    // MARK: - Actions

    func actionTapped() {
        switch mode {
        case .lidarAuto:
            guard planeFound else { return }
            locked.toggle()
            if !locked { history.removeAll(); onClearBox?() }
            emitUI()
            onStatus?(locked ? "Locked" : stageStatus())
        case .interactive:
            interactiveAdvance()
        }
    }

    func reset() {
        locked = false
        history.removeAll()
        p1 = nil; p2 = nil; p3 = nil
        manualHeight = 0.10
        onClearBox?()
        onClearMarkers?()
        stage = planeFound ? .placeCorner1 : .findingPlane
        emitUI()
        onStatus?(stageStatus())
    }

    func setRadius(_ v: Float) { captureRadius = v }

    func setManualHeight(_ v: Float) {
        manualHeight = v
        rebuildInteractive()
    }

    // MARK: - Interactive flow

    private func interactiveAdvance() {
        switch stage {
        case .findingPlane:
            return
        case .placeCorner1:
            guard let a = lastAim else { return }
            p1 = a; onAddMarker?(a); stage = .placeCorner2
        case .placeCorner2:
            guard let a = lastAim else { return }
            p2 = a; onAddMarker?(a); stage = .placeCorner3
        case .placeCorner3:
            guard let a = lastAim else { return }
            p3 = a; onAddMarker?(a); stage = .setHeight
            rebuildInteractive()
        case .setHeight:
            stage = .done
        case .done:
            reset()
            return
        }
        emitUI()
        onStatus?(stageStatus())
    }

    private func rebuildInteractive() {
        guard mode == .interactive, let p1, let p2, let p3 else { return }
        if let m = ObjectScanner.interactiveBox(p1: p1, p2: p2, p3: p3, height: manualHeight) {
            onMeasurement?(m)
            onDims?(m.length, m.width, m.height)
        }
    }

    // MARK: - Temporal smoothing

    private func smoothAndEmit(_ m: BoxMeasurement) {
        guard !locked else { return }
        var xs = m.xAxis, zs = m.zAxis
        if let last = history.last {
            if simd_dot(xs, last.x) < 0 { xs = -xs }
            if simd_dot(zs, last.z) < 0 { zs = -zs }
        }
        history.append((m.length, m.width, m.height, m.center, xs, zs))
        if history.count > historyMax { history.removeFirst() }

        let cnt = Float(history.count)
        let L = history.reduce(0) { $0 + $1.l } / cnt
        let W = history.reduce(0) { $0 + $1.w } / cnt
        let H = history.reduce(0) { $0 + $1.h } / cnt
        var C = SIMD3<Float>(repeating: 0)
        var X = SIMD3<Float>(repeating: 0)
        var Z = SIMD3<Float>(repeating: 0)
        for s in history { C += s.c; X += s.x; Z += s.z }
        C /= cnt
        X = simd_length(X) > 1e-5 ? simd_normalize(X) : SIMD3<Float>(1, 0, 0)
        Z = simd_length(Z) > 1e-5 ? simd_normalize(Z) : SIMD3<Float>(0, 0, 1)

        onMeasurement?(BoxMeasurement(center: C, xAxis: X, zAxis: Z,
                                      length: L, width: W, height: H))
        onDims?(L, W, H)

        func sd(_ a: [Float], _ mn: Float) -> Float {
            sqrt(a.reduce(0) { $0 + ($1 - mn) * ($1 - mn) } / Float(a.count))
        }
        let stable = history.count >= 5
            && sd(history.map { $0.l }, L) < 0.006
            && sd(history.map { $0.w }, W) < 0.006
            && sd(history.map { $0.h }, H) < 0.006
        onStatus?(stable ? "Stable — tap Lock to keep this measurement"
                         : "Scanning… hold steady on the object")
    }

    // MARK: - UI text

    private func emitUI() {
        let s: UIState
        if mode == .lidarAuto {
            if !planeFound {
                s = UIState(actionTitle: "Detecting…", actionEnabled: false,
                            radiusSliderHidden: true, heightSliderHidden: true)
            } else {
                s = UIState(actionTitle: locked ? "Scan Again" : "Lock",
                            actionEnabled: true,
                            radiusSliderHidden: locked, heightSliderHidden: true)
            }
        } else {
            let title: String
            let enabled: Bool
            switch stage {
            case .findingPlane: title = "Detecting…"; enabled = false
            case .placeCorner1: title = "Set Corner 1"; enabled = true
            case .placeCorner2: title = "Set Corner 2"; enabled = true
            case .placeCorner3: title = "Set Corner 3"; enabled = true
            case .setHeight:    title = "Done"; enabled = true
            case .done:         title = "Scan Again"; enabled = true
            }
            s = UIState(actionTitle: title, actionEnabled: enabled,
                        radiusSliderHidden: true,
                        heightSliderHidden: stage != .setHeight)
        }
        onUIState?(s)
    }

    private func initialStatus() -> String {
        mode == .lidarAuto
            ? "LiDAR ready. Move the phone to scan the surface under the object"
            : "No LiDAR — move the phone to scan the surface"
    }

    private func stageStatus() -> String {
        if mode == .lidarAuto {
            if !planeFound { return initialStatus() }
            return locked ? "Locked" : "Scanning… hold steady on the object"
        }
        switch stage {
        case .findingPlane: return "No LiDAR — move the phone to scan the surface"
        case .placeCorner1: return "Aim at the FIRST bottom corner"
        case .placeCorner2: return "Aim at the SECOND bottom corner (length)"
        case .placeCorner3: return "Aim at a THIRD bottom corner (width)"
        case .setHeight:    return "Drag the slider to match the object's height"
        case .done:         return "Measurement complete"
        }
    }
}
