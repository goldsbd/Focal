import AppKit
import SceneKit
import UniformTypeIdentifiers

/// A 3D file (USD/USDZ, glTF, OBJ, STL, PLY, Alembic, MaterialX). Nothing is read up front; the viewer loads the
/// scene off the main thread so the window shows at once.
@objc(ModelDocument)
final class ModelDocument: NSDocument {
    /// Files converted for SceneKit (glTF via USD), deleted with the window.
    var temporaryFiles: [URL] = []

    override class var autosavesInPlace: Bool { false }

    override func makeWindowControllers() {
        addWindowController(ViewerWindowController())
    }

    override func read(from url: URL, ofType typeName: String) throws {
        Log.event("3d \(url.lastPathComponent)")
    }

    override func close() {
        ModelLoader.removeTemporaryFiles(temporaryFiles)
        temporaryFiles = []
        super.close()
    }

    /// 3D files are viewed, not edited or printed here.
    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        [#selector(saveTo(_:)), #selector(printDocument(_:))].contains(item.action) ? false : super.validateUserInterfaceItem(item)
    }
}

/// SceneKit holds the scene: drag orbits, pinch or scroll zooms, two-finger drag pans. Reset View returns to the
/// opening framing; Copy puts the current view on the clipboard as a picture.
final class ModelViewController: NSViewController, ViewerContent, NSMenuItemValidation, NSToolbarItemValidation {
    let document: ModelDocument
    let scnView = SCNView()
    private let spinner = NSProgressIndicator()
    private let message = NSTextField(wrappingLabelWithString: "")
    private let camera = SCNNode()
    private var home: (transform: SCNMatrix4, target: SCNVector3)?
    private(set) var stats: ModelLoader.Stats?
    private var loadTask: Task<Void, Never>?

