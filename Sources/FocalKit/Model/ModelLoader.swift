import AppKit
import SceneKit
import UniformTypeIdentifiers

/// Reading 3D files into a SceneKit scene. SceneKit (through ModelIO) reads USD, OBJ, STL, PLY and Alembic itself.
/// glTF it can't, but macOS's USD library can (its plugins): those are converted to a temporary USD file with the
/// system's `usdcat` first. MaterialX is a material, not a model: it is shown on a sphere.
enum ModelLoader {
    enum Route: Equatable { case sceneKit, viaUSD, materialX }

    static let sceneKitTypes = ["com.pixar.universal-scene-description", "com.pixar.universal-scene-description-mobile",
                                "com.pixar.universal-scene-description-utf8", "com.pixar.universal-scene-description-binary",
                                "public.geometry-definition-format", "public.standard-tesselated-geometry-format",
                                "public.polygon-file-format", "public.alembic"]
    static let usdTypes = ["org.khronos.gltf", "org.khronos.glb"]
    static let materialXType = "io.aswf.materialx"
    /// Every type Focal opens as a model (OpenVDB volumes are left out: no public framework draws them).
    static var allTypes: [String] { sceneKitTypes + usdTypes + [materialXType] }

    static func route(for type: UTType) -> Route? {
        if sceneKitTypes.contains(where: { type.conforms(to: UTType($0)!) }) { return .sceneKit }
        if usdTypes.contains(where: { type.conforms(to: UTType($0)!) }) { return .viaUSD }
        if type.conforms(to: UTType(materialXType)!) { return .materialX }
        return nil
    }

    enum LoadError: LocalizedError {
        case unsupported, empty, converter(String)
        var errorDescription: String? {
            switch self {
            case .unsupported: "Focal can't show this kind of 3D file."
            case .empty: "The file has no 3D shapes to show."
            case .converter(let detail): "macOS's USD tools couldn't read this file. \(detail)"
            }
        }
    }

    /// Loads off the main thread. `temporary` collects files made along the way, for the caller to delete.
    static func load(_ url: URL, type: UTType, temporary: inout [URL]) throws -> SCNScene {
        let scene: SCNScene
        switch route(for: type) {
        case .sceneKit:
            scene = try SCNScene(url: url, options: [.checkConsistency: false, .convertToYUp: true])
        case .viaUSD:
            let converted = try convertWithUSD(url)
            temporary.append(converted)
            scene = try SCNScene(url: converted, options: [.convertToYUp: true])
        case .materialX:
            guard let data = try? Data(contentsOf: url), let material = MaterialXPreview.parse(data, baseURL: url.deletingLastPathComponent())
            else { throw LoadError.empty }
            scene = MaterialXPreview.scene(for: material)
        case nil:
            throw LoadError.unsupported
        }
        guard stats(scene).meshes > 0 else { throw LoadError.empty }   // SceneKit "opens" a missing or empty file as an empty scene
        return scene
    }

    /// The system's USD converter (part of macOS).
    static let usdcat = URL(fileURLWithPath: "/usr/bin/usdcat")

    static func convertWithUSD(_ url: URL) throws -> URL {
        guard FileManager.default.isExecutableFile(atPath: usdcat.path) else { throw LoadError.converter("usdcat is missing.") }
        let folder = temporaryFolder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let out = folder.appendingPathComponent(UUID().uuidString + ".usdc")
        let process = Process()
        process.executableURL = usdcat
        process.arguments = [url.path, "-o", out.path]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(separator: "\n").first { !$0.contains("warning") }.map(String.init) ?? ""
        guard process.terminationStatus == 0, FileManager.default.fileExists(atPath: out.path) else { throw LoadError.converter(message) }
        return out
    }

    static var temporaryFolder: URL { FileManager.default.temporaryDirectory.appendingPathComponent("FocalModels", isDirectory: true) }

    /// At quit: conversions of windows still open.
    static func removeAllTemporaryFiles() { try? FileManager.default.removeItem(at: temporaryFolder) }

    static func removeTemporaryFiles(_ urls: [URL]) {
        urls.forEach { try? FileManager.default.removeItem(at: $0) }
    }

    struct Stats {
        var nodes = 0, meshes = 0, triangles = 0, vertices = 0, materials = 0, animations = 0
        var min = SIMD3<Float>(repeating: .infinity), max = SIMD3<Float>(repeating: -.infinity)
        var size: SIMD3<Float> { meshes > 0 ? max - min : .zero }
        var center: SIMD3<Float> { meshes > 0 ? (min + max) / 2 : .zero }
    }

