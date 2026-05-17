import ARKit
import simd

/// Inputs needed to segment & measure one object from a LiDAR depth frame.
struct DepthFrameInput {
    let depthMap: CVPixelBuffer
    let confidenceMap: CVPixelBuffer?
    let cameraTransform: simd_float4x4
    let intrinsics: simd_float3x3
    let imageResolution: CGSize
    let planeYs: [Float]
    let fallbackFloorY: Float?
    let maxSize: Float          // max object size (m) — bounds the region grow
}

enum ScanOutcome {
    case measurement(BoxMeasurement)
    case failure(String)        // user-facing reason it couldn't measure
}

/// Model: pure geometry. Turns a depth frame into an oriented box, and builds
/// the interactive (non-LiDAR) box from 3 corners. No UIKit / scene graph here.
enum ObjectScanner {

    /// 5 mm band above the surface counts as surface — small enough that a phone
    /// (~8 mm) survives, large enough to reject most smoothed LiDAR floor noise.
    private static let bandThin: Float = 0.005

    static func scan(_ input: DepthFrameInput) -> ScanOutcome {
        let depthMap = input.depthMap
        let dw = CVPixelBufferGetWidth(depthMap)
        let dh = CVPixelBufferGetHeight(depthMap)
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
        guard let baseAddr = CVPixelBufferGetBaseAddress(depthMap) else {
            return .failure("Depth unavailable")
        }
        let rowBytes = CVPixelBufferGetBytesPerRow(depthMap)

        var confBase: UnsafeMutableRawPointer?
        var confRow = 0
        if let confMap = input.confidenceMap {
            CVPixelBufferLockBaseAddress(confMap, .readOnly)
            confBase = CVPixelBufferGetBaseAddress(confMap)
            confRow = CVPixelBufferGetBytesPerRow(confMap)
        }
        defer {
            if let confMap = input.confidenceMap {
                CVPixelBufferUnlockBaseAddress(confMap, .readOnly)
            }
        }
        let lowConf = ARConfidenceLevel.low.rawValue

        let K = input.intrinsics
        let res = input.imageResolution
        let camT = input.cameraTransform
        let sx = Float(dw) / Float(res.width)
        let sy = Float(dh) / Float(res.height)
        let fx = K.columns.0.x * sx
        let fy = K.columns.1.y * sy
        let cx = K.columns.2.x * sx
        let cy = K.columns.2.y * sy

        // 1) Guess the floor BEFORE sampling so the seed lands on the object.
        var approxFloor = input.fallbackFloorY ?? -Float.greatestFiniteMagnitude
        if approxFloor == -Float.greatestFiniteMagnitude {
            approxFloor = input.planeYs.max() ?? -Float.greatestFiniteMagnitude
        }
        let haveFloorGuess = approxFloor > -Float.greatestFiniteMagnitude

        var pts: [SIMD3<Float>] = []
        pts.reserveCapacity(50000)
        var seed: SIMD3<Float>?
        var seedBestD2 = Float.greatestFiniteMagnitude
        let ccx = Float(dw) * 0.5, ccy = Float(dh) * 0.5

        var v = 0
        while v < dh {
            let row = baseAddr.advanced(by: v * rowBytes).assumingMemoryBound(to: Float32.self)
            let cRow = confBase?.advanced(by: v * confRow).assumingMemoryBound(to: UInt8.self)
            var u = 0
            while u < dw {
                if let cRow, Int(cRow[u]) <= lowConf { u += 1; continue }
                let z = row[u]
                if z > 0.05 && z < 5.0 {
                    let px = (Float(u) - cx) / fx * z
                    let py = (Float(v) - cy) / fy * z
                    let w4 = camT * SIMD4<Float>(px, -py, -z, 1)
                    let wp = SIMD3<Float>(w4.x, w4.y, w4.z)
                    pts.append(wp)
                    let aboveSurface = !haveFloorGuess || (wp.y - approxFloor) > bandThin
                    if aboveSurface {
                        let du = Float(u) - ccx, dv = Float(v) - ccy
                        let d2 = du * du + dv * dv
                        if d2 < seedBestD2 { seedBestD2 = d2; seed = wp }
                    }
                }
                u += 1
            }
            v += 1
        }

        guard let seedPt = seed, pts.count > 200 else {
            return .failure("Aim at the object — move a little closer")
        }

        // 2) Precise resting surface = highest tracked plane just below the seed.
        var floorY = haveFloorGuess ? approxFloor : (pts.map { $0.y }.min() ?? seedPt.y)
        var bestBelow = -Float.greatestFiniteMagnitude
        for py in input.planeYs where py < seedPt.y - bandThin { bestBelow = max(bestBelow, py) }
        if bestBelow > -Float.greatestFiniteMagnitude { floorY = bestBelow }

        // 3) Voxelize the space ABOVE the surface.
        let vs: Float = 0.02
        func key(_ p: SIMD3<Float>) -> Int64 {
            let ix = Int64((p.x / vs).rounded(.down)) &+ 100_000
            let iy = Int64((p.y / vs).rounded(.down)) &+ 100_000
            let iz = Int64((p.z / vs).rounded(.down)) &+ 100_000
            return (ix << 42) | (iy << 21) | iz
        }
        var occupied = Set<Int64>()
        occupied.reserveCapacity(pts.count)
        for p in pts {
            let h = p.y - floorY
            if h > bandThin && h < 2.6 { occupied.insert(key(p)) }
        }
        guard !occupied.isEmpty else {
            return .failure("Aim at an object resting on a flat surface")
        }

        // 4) Snap the seed to the nearest occupied voxel.
        func snapSeed() -> Int64? {
            if (seedPt.y - floorY) > bandThin {
                let k = key(seedPt)
                if occupied.contains(k) { return k }
            }
            let bx = Int((seedPt.x / vs).rounded(.down))
            let by = Int((seedPt.y / vs).rounded(.down))
            let bz = Int((seedPt.z / vs).rounded(.down))
            for r in 1...8 {
                for dx in -r...r { for dy in -r...r { for dz in -r...r {
                    let kx = Int64(bx + dx) &+ 100_000
                    let ky = Int64(by + dy) &+ 100_000
                    let kz = Int64(bz + dz) &+ 100_000
                    let k = (kx << 42) | (ky << 21) | kz
                    if occupied.contains(k) { return k }
                }}}
            }
            return nil
        }
        guard let startKey = snapSeed() else {
            return .failure("Aim directly at the object")
        }

        // 5) Region-grow a connected cluster from the seed.
        let mask: Int64 = (1 << 21) - 1
        func unpack(_ k: Int64) -> (Int64, Int64, Int64) {
            ((k >> 42) & mask, (k >> 21) & mask, k & mask)
        }
        let maxVox = Int((input.maxSize / vs).rounded()) + 2
        let (s0x, s0y, s0z) = unpack(startKey)
        var cluster: Set<Int64> = [startKey]
        var queue = [startKey]
        var qi = 0
        while qi < queue.count {
            let (cxk, cyk, czk) = unpack(queue[qi]); qi += 1
            for ox in Int64(-1)...1 { for oy in Int64(-1)...1 { for oz in Int64(-1)...1 {
                if ox == 0 && oy == 0 && oz == 0 { continue }
                let nx = cxk + ox, ny = cyk + oy, nz = czk + oz
                let nk = (nx << 42) | (ny << 21) | nz
                if occupied.contains(nk) && !cluster.contains(nk)
                    && abs(Int(nx - s0x)) <= maxVox
                    && abs(Int(ny - s0y)) <= maxVox
                    && abs(Int(nz - s0z)) <= maxVox {
                    cluster.insert(nk)
                    queue.append(nk)
                }
            }}}
            if cluster.count > 250_000 { break }
        }

        // 6) Gather the cluster's points.
        var obj: [SIMD3<Float>] = []
        obj.reserveCapacity(cluster.count)
        for p in pts where (p.y - floorY) > bandThin {
            if cluster.contains(key(p)) { obj.append(p) }
        }
        guard obj.count > 60 else {
            return .failure("Object too small/far — move closer or widen Max size")
        }

        // 7) Footprint PCA (XZ) → orientation.
        var mX: Float = 0, mZ: Float = 0
        for p in obj { mX += p.x; mZ += p.z }
        let n = Float(obj.count); mX /= n; mZ /= n
        var cxx: Float = 0, cxz: Float = 0, czz: Float = 0
        for p in obj { let ax = p.x - mX, az = p.z - mZ; cxx += ax*ax; cxz += ax*az; czz += az*az }
        cxx /= n; cxz /= n; czz /= n
        let ang = 0.5 * atan2(2 * cxz, cxx - czz)
        let a1 = SIMD2<Float>(cos(ang), sin(ang))
        let a2 = SIMD2<Float>(-sin(ang), cos(ang))

        // 8) Percentile-trimmed extents reject LiDAR noise tails.
        var q1 = [Float](); q1.reserveCapacity(obj.count)
        var q2 = [Float](); q2.reserveCapacity(obj.count)
        var hs = [Float](); hs.reserveCapacity(obj.count)
        for p in obj {
            let dx = p.x - mX, dz = p.z - mZ
            q1.append(dx * a1.x + dz * a1.y)
            q2.append(dx * a2.x + dz * a2.y)
            hs.append(p.y - floorY)
        }
        func pct(_ a: [Float], _ lo: Float, _ hi: Float) -> (Float, Float) {
            let s = a.sorted()
            let li = max(0, min(s.count - 1, Int(Float(s.count - 1) * lo)))
            let hiIdx = max(0, min(s.count - 1, Int(Float(s.count - 1) * hi)))
            return (s[li], s[hiIdx])
        }
        let (lo1, hi1) = pct(q1, 0.015, 0.985)
        let (lo2, hi2) = pct(q2, 0.015, 0.985)
        let (_,  hHi) = pct(hs, 0.0, 0.985)
        let ext1 = hi1 - lo1, ext2 = hi2 - lo2
        let length = max(ext1, ext2)
        let width  = min(ext1, ext2)
        let height = max(hHi, 0.005)

        let cU = (lo1 + hi1) / 2, cW = (lo2 + hi2) / 2
        let cXZ = SIMD2<Float>(mX, mZ) + a1 * cU + a2 * cW
        let center = SIMD3<Float>(cXZ.x, floorY + height / 2, cXZ.y)

        return .measurement(BoxMeasurement(
            center: center,
            xAxis: SIMD3<Float>(a1.x, 0, a1.y),
            zAxis: SIMD3<Float>(a2.x, 0, a2.y),
            length: length, width: width, height: height))
    }

    /// Interactive (non-LiDAR) box from 3 base corners + a manual height.
    static func interactiveBox(p1: SIMD3<Float>, p2: SIMD3<Float>,
                               p3: SIMD3<Float>, height: Float) -> BoxMeasurement? {
        let lengthVec = p2 - p1
        let length = simd_length(lengthVec)
        guard length > 0.001 else { return nil }
        let xAxis = simd_normalize(lengthVec)
        let yAxis = SIMD3<Float>(0, 1, 0)
        var zAxis = simd_cross(xAxis, yAxis)
        guard simd_length(zAxis) > 0.0001 else { return nil }
        zAxis = simd_normalize(zAxis)

        let sign = copysignf(1, simd_dot(p3 - p1, zAxis))
        let width = abs(simd_dot(p3 - p1, zAxis))
        guard width > 0.001 else { return nil }
        let zSigned = zAxis * sign

        let baseCenter = p1 + xAxis * (length / 2) + zSigned * (width / 2)
        let center = baseCenter + yAxis * (height / 2)

        return BoxMeasurement(center: center, xAxis: xAxis, zAxis: zSigned,
                              length: length, width: width, height: height)
    }
}
