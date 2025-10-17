//
//  ViewController.swift
//  MaLiang
//
//  Created by Harley-xk on 04/07/2019.
//  Copyright (c) 2019 Harley-xk. All rights reserved.
//

import UIKit
import MaLiang
import Comet
import Chrysan
// import Zip
import Metal
import MetalKit

class ViewController: UIViewController {
    
    @IBOutlet weak var strokeSizeLabel: UILabel!
    @IBOutlet weak var brushSegement: UISegmentedControl!
    @IBOutlet weak var sizeSlider: UISlider!
    @IBOutlet weak var undoButton: UIButton!
    @IBOutlet weak var redoButton: UIButton!
    @IBOutlet weak var backgroundSwitchButton: UIButton!
    @IBOutlet weak var backgroundView: UIImageView!
    
    @IBOutlet weak var canvas: Canvas!
    
    var filePath: String?
    
    var brushes: [Brush] = []
    var chartlets: [MLTexture] = []
    
    // Shader effect overlay
    var shaderOverlayView: UIView!
    var metalView: MTKView!
    var isShaderEnabled = false
    
    // Halftone shader parameters
    var halftoneDotSize: CGFloat = 8.0     // Size of halftone dots (4.0-20.0)
    var halftoneSmoothing: CGFloat = 12.0  // Edge smoothing factor
    var halftoneBlendMode: Int = 3         // Blend mode (0-7), 3 = B&W Overlay
    
    // Metal resources
    var metalDevice: MTLDevice?
    var commandQueue: MTLCommandQueue?
    var pipelineState: MTLRenderPipelineState?
    var vertexBuffer: MTLBuffer?
    var texCoordBuffer: MTLBuffer?
    var canvasTexture: MTLTexture?
    
    var color: UIColor {
        return UIColor(red: r, green: g, blue: b, alpha: 1)
    }
    
    private func registerBrush(with imageName: String) throws -> Brush {
        let texture = try canvas.makeTexture(with: UIImage(named: imageName)!.pngData()!)
        return try canvas.registerBrush(name: imageName, textureID: texture.id)
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        // Do any additional setup after loading the view, typically from a nib.
        
        navigationController?.interactivePopGestureRecognizer?.isEnabled = false
        
        chartlets = ["chartlet-1", "chartlet-2", "chartlet-3"].compactMap({ (name) -> MLTexture? in
            return try? canvas.makeTexture(with: UIImage(named: name)!.pngData()!)
        })
        canvas.backgroundColor = .clear
        canvas.data.addObserver(self)
        registerBrushes()
        readDataIfNeeds()
        setupShaderOverlay()
    }
    
    
    func registerBrushes() {
        do {
            let pen = canvas.defaultBrush!
            pen.name = "Pen"
            pen.pointSize = 5
            pen.pointStep = 0.5
            pen.color = color
            
            let pencil = try registerBrush(with: "pencil")
            pencil.rotation = .random
            pencil.pointSize = 3
            pencil.pointStep = 2
            pencil.forceSensitive = 0.3
            pencil.opacity = 1
            
            let brush = try registerBrush(with: "brush")
            brush.opacity = 1
            brush.rotation = .ahead
            brush.pointSize = 15
            brush.pointStep = 1
            brush.forceSensitive = 1
            brush.color = color
            brush.forceOnTap = 0.5
            
            let texture = try canvas.makeTexture(with: UIImage(named: "glow")!.pngData()!)
            let glow: GlowingBrush = try canvas.registerBrush(name: "glow", textureID: texture.id)
            glow.opacity = 0.5
            glow.coreProportion = 0.2
            glow.pointSize = 20
            glow.rotation = .ahead
            
            let claw = try registerBrush(with: "claw")
            claw.rotation = .ahead
            claw.pointSize = 30
            claw.pointStep = 5
            claw.forceSensitive = 0.1
            claw.color = color
            
            /// make a chartlet brush
            let chartletBrush = try ChartletBrush(name: "Chartlet", imageNames: ["rect-1", "rect-2", "rect-3"], target: canvas)
            chartletBrush.renderStyle = .ordered
            chartletBrush.rotation = .random
            
            // make eraser with a texture for claw
//            let eraser = try canvas.registerBrush(name: "Eraser", textureID: claw.textureID) as Eraser
//            eraser.rotation = .ahead
            
            /// make eraser with default round point
            let eraser = try! canvas.registerBrush(name: "Eraser") as Eraser
            eraser.opacity = 1
            
            brushes = [pen, pencil, brush, glow, claw, chartletBrush, eraser]
            
        } catch MLError.simulatorUnsupported {
            let alert = UIAlertController(title: "Attension", message: "You are running MaLiang on a Simulator, whitch is not supported by Metal. So painting is not alvaliable now. But you can go on testing your other businesses which are not relative with MaLiang. Or you can also runs MaLiang on your Mac with Catalyst enabled now.", preferredStyle: .alert)
            alert.addAction(title: "确定", style: .cancel)
            self.present(alert, animated: true, completion: nil)
        } catch {
            let alert = UIAlertController(title: "Error", message: error.localizedDescription, preferredStyle: .alert)
            alert.addAction(title: "确定", style: .cancel)
            self.present(alert, animated: true, completion: nil)
        }
        
        brushSegement.removeAllSegments()
        for i in 0 ..< brushes.count {
            let name = brushes[i].name
            brushSegement.insertSegment(withTitle: name, at: i, animated: false)
        }
        
        if brushes.count > 0 {
            brushSegement.selectedSegmentIndex = 0
            styleChanged(brushSegement)
        }
    }
    