    /// Counts and world-space bounds over every node with a shape.
    static func stats(_ scene: SCNScene) -> Stats {
        var s = Stats()
        var materials = Set<ObjectIdentifier>()
        scene.rootNode.enumerateHierarchy { node, _ in
            s.nodes += 1
            s.animations += node.animationKeys.count
            guard let geometry = node.geometry else { return }
            s.meshes += 1
            geometry.materials.forEach { materials.insert(ObjectIdentifier($0)) }
            s.vertices += geometry.sources(for: .vertex).first?.vectorCount ?? 0
            for element in geometry.elements {
                switch element.primitiveType {
                case .triangles, .triangleStrip: s.triangles += element.primitiveCount
                case .polygon: s.triangles += element.primitiveCount   // at least one triangle per polygon
                default: break
                }
            }
            let (lo, hi) = node.boundingBox
            for x in [lo.x, hi.x] { for y in [lo.y, hi.y] { for z in [lo.z, hi.z] {
                let w = node.convertPosition(SCNVector3(x, y, z), to: nil)
                let p = SIMD3<Float>(Float(w.x), Float(w.y), Float(w.z))
                s.min = simd_min(s.min, p)
                s.max = simd_max(s.max, p)
            } } }
        }
        s.materials = materials.count
        return s
    }
}

/// A MaterialX document shown the way Preview does: on a sphere. Reads the first surface shader's constant inputs
/// (standard_surface or UsdPreviewSurface) and an image file wired to its base colour; procedural node graphs
/// beyond that aren't evaluated, so complex materials show their base colour only.
enum MaterialXPreview {
    struct Material: Equatable {
        var name: String
        var baseColor: (Double, Double, Double) = (0.8, 0.8, 0.8)
        var metalness = 0.0
        var roughness = 0.5
        var emission: (Double, Double, Double) = (0, 0, 0)
        var opacity = 1.0
        var baseColorTexture: URL?

        static func == (a: Material, b: Material) -> Bool {
            a.name == b.name && a.baseColor == b.baseColor && a.metalness == b.metalness && a.roughness == b.roughness
                && a.emission == b.emission && a.opacity == b.opacity && a.baseColorTexture == b.baseColorTexture
        }
    }

    static func parse(_ data: Data, baseURL: URL) -> Material? {
        guard let doc = try? XMLDocument(data: data), let root = doc.rootElement() else { return nil }
        let shaders = root.elements(forName: "standard_surface") + root.elements(forName: "UsdPreviewSurface")
        guard let shader = shaders.first else { return nil }
        let materialName = root.elements(forName: "surfacematerial").first?.attribute(forName: "name")?.stringValue
        var m = Material(name: materialName ?? shader.attribute(forName: "name")?.stringValue ?? "Material")
        let images = Dictionary(root.elements(forName: "image").compactMap { node -> (String, URL)? in
            guard let name = node.attribute(forName: "name")?.stringValue,
                  let file = node.elements(forName: "input").first(where: { $0.attribute(forName: "name")?.stringValue == "file" })?
                    .attribute(forName: "value")?.stringValue else { return nil }
            return (name, URL(fileURLWithPath: file, relativeTo: baseURL).standardizedFileURL)
        }, uniquingKeysWith: { a, _ in a })
        for input in shader.elements(forName: "input") {
            let name = input.attribute(forName: "name")?.stringValue ?? ""
            let value = input.attribute(forName: "value")?.stringValue ?? ""
            let numbers = value.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            func color() -> (Double, Double, Double)? { numbers.count >= 3 ? (numbers[0], numbers[1], numbers[2]) : nil }
            switch name {
            case "base_color", "diffuseColor":
                if let c = color() { m.baseColor = c }
                if let node = input.attribute(forName: "nodename")?.stringValue, let file = images[node] { m.baseColorTexture = file }
            case "metalness", "metallic": if let v = numbers.first { m.metalness = v }
            case "specular_roughness", "roughness": if let v = numbers.first { m.roughness = v }
            case "emission_color", "emissiveColor": if let c = color() { m.emission = c }
            case "opacity": if let v = numbers.first { m.opacity = v }
            default: break
            }
        }
        return m
    }

    static func scene(for m: Material) -> SCNScene {
        let scene = SCNScene()
        let sphere = SCNSphere(radius: 1)
        sphere.segmentCount = 96
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.diffuse.contents = m.baseColorTexture.flatMap { NSImage(contentsOf: $0) }
            ?? NSColor(srgbRed: m.baseColor.0, green: m.baseColor.1, blue: m.baseColor.2, alpha: 1)
        material.metalness.contents = m.metalness
        material.roughness.contents = m.roughness
        material.emission.contents = NSColor(srgbRed: m.emission.0, green: m.emission.1, blue: m.emission.2, alpha: 1)
        material.transparency = m.opacity
        material.name = m.name
        sphere.materials = [material]
        let node = SCNNode(geometry: sphere)
        node.name = m.name
        scene.rootNode.addChildNode(node)
        scene.lightingEnvironment.contents = NSColor(white: 0.55, alpha: 1)   // metals need something to reflect
        return scene
    }
}
