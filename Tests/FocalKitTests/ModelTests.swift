import Foundation
import SceneKit
import Testing
import UniformTypeIdentifiers
@testable import FocalKit

@Test func eachThreeDFormatTakesTheLoaderThatCanReadIt() {
    func route(_ ext: String) -> ModelLoader.Route? { UTType(filenameExtension: ext).flatMap(ModelLoader.route(for:)) }
    // SceneKit reads these itself (through ModelIO).
    for ext in ["usdz", "usd", "usda", "usdc", "obj", "stl", "ply", "abc"] { #expect(route(ext) == .sceneKit, "\(ext)") }
    // macOS's USD library reads glTF through its plugins; SceneKit doesn't, so they are converted to USD first.
    for ext in ["gltf", "glb"] { #expect(route(ext) == .viaUSD, "\(ext)") }
    #expect(route("mtlx") == .materialX)
    #expect(route("vdb") == nil, "volumes: no public framework draws them")
    #expect(route("png") == nil)
}

@Test func materialXStandardSurfaceBecomesAPreviewMaterial() throws {
    let mtlx = """
    <?xml version="1.0"?>
    <materialx version="1.38">
      <standard_surface name="SR_gold" type="surfaceshader">
        <input name="base_color" type="color3" value="1.0, 0.766, 0.336" />
        <input name="metalness" type="float" value="1" />
        <input name="specular_roughness" type="float" value="0.25" />
      </standard_surface>
      <surfacematerial name="M_gold" type="material">
        <input name="surfaceshader" type="surfaceshader" nodename="SR_gold" />
      </surfacematerial>
    </materialx>
    """
    let m = try #require(MaterialXPreview.parse(Data(mtlx.utf8), baseURL: URL(fileURLWithPath: "/tmp")))
    #expect(m.name == "M_gold")
    #expect(abs(m.baseColor.0 - 1.0) < 0.001 && abs(m.baseColor.1 - 0.766) < 0.001 && abs(m.baseColor.2 - 0.336) < 0.001)
    #expect(m.metalness == 1 && m.roughness == 0.25)
    #expect(MaterialXPreview.parse(Data("<materialx/>".utf8), baseURL: URL(fileURLWithPath: "/tmp")) == nil, "no surface, nothing to show")
}

@Test func sceneStatsCountTrianglesAndVertices() {
    let scene = SCNScene()
    scene.rootNode.addChildNode(SCNNode(geometry: SCNBox(width: 1, height: 2, length: 3, chamferRadius: 0)))
    let child = SCNNode(geometry: SCNPlane(width: 1, height: 1))
    child.position = SCNVector3(5, 0, 0)
    scene.rootNode.addChildNode(child)
    let s = ModelLoader.stats(scene)
    #expect(s.meshes == 2)
    #expect(s.triangles == 12 + 2, "a box is 6 faces x 2 triangles, a plane 2")
    #expect(s.vertices > 0)
    #expect(abs(s.size.x - 6) < 0.01, "from the box's left side (-0.5) to the plane's right edge (5.5)")
    #expect(abs(s.size.z - 3) < 0.01)
}