    // MARK: - Shader Overlay Setup
    
    func setupShaderOverlay() {
        // Initialize Metal
        guard let device = MTLCreateSystemDefaultDevice() else {
            print("Metal is not supported on this device")
            return
        }
        metalDevice = device
        commandQueue = device.makeCommandQueue()
        
        // Setup Metal pipeline
        setupMetalPipeline()
        
        // Create container view for shader effect - match canvas frame exactly
        shaderOverlayView = UIView(frame: canvas.frame)
        shaderOverlayView.backgroundColor = .clear
        shaderOverlayView.isUserInteractionEnabled = false
        shaderOverlayView.autoresizingMask = canvas.autoresizingMask
        
        // Create MTKView for Metal rendering
        metalView = MTKView(frame: shaderOverlayView.bounds, device: device)
        metalView.backgroundColor = .clear
        metalView.framebufferOnly = false
        metalView.isPaused = true
        metalView.enableSetNeedsDisplay = true  // Enable manual drawing
        metalView.delegate = nil
        metalView.clearColor = MTLClearColorMake(0, 0, 0, 0)  // Transparent background
        metalView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        shaderOverlayView.addSubview(metalView)
        
        // Setup vertex buffers for full-screen quad
        setupVertexBuffers()
        
        // Add above canvas in the same superview
        canvas.superview?.addSubview(shaderOverlayView)
        canvas.superview?.bringSubviewToFront(shaderOverlayView)
        
        // Initially hidden
        shaderOverlayView.isHidden = true
    }
    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        
        // Keep shader overlay aligned with canvas position
        if shaderOverlayView != nil {
            shaderOverlayView.frame = canvas.frame
            metalView?.frame = shaderOverlayView.bounds
            
            // Update shader if it's currently enabled to reflect new layout
            if isShaderEnabled {
                updateShaderEffect()
            }
        }
    }
    
    func setupMetalPipeline() {
        guard let device = metalDevice else { return }
        
        // Load the Metal library
        guard let defaultLibrary = device.makeDefaultLibrary() else {
            print("Failed to create Metal library")
            return
        }
        
        // Load vertex and fragment functions for halftone shader
        guard let vertexFunction = defaultLibrary.makeFunction(name: "halftone_vertex"),
              let fragmentFunction = defaultLibrary.makeFunction(name: "halftone_fragment") else {
            print("Failed to load shader functions")
            return
        }
        
        // Create render pipeline descriptor
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        
        // Enable alpha blending for transparency
        pipelineDescriptor.colorAttachments[0].isBlendingEnabled = true
        pipelineDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        pipelineDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        pipelineDescriptor.colorAttachments[0].rgbBlendOperation = .add
        pipelineDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        pipelineDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        pipelineDescriptor.colorAttachments[0].alphaBlendOperation = .add
        
        // Create pipeline state
        do {
            pipelineState = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        } catch {
            print("Failed to create pipeline state: \(error)")
        }
    }
    
    func setupVertexBuffers() {
        guard let device = metalDevice else { return }
        
        // Full-screen quad vertices (normalized device coordinates)
        let vertices: [Float] = [
            -1.0, -1.0,  // Bottom-left
             1.0, -1.0,  // Bottom-right
            -1.0,  1.0,  // Top-left
             1.0,  1.0   // Top-right
        ]
        
        // Texture coordinates
        let texCoords: [Float] = [
            0.0, 1.0,  // Bottom-left
            1.0, 1.0,  // Bottom-right
            0.0, 0.0,  // Top-left
            1.0, 0.0   // Top-right
        ]
        
        vertexBuffer = device.makeBuffer(bytes: vertices, length: vertices.count * MemoryLayout<Float>.stride, options: [])
        texCoordBuffer = device.makeBuffer(bytes: texCoords, length: texCoords.count * MemoryLayout<Float>.stride, options: [])
    }
    
    func startShaderEffect() {
        isShaderEnabled = true
        shaderOverlayView.isHidden = false
        
        // Initial update
        updateShaderEffect()
    }
    
    func stopShaderEffect() {
        isShaderEnabled = false
        shaderOverlayView.isHidden = true
    }
    
    func updateShaderEffect() {
        guard isShaderEnabled else { return }
        guard let device = metalDevice,
              let commandQueue = commandQueue,
              let pipelineState = pipelineState else { return }
        
        // Get snapshot of canvas
        guard let snapshot = canvas.snapshot() else { return }
        
        // Convert UIImage to Metal texture
        guard let texture = createMetalTexture(from: snapshot, device: device) else { return }
        canvasTexture = texture
        
        // Trigger the Metal view to draw
        autoreleasepool {
            renderHalftoneEffect(with: texture)
        }
    }
    
    func renderHalftoneEffect(with texture: MTLTexture) {
        guard let commandQueue = commandQueue,
              let pipelineState = pipelineState else { return }
        
        // Get current drawable - this must be done fresh each frame
        guard let drawable = metalView.currentDrawable else {
            // If no drawable available, try again next frame
            return
        }
        
        // Create render pass descriptor manually
        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = drawable.texture
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        renderPassDescriptor.colorAttachments[0].storeAction = .store
        
        // Create command buffer
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        
        // Create render encoder
        guard let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else { return }
        
        renderEncoder.setRenderPipelineState(pipelineState)
        
        // Set vertex buffers
        renderEncoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        renderEncoder.setVertexBuffer(texCoordBuffer, offset: 0, index: 1)
        
        // Set fragment texture
        renderEncoder.setFragmentTexture(texture, index: 0)
        
        // Create and set halftone parameters struct
        var halftoneParams = (
            dotSize: Float(halftoneDotSize),
            smoothing: Float(halftoneSmoothing),
            blendMode: Int32(halftoneBlendMode)
        )
        renderEncoder.setFragmentBytes(&halftoneParams, length: MemoryLayout.size(ofValue: halftoneParams), index: 0)
        
        // Draw full-screen quad
        renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        
        renderEncoder.endEncoding()
        
        // Schedule drawable presentation
        commandBuffer.present(drawable)
        
        // Commit the command buffer
        commandBuffer.commit()
    }
    
    func createMetalTexture(from image: UIImage, device: MTLDevice) -> MTLTexture? {
        guard let cgImage = image.cgImage else { return nil }
        
        let textureLoader = MTKTextureLoader(device: device)
        
        do {
            let texture = try textureLoader.newTexture(cgImage: cgImage, options: [
                .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
                .SRGB: false
            ])
            return texture
        } catch {
            print("Failed to create texture: \(error)")
            return nil
        }
    }
    
    @IBAction func switchBackground(_ sender: UIButton) {
        sender.isSelected.toggle()
        backgroundView.isHidden = !sender.isSelected
    }
    
    @IBAction func changeSizeAction(_ sender: UISlider) {
        let size = Int(sender.value)
        canvas.currentBrush.pointSize = CGFloat(size)
        strokeSizeLabel.text = "\(size)"
    }
    
    @IBAction func styleChanged(_ sender: UISegmentedControl) {
        let index = sender.selectedSegmentIndex
        let brush = brushes[index]
        brush.color = color
        brush.use()
        strokeSizeLabel.text = "\(brush.pointSize)"
        sizeSlider.value = Float(brush.pointSize)
    }
    
    @IBAction func togglePencilMode(_ sender: UISwitch) {
        canvas.isPencilMode = sender.isOn
    }
    
    @IBAction func undoAction(_ sender: Any) {
        canvas.undo()
    }
    
    @IBAction func redoAction(_ sender: Any) {
        canvas.redo()
    }
    
    @IBAction func clearAction(_ sender: Any) {
        canvas.clear()
    }
    
    @IBAction func moreAction(_ sender: UIBarButtonItem) {
        let actionSheet = UIAlertController(title: "Choose Actions", message: nil, preferredStyle: .actionSheet)
        actionSheet.addAction(title: "Add Chartlet", style: .default) { [unowned self] (_) in
            self.addChartletAction()
        }
        
        // Toggle shader effect
        let shaderTitle = isShaderEnabled ? "Disable Halftone Shader" : "Enable Halftone Shader"
        actionSheet.addAction(title: shaderTitle, style: .default) { [unowned self] (_) in
            self.toggleShaderEffect()
        }
        
        // Halftone customization options (only show when shader is enabled)
        if isShaderEnabled {
            actionSheet.addAction(title: "Adjust Dot Size", style: .default) { [unowned self] (_) in
                self.adjustHalftoneDotSize()
            }
            actionSheet.addAction(title: "Change Blend Mode", style: .default) { [unowned self] (_) in
                self.selectHalftoneBlendMode()
            }
        }
        
        actionSheet.addAction(title: "Snapshot", style: .default) { [unowned self] (_) in
            self.snapshotAction(sender)
        }
        actionSheet.addAction(title: "Save", style: .default) { [unowned self] (_) in
            self.saveData()
        }
        actionSheet.addAction(title: "Cancel", style: .cancel)
        actionSheet.popoverPresentationController?.barButtonItem = sender
        present(actionSheet, animated: true, completion: nil)
    }
    
    func toggleShaderEffect() {
        if isShaderEnabled {
            stopShaderEffect()
        } else {
            startShaderEffect()
        }
    }
    
    func adjustHalftoneDotSize() {
        let alert = UIAlertController(title: "Adjust Dot Size", message: "Change the size of halftone dots\nCurrent: \(String(format: "%.1f", halftoneDotSize)) pixels", preferredStyle: .alert)
        
        alert.addTextField { textField in
            textField.placeholder = "Dot Size (4.0-20.0)"
            textField.keyboardType = .decimalPad
            textField.text = String(format: "%.1f", self.halftoneDotSize)
        }
        
        alert.addAction(UIAlertAction(title: "Apply", style: .default) { [weak self] _ in
            guard let self = self,
                  let text = alert.textFields?.first?.text,
                  let value = Float(text) else { return }
            
            // Clamp between 4.0 and 20.0
            self.halftoneDotSize = CGFloat(max(4.0, min(20.0, value)))
            
            // Update shader with new dot size
            self.updateShaderEffect()
        })
        
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }
    
    func selectHalftoneBlendMode() {
        let alert = UIAlertController(title: "Select Blend Mode", message: "Current: \(getBlendModeName(halftoneBlendMode))", preferredStyle: .actionSheet)
        
        let blendModes = [
            (0, "Multiply"),
            (1, "B&W Multiply"),
            (2, "Overlay"),
            (3, "B&W Overlay"),
            (4, "Screen Blend"),
            (5, "B&W Screen Blend"),
            (6, "Circles Only"),
            (7, "Color Mix")
        ]
        
        for (mode, name) in blendModes {
            let title = mode == halftoneBlendMode ? "✓ \(name)" : name
            alert.addAction(UIAlertAction(title: title, style: .default) { [weak self] _ in
                self?.halftoneBlendMode = mode
                self?.updateShaderEffect()
            })
        }
        
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.popoverPresentationController?.sourceView = view
        present(alert, animated: true)
    }
    
    func getBlendModeName(_ mode: Int) -> String {
        switch mode {
        case 0: return "Multiply"
        case 1: return "B&W Multiply"
        case 2: return "Overlay"
        case 3: return "B&W Overlay"
        case 4: return "Screen Blend"
        case 5: return "B&W Screen Blend"
        case 6: return "Circles Only"
        case 7: return "Color Mix"
        default: return "Unknown"
        }
    }
    
    func addChartletAction() {
        ChartletPicker.present(from: self, textures: chartlets) { [unowned self] (texture) in
            self.showEditor(for: texture)
        }
    }
    
    func showEditor(for texture: MLTexture) {
        ChartletEditor.present(from: self, for: texture) { [unowned self] (editor) in
            let result = editor.convertCoordinate(to: self.canvas)
            self.canvas.renderChartlet(at: result.center, size: result.size, textureID: texture.id, rotation: result.angle)
            // Update shader after adding chartlet
            self.updateShaderEffect()
        }
    }
    
    func snapshotAction(_ sender: Any) {
        let preview = PaintingPreview.create(from: .main)
        preview.image = canvas.snapshot()
        navigationController?.pushViewController(preview, animated: true)
    }
    
    func saveData() {
        self.chrysan.showMessage("Saving...")
        let exporter = DataExporter(canvas: canvas)
        let path = Path.temp().resource(Date().string())
        path.createDirectory()
        exporter.save(to: path.url, progress: { (progress) in
            self.chrysan.show(progress: progress, message: "Saving...")
        }) { (result) in
            if case let .failure(error) = result {
                self.chrysan.hide()
                let alert = UIAlertController(title: "Saving Failed", message: error.localizedDescription, preferredStyle: .alert)
                alert.addAction(title: "OK", style: .cancel)
                self.present(alert, animated: true, completion: nil)
            } else {
                let filename = "\(Date().string(format: "yyyyMMddHHmmss")).maliang"
                
                // Create a simple zip file using system compression
                let zipURL = Path.documents().resource(filename).url
                try? self.createZipFile(from: path.url, to: zipURL)
                try? FileManager.default.removeItem(at: path.url)
                self.chrysan.show(.succeed, message: "Saving Succeed!", hideDelay: 1)
            }
        }
    }
    
    func readDataIfNeeds() {
        guard let file = filePath else {
            return
        }
        chrysan.showMessage("Reading...")
        
        let path = Path(file)
        let temp = Path.temp().resource("temp.zip")
        let contents = Path.temp().resource("contents")
        
        do {
            try? FileManager.default.removeItem(at: temp.url)
            try FileManager.default.copyItem(at: path.url, to: temp.url)
            try self.extractZipFile(from: temp.url, to: contents.url)
        } catch {
            self.chrysan.hide()
            let alert = UIAlertController(title: "unzip failed", message: error.localizedDescription, preferredStyle: .alert)
            alert.addAction(title: "OK", style: .cancel)
            self.present(alert, animated: true, completion: nil)
            return
        }
        
        
        DataImporter.importData(from: contents.url, to: canvas, progress: { (progress) in
            
        }) { (result) in
            if case let .failure(error) = result {
                self.chrysan.hide()
                let alert = UIAlertController(title: "Reading Failed", message: error.localizedDescription, preferredStyle: .alert)
                alert.addAction(title: "OK", style: .cancel)
                self.present(alert, animated: true, completion: nil)
            } else {
                self.chrysan.show(.succeed, message: "Reading Succeed!", hideDelay: 1)
            }
            
        }
    }
    
    // MARK: - color
    @IBOutlet weak var colorSampleView: UIView!
    @IBOutlet weak var redSlider: UISlider!
    @IBOutlet weak var greenSlider: UISlider!
    @IBOutlet weak var blueSlider: UISlider!
    @IBOutlet weak var rl: UILabel!
    @IBOutlet weak var gl: UILabel!
    @IBOutlet weak var bl: UILabel!
    
    var r: CGFloat = 0
    var g: CGFloat = 0
    var b: CGFloat = 0
    
    @IBAction func colorChanged(_ sender: UISlider) {
        let value = Int(sender.value)
        let colorv = CGFloat(value) / 255
        switch sender.tag {
        case 0:
            r = colorv
            rl.text = "\(value)"
        case 1:
            g = colorv
            gl.text = "\(value)"
        case 2:
            b = colorv
            bl.text = "\(value)"
        default: break
        }
        
        colorSampleView.backgroundColor = color
        canvas.currentBrush.color = color
    }
    
    // MARK: - Zip Helper Methods
    
    func createZipFile(from sourceURL: URL, to zipURL: URL) throws {
        // For now, just copy the directory as a simple workaround
        // In a real implementation, you would use a proper zip library
        try FileManager.default.copyItem(at: sourceURL, to: zipURL)
    }
    
    func extractZipFile(from zipURL: URL, to destinationURL: URL) throws {
        // For now, just copy the file as a simple workaround
        // In a real implementation, you would use a proper zip library
        try FileManager.default.copyItem(at: zipURL, to: destinationURL)
    }
}

extension ViewController: DataObserver {
    /// called when a line strip is begin
    func lineStrip(_ strip: LineStrip, didBeginOn data: CanvasData) {
        self.redoButton.isEnabled = false
    }
    
    /// called when a element is finished
    func element(_ element: CanvasElement, didFinishOn data: CanvasData) {
        self.undoButton.isEnabled = true
        // Update shader when drawing is finished
        updateShaderEffect()
    }
    
    /// callen when clear the canvas
    func dataDidClear(_ data: CanvasData) {
        // Update shader when canvas is cleared
        updateShaderEffect()
    }
    
    /// callen when undo
    func dataDidUndo(_ data: CanvasData) {
        self.undoButton.isEnabled = true
        self.redoButton.isEnabled = data.canRedo
        // Update shader when undo is performed
        updateShaderEffect()
    }
    
    /// callen when redo
    func dataDidRedo(_ data: CanvasData) {
        self.undoButton.isEnabled = true
        self.redoButton.isEnabled = data.canRedo
        // Update shader when redo is performed
        updateShaderEffect()
    }
}

extension String {
    var floatValue: CGFloat {
        let db = Double(self) ?? 0
        return CGFloat(db)
    }
}
