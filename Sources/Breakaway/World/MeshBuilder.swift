import BreakawayCore
import Foundation
import SceneKit
import simd

/// Maps the route's local east/north metres + elevation into SceneKit space
/// (Y up, north = −Z). Elevations are offset so numbers stay small.
struct WorldFrame {
    let baseElevation: Double

    func point(_ p: LocalPoint, _ elevation: Double) -> SIMD3<Float> {
        SIMD3(Float(p.x), Float(elevation - baseElevation), Float(-p.y))
    }

    func point(x: Double, y: Double, elevation: Double) -> SIMD3<Float> {
        SIMD3(Float(x), Float(elevation - baseElevation), Float(-y))
    }

    /// Horizontal scene direction for a local direction vector.
    func direction(_ d: LocalPoint) -> SIMD3<Float> { simd_normalize(SIMD3(Float(d.x), 0, Float(-d.y))) }

    /// Yaw (radians about +Y) that turns a node's −Z forward axis onto local direction `d`.
    func yaw(_ d: LocalPoint) -> Float { Float(atan2(-d.x, d.y)) }
}

/// Interleaving-free vertex buffers that become one SCNGeometry with several elements.
struct MeshData {
    var positions: [Float] = []
    var normals: [Float] = []
    var colors: [Float] = []
    var uvs: [Float] = []
    var elements: [[UInt32]] = [[]]

    var vertexCount: Int { positions.count / 3 }

    @discardableResult
    mutating func addVertex(_ p: SIMD3<Float>, normal n: SIMD3<Float> = SIMD3(0, 1, 0),
                            color c: SIMD4<Float> = SIMD4(1, 1, 1, 1), uv: SIMD2<Float> = .zero) -> UInt32 {
        positions += [p.x, p.y, p.z]
        normals += [n.x, n.y, n.z]
        colors += [c.x, c.y, c.z, c.w]
        uvs += [uv.x, uv.y]
        return UInt32(vertexCount - 1)
    }

    mutating func addTriangle(_ a: UInt32, _ b: UInt32, _ c: UInt32, element: Int = 0) {
        while elements.count <= element { elements.append([]) }
        elements[element] += [a, b, c]
    }

    mutating func addQuad(_ a: UInt32, _ b: UInt32, _ c: UInt32, _ d: UInt32, element: Int = 0) {
        addTriangle(a, b, c, element: element)
        addTriangle(a, c, d, element: element)
    }

    func position(_ i: Int) -> SIMD3<Float> { SIMD3(positions[i * 3], positions[i * 3 + 1], positions[i * 3 + 2]) }

    mutating func setNormal(_ i: Int, _ n: SIMD3<Float>) {
        normals[i * 3] = n.x
        normals[i * 3 + 1] = n.y
        normals[i * 3 + 2] = n.z
    }

    /// Smooth normals from triangle faces (area weighted).
    mutating func computeNormals() {
        var acc = [SIMD3<Float>](repeating: .zero, count: vertexCount)
        for el in elements {
            var i = 0
            while i + 2 < el.count {
                let a = Int(el[i]), b = Int(el[i + 1]), c = Int(el[i + 2])
                let n = simd_cross(position(b) - position(a), position(c) - position(a))
                acc[a] += n
                acc[b] += n
                acc[c] += n
                i += 3
            }
        }
        for (i, n) in acc.enumerated() {
            let l = simd_length(n)
            setNormal(i, l > 1e-8 ? n / l : SIMD3(0, 1, 0))
        }
    }

    func geometry(materials: [SCNMaterial], includeColors: Bool = true) -> SCNGeometry {
        func source(_ array: [Float], _ semantic: SCNGeometrySource.Semantic, _ components: Int) -> SCNGeometrySource {
            let data = array.withUnsafeBufferPointer { Data(buffer: $0) }
            return SCNGeometrySource(data: data, semantic: semantic, vectorCount: array.count / components,
                                     usesFloatComponents: true, componentsPerVector: components,
                                     bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0,
                                     dataStride: MemoryLayout<Float>.size * components)
        }
        var sources = [source(positions, .vertex, 3), source(normals, .normal, 3), source(uvs, .texcoord, 2)]
        if includeColors { sources.append(source(colors, .color, 4)) }
        let els = elements.map { idx -> SCNGeometryElement in
            let data = idx.withUnsafeBufferPointer { Data(buffer: $0) }
            return SCNGeometryElement(data: data, primitiveType: .triangles, primitiveCount: idx.count / 3,
                                      bytesPerIndex: MemoryLayout<UInt32>.size)
        }
        let g = SCNGeometry(sources: sources, elements: els)
        g.materials = materials
        return g
    }
}

enum SceneMath {
    /// Rotation taking +Y onto `dir` (used to align cylinders / capsules).
    static func alignY(to dir: SIMD3<Float>) -> simd_quatf {
        let d = simd_normalize(dir)
        let up = SIMD3<Float>(0, 1, 0)
        let dot = simd_dot(up, d)
        if dot > 0.9999 { return simd_quatf(angle: 0, axis: SIMD3(1, 0, 0)) }
        if dot < -0.9999 { return simd_quatf(angle: .pi, axis: SIMD3(1, 0, 0)) }
        return simd_quatf(from: up, to: d)
    }

    /// Yaw → pitch → roll, intrinsic (heading, then nose-up, then lean).
    static func orientation(yaw: Float, pitch: Float, roll: Float) -> simd_quatf {
        simd_quatf(angle: yaw, axis: SIMD3(0, 1, 0)) * simd_quatf(angle: pitch, axis: SIMD3(1, 0, 0)) * simd_quatf(angle: roll, axis: SIMD3(0, 0, 1))
    }

    /// Positions a Y-aligned node so it spans from `a` to `b`.
    static func place(_ node: SCNNode, from a: SIMD3<Float>, to b: SIMD3<Float>) {
        node.simdPosition = (a + b) / 2
        node.simdOrientation = alignY(to: b - a)
    }

    static func color(_ c: RGBColor) -> NSColor {
        NSColor(srgbRed: CGFloat(c.r), green: CGFloat(c.g), blue: CGFloat(c.b), alpha: 1)
    }

    static func material(_ color: NSColor, roughness: CGFloat = 0.6, metalness: CGFloat = 0, lit: SCNMaterial.LightingModel = .physicallyBased) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = lit
        m.diffuse.contents = color
        m.roughness.contents = roughness
        m.metalness.contents = metalness
        return m
    }

    static func mix(_ a: SIMD4<Float>, _ b: SIMD4<Float>, _ t: Float) -> SIMD4<Float> { a + (b - a) * max(0, min(1, t)) }

    static func rgba(_ hex: UInt32, _ a: Float = 1) -> SIMD4<Float> {
        SIMD4(Float((hex >> 16) & 0xFF) / 255, Float((hex >> 8) & 0xFF) / 255, Float(hex & 0xFF) / 255, a)
    }
}

/// Deterministic per-world random numbers for scenery placement.
struct SceneRandom {
    private var rng: SplitMix64

    init(seed: UInt64) { rng = SplitMix64(seed: seed) }

    mutating func unit() -> Double { rng.nextUnit() }
    mutating func range(_ a: Double, _ b: Double) -> Double { rng.range(a, b) }
    mutating func float(_ a: Float, _ b: Float) -> Float { Float(rng.range(Double(a), Double(b))) }
    mutating func chance(_ p: Double) -> Bool { rng.nextUnit() < p }
    mutating func pick<T>(_ items: [T]) -> T { items[Int(rng.next() % UInt64(items.count))] }
}
