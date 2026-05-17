import SceneKit
import UIKit

/// View layer: turns a `BoxMeasurement` into a SceneKit node — faint fill,
/// a 1 px wireframe border, and billboarded L/W/H labels.
enum BoxNodeFactory {

    static func make(_ m: BoxMeasurement) -> SCNNode? {
        guard m.length > 0.005, m.width > 0.005, m.height > 0.005 else { return nil }

        let container = SCNNode()
        container.simdTransform = simd_float4x4(
            SIMD4(m.xAxis, 0),
            SIMD4(SIMD3<Float>(0, 1, 0), 0),
            SIMD4(m.zAxis, 0),
            SIMD4(m.center, 1)
        )
        let hx = m.length / 2, hy = m.height / 2, hz = m.width / 2

        // Faint fill so the real object stays visible through it
        let fill = SCNBox(width: CGFloat(m.length), height: CGFloat(m.height),
                          length: CGFloat(m.width), chamferRadius: 0)
        let fillMat = SCNMaterial()
        fillMat.diffuse.contents = UIColor.systemGreen.withAlphaComponent(0.10)
        fillMat.isDoubleSided = true
        fill.firstMaterial = fillMat
        container.addChildNode(SCNNode(geometry: fill))

        // 1 px wireframe border — the 12 edges
        let corners = [
            SCNVector3(-hx, -hy, -hz), SCNVector3( hx, -hy, -hz),
            SCNVector3( hx, -hy,  hz), SCNVector3(-hx, -hy,  hz),
            SCNVector3(-hx,  hy, -hz), SCNVector3( hx,  hy, -hz),
            SCNVector3( hx,  hy,  hz), SCNVector3(-hx,  hy,  hz),
        ]
        let edges: [Int32] = [
            0,1, 1,2, 2,3, 3,0,
            4,5, 5,6, 6,7, 7,4,
            0,4, 1,5, 2,6, 3,7,
        ]
        let lineGeo = SCNGeometry(
            sources: [SCNGeometrySource(vertices: corners)],
            elements: [SCNGeometryElement(indices: edges, primitiveType: .line)]
        )
        let lineMat = SCNMaterial()
        lineMat.diffuse.contents = UIColor.systemGreen
        lineMat.lightingModel = .constant
        lineGeo.firstMaterial = lineMat
        container.addChildNode(SCNNode(geometry: lineGeo))

        func label(_ text: String, at p: SCNVector3) {
            let t = SCNText(string: text, extrusionDepth: 0)
            t.font = .boldSystemFont(ofSize: 10)
            t.flatness = 0.2
            let tm = SCNMaterial()
            tm.diffuse.contents = UIColor.white
            tm.lightingModel = .constant
            t.firstMaterial = tm
            let node = SCNNode(geometry: t)
            let bb = t.boundingBox
            node.pivot = SCNMatrix4MakeTranslation((bb.min.x + bb.max.x) / 2,
                                                   (bb.min.y + bb.max.y) / 2, 0)
            let s: Float = 0.0016
            node.scale = SCNVector3(s, s, s)
            node.position = p
            node.constraints = [SCNBillboardConstraint()]
            container.addChildNode(node)
        }
        label(cm(m.length), at: SCNVector3(0,  hy * 1.08, hz))
        label(cm(m.width),  at: SCNVector3(hx, hy * 1.08, 0))
        label(cm(m.height), at: SCNVector3(hx, 0,         hz))

        return container
    }

    static func marker(at pos: SIMD3<Float>) -> SCNNode {
        let s = SCNSphere(radius: 0.006)
        s.firstMaterial?.diffuse.contents = UIColor.systemYellow
        let node = SCNNode(geometry: s)
        node.simdPosition = pos
        return node
    }

    static func cm(_ meters: Float) -> String {
        String(format: "%.1f cm", meters * 100)
    }
}