    init(document: ModelDocument) {
        self.document = document
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var supportsMarkup: Bool { false }
    var toolbarKind: ViewerToolbar.Kind? { .model }
    var keepsAspectRatio: Bool { false }
    var keyView: NSView? { scnView }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 960, height: 720))
        scnView.translatesAutoresizingMaskIntoConstraints = false
        scnView.allowsCameraControl = true
        scnView.autoenablesDefaultLighting = true
        scnView.antialiasingMode = .multisampling4X
        scnView.backgroundColor = .underPageBackgroundColor
        scnView.defaultCameraController.interactionMode = .orbitTurntable
        scnView.defaultCameraController.inertiaEnabled = true
        scnView.isPlaying = true   // models with animation play
        scnView.rendersContinuously = false
        spinner.style = .spinning
        spinner.isDisplayedWhenStopped = false   // a stopped spinner otherwise stays drawn over the model
        spinner.translatesAutoresizingMaskIntoConstraints = false
        message.alignment = .center
        message.font = .systemFont(ofSize: 15)
        message.textColor = .secondaryLabelColor
        message.isHidden = true
        message.translatesAutoresizingMaskIntoConstraints = false
        for v in [scnView, spinner, message] { root.addSubview(v) }
        NSLayoutConstraint.activate([
            scnView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scnView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scnView.topAnchor.constraint(equalTo: root.topAnchor),
            scnView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            spinner.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            message.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            message.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            message.widthAnchor.constraint(lessThanOrEqualTo: root.widthAnchor, constant: -40),
        ])
        view = root
        load()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        if mayTakeKeyboardFocus { view.window?.makeFirstResponder(scnView) }
        updateSubtitle()
    }

    private struct SceneBox: @unchecked Sendable { let scene: SCNScene; let temporary: [URL] }   // handed over once, not shared

    private func load() {
        guard let url = document.fileURL, let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
            ?? document.fileType.flatMap(UTType.init) else { return }
        spinner.startAnimation(nil)
        let started = Date()
        loadTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> Result<SceneBox, any Error> in
                var temporary: [URL] = []
                do {
                    let scene = try ModelLoader.load(url, type: type, temporary: &temporary)
                    return .success(SceneBox(scene: scene, temporary: temporary))
                } catch {
                    ModelLoader.removeTemporaryFiles(temporary)
                    return .failure(error)
                }
            }.value
            guard let self, !Task.isCancelled else {
                if case .success(let box) = result { ModelLoader.removeTemporaryFiles(box.temporary) }
                return
            }
            self.spinner.stopAnimation(nil)
            switch result {
            case .success(let box):
                self.document.temporaryFiles += box.temporary
                self.show(box.scene)
                Log.event(String(format: "3d loaded in %.1f ms", Date().timeIntervalSince(started) * 1000))
            case .failure(let error):
                self.message.stringValue = error.localizedDescription
                self.message.isHidden = false
                Log.event("3d failed: \(error.localizedDescription)")
            }
        }
    }

    private func show(_ scene: SCNScene) {
        let s = ModelLoader.stats(scene)
        stats = s
        // Frame the whole model from slightly above, as Preview opens it.
        let radius = max(simd_length(s.size) / 2, 0.001)
        let lens = SCNCamera()
        lens.fieldOfView = 40
        lens.zNear = Double(radius) * 0.01
        lens.zFar = Double(radius) * 100
        camera.camera = lens
        let center = SCNVector3(s.center.x, s.center.y, s.center.z)
        let distance = CGFloat(radius) / sin(CGFloat(20) * .pi / 180) * 1.15
        camera.position = SCNVector3(center.x + distance * 0.35, center.y + distance * 0.3, center.z + distance * 0.89)
        camera.look(at: center)
        scene.rootNode.addChildNode(camera)
        scnView.scene = scene
        scnView.pointOfView = camera
        scnView.defaultCameraController.target = center
        home = (camera.transform, center)
        updateSubtitle()
        InspectorController.refreshIfOpen()
    }

    @objc func resetView(_ sender: Any?) {
        guard let home else { return }
        scnView.defaultCameraController.stopInertia()
        camera.transform = home.transform
        scnView.pointOfView = camera
        scnView.defaultCameraController.target = home.target
    }

    @objc func copy(_ sender: Any?) {
        let image = scnView.snapshot()
        var rect = CGRect(origin: .zero, size: image.size)
        guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { NSSound.beep(); return }
        PasteboardImage.write(cg, pointSize: scnView.bounds.size)
        Toast.show("Copied the view", in: view)
    }

    private func updateSubtitle() {
        guard let window = view.window, let s = stats else { return }
        window.subtitle = "\(s.triangles.formatted()) triangles · \(s.meshes) mesh\(s.meshes == 1 ? "" : "es")"
    }

    func resolveNaturalSize(_ completion: @escaping @MainActor (CGSize) -> Void) { completion(CGSize(width: 960, height: 720)) }

    func teardown() {
        loadTask?.cancel()
        scnView.isPlaying = false
        scnView.scene = nil
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool { validate(item.action) }
    func validateToolbarItem(_ item: NSToolbarItem) -> Bool { validate(item.action) }
    private func validate(_ action: Selector?) -> Bool {
        switch action {
        case #selector(resetView(_:)), #selector(copy(_:)): stats != nil
        default: true
        }
    }

    func inspectorRows() async -> [(String, String)] {
        var rows: [(String, String)] = []
        if let url = document.fileURL {
            rows.append(("File", url.lastPathComponent))
            rows.append(("Folder", (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath))
            if let bytes = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                rows.append(("File size", ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)))
            }
            rows.append(("Kind", (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType?.localizedDescription ?? "3D model"))
        }
        guard let s = stats else { return rows }
        rows.append(("Meshes", "\(s.meshes)"))
        rows.append(("Triangles", s.triangles.formatted()))
        rows.append(("Vertices", s.vertices.formatted()))
        rows.append(("Materials", "\(s.materials)"))
        rows.append(("Size", String(format: "%.3g × %.3g × %.3g units", s.size.x, s.size.y, s.size.z)))
        if s.animations > 0 { rows.append(("Animations", "\(s.animations)")) }
        return rows
    }
}
