import Cocoa
import MetalKit

var vc:ViewController! = nil
var g = Graphics()
var aData = ArcBallData()

class ViewController: NSViewController, NSWindowDelegate, WGDelegate {
    var isStereo:Bool = false
    var isHighRes:Bool = true
    var isRotate:Bool = false
    var isMorph:Bool = false

    var control = Control()
    
    var threadGroupCount = MTLSize()
    var threadGroups = MTLSize()
    
    lazy var device: MTLDevice! = MTLCreateSystemDefaultDevice()
    var cBuffer:MTLBuffer! = nil
    var bBuffer:MTLBuffer! = nil
    var coloringTexture:MTLTexture! = nil
    var outTextureL:MTLTexture! = nil
    var outTextureR:MTLTexture! = nil
    var pipeline1:MTLComputePipelineState! = nil
    let queue = DispatchQueue(label:"Q")
    
    lazy var defaultLibrary: MTLLibrary! = { self.device.makeDefaultLibrary() }()
    lazy var commandQueue: MTLCommandQueue! = { return self.device.makeCommandQueue() }()
    
    @IBOutlet var wg: WidgetGroup!
    @IBOutlet var metalTextureViewL: MetalTextureView!
    @IBOutlet var metalTextureViewR: MetalTextureView!
    
    override func viewDidLoad() {
        super.viewDidLoad()
        vc = self
        
        cBuffer = device.makeBuffer(bytes: &control, length: MemoryLayout<Control>.stride, options:MTLResourceOptions.storageModeShared)
        
        do {
            let defaultLibrary:MTLLibrary! = device.makeDefaultLibrary()
            guard let kf1 = defaultLibrary.makeFunction(name: "kleinianShader")  else { fatalError() }
            pipeline1 = try device.makeComputePipelineState(function: kf1)
        } catch { fatalError("error creating pipelines") }
        
        let w = pipeline1.threadExecutionWidth
        let h = pipeline1.maxTotalThreadsPerThreadgroup / w
        threadGroupCount = MTLSizeMake(w, h, 1)

        control.txtOnOff = 0    // 'no texture'
        
        wg.delegate = self
        initializeWidgetGroup()
        layoutViews()
        alterAngle(0,0)
        
        Timer.scheduledTimer(withTimeInterval:0.05, repeats:true) { timer in self.timerHandler() }
    }
    
    override func viewDidAppear() {
        view.window?.delegate = self
        resizeIfNecessary()
        dvrCount = 1 // resize metalviews without delay
        reset()
    }
    
    //MARK: -
    
    func resizeIfNecessary() {
        let minWinSize:CGSize = CGSize(width:700, height:735)
        var r:CGRect = (view.window?.frame)!
        
        if r.size.width < minWinSize.width || r.size.height < minWinSize.height {
            r.size = minWinSize
            view.window?.setFrame(r, display: true)
        }
    }
    
    func windowDidResize(_ notification: Notification) {
        resizeIfNecessary()
        resetDelayedViewResizing()
    }
    
    //MARK: -
    
    var dvrCount:Int = 0
    
    // don't realloc metalTextures until they have finished resizing the window
    func resetDelayedViewResizing() {
        dvrCount = 10 // 20 = 1 second delay
    }
    
    //MARK: -
    
    var morphAngle:Float = 0
    
    func updateMorphingValues() -> Bool {
        var wasMorphed:Bool = false
        
        if isMorph {
            let s = sin(morphAngle)
            morphAngle += 0.001
            
            for index in 0 ..< wg.data.count {
                if wg.alterValueViaMorph(index,s) { wasMorphed = true }
            }
        }
        
        return wasMorphed
    }
    
    @objc func timerHandler() {
        let refresh:Bool = wg.update() || updateMorphingValues()
        if refresh && !isBusy { updateImage() }
        
        if dvrCount > 0 {
            dvrCount -= 1
            if dvrCount <= 0 {
                layoutViews()
            }
        }
    }
    
    //MARK: -
    
    func initializeWidgetGroup() {
        let coloringHeight:Float = Float(RowHT - 2)
        wg.reset()
        wg.addToggle("Q",.resolution)
        wg.addLine()
        wg.addSingleFloat("Z",&control.zoom,  0.2,2, 0.03, "Zoom")
        
        wg.addLine()
        wg.addSingleFloat("2",&control.fMaxSteps,10,300,10, "Max Steps")
        wg.addSingleFloat("",&control.fFinal_Iterations, 1,50,1, "FinalIter")
        wg.addSingleFloat("",&control.fBox_Iterations, 5,25,1, "BoxIter")
        wg.addLine()
        wg.addColoredCommand("3",.showBalls,"ShowBalls")
        wg.addColoredCommand("",.fourGen,"FourGen")
        
        wg.addLine()
        wg.addColoredCommand("",.doInversion,"DoInversion")
        wg.addTriplet("I",&control.InvCenter,0,1.5,0.02,"InvCenter")
        wg.addSingleFloat("",&control.InvRadius, 0.01,4,0.01, "InvRadius")
        wg.addSingleFloat("4",&control.DeltaAngle, 0.1,10,0.004, "DeltaAngle")

        wg.addLine()
        wg.addSingleFloat("X",&control.box_size_x, 0.01,2,0.003, "box_X")
        wg.addSingleFloat("Y",&control.box_size_z, 0.01,2,0.003, "box_Z")
        
        wg.addLine()
        wg.addSingleFloat("K",&control.KleinR, 0.01,2.5,0.03, "KleinR")
        wg.addSingleFloat("L",&control.KleinI, 0.01,2.5,0.03, "KleinI")
        
        wg.addLine()
        wg.addSingleFloat("5",&control.Clamp_y, 0.001,2,0.01, "Clamp_y")
        wg.addSingleFloat("",&control.Clamp_DF, 0.001,2,0.03, "Clamp_DF")
        wg.addColoredCommand("",.dfClamp,"DF < 1")

        wg.addLine()
        wg.addSingleFloat("E",&control.epsilon, 0.000001, 0.01, 0.0001, "epsilon")
        wg.addSingleFloat("",&control.normalEpsilon, 0.000001, 0.04, 0.0002, "N epsilon")
        
        let sPmin:Float = 0.01
        let sPmax:Float = 1
        let sPchg:Float = 0.03
        wg.addLine()
        wg.addSingleFloat("B",&control.lighting.diffuse,sPmin,sPmax,sPchg, "Bright")
        wg.addSingleFloat("",&control.lighting.specular,sPmin,sPmax,sPchg, "Shiny")
        wg.addTriplet("G",&control.lighting.position,-10,10,0.6,"Light")
        wg.addTriplet("C",&control.color,0,0.5,0.03,"Color")

        wg.addLine()
        wg.addCommand("V","Save/Load",.saveLoad)
        wg.addCommand("H","Help",.help)
        wg.addCommand("7","Reset",.reset)
        
        wg.addLine()
        wg.addColor(.stereo,Float(RowHT * 2))
        wg.addCommand("O","Stereo",.stereo)
        let parallaxRange:Float = 0.008
        wg.addSingleFloat("8",&control.parallax, -parallaxRange,+parallaxRange,0.0002, "Parallax")

        wg.addLine()
        wg.addCommand("M","Move",.move)
        wg.addCommand("R","Rotate",.rotate)
        
        wg.addLine()
        wg.addColor(.texture,coloringHeight)
        wg.addCommand("9","Texture",.texture)
        wg.addTriplet("T",&control.txtCenter,0.01,1,0.02,"Pos, Sz")
  
        wg.addLine()
        wg.addColor(.morph,coloringHeight)
        wg.addToggle("J",.morph)
        
        wg.refresh()
    }
    
    //MARK: -
    
    func wgCommand(_ cmd: WgIdent) {
        func presentPopover(_ name:String) {
            let mvc = NSStoryboard(name: NSStoryboard.Name("Main"), bundle: nil)
            let vc = mvc.instantiateController(withIdentifier: NSStoryboard.SceneIdentifier(name)) as! NSViewController
            self.present(vc, asPopoverRelativeTo: wg.bounds, of: wg, preferredEdge: .maxX, behavior: .transient)
        }
        
        switch(cmd) {
        case .saveLoad : presentPopover("SaveLoadVC")
        case .help : presentPopover("HelpVC")
        case .showBalls : control.showBalls = !control.showBalls; updateImage()
        case .doInversion : control.doInversion = !control.doInversion; updateImage()
        case .fourGen : control.fourGen = !control.fourGen; updateImage()
        case .dfClamp : control.dfClamp = !control.dfClamp; updateImage()
        case .stereo :
            isStereo = !isStereo
            initializeWidgetGroup()
            layoutViews()
            updateImage()
        case .texture :
            if control.txtOnOff > 0 {
               control.txtOnOff = 0
               updateImage()
            }
            else {
                loadImageFile()
            }
        case .reset :
            reset()
        default : break
        }
        
        wg.refresh()
    }
    
    func wgToggle(_ ident:WgIdent) {
        switch(ident) {
        case .resolution :
            isHighRes = !isHighRes
            setImageViewResolution()
            updateImage()
        case .morph :
            isMorph = !isMorph
        default : break
        }
        
        wg.refresh()
    }
    
    func wgGetString(_ ident:WgIdent) -> String {
        switch ident {
        case .resolution : return isHighRes ? "Res: High" : "Res: Low"
        case .morph : return isMorph ? "Morph: On" : "Morph: Off"
        default : return ""
        }
    }
    
    func wgGetColor(_ ident:WgIdent) -> NSColor {
        var highlight:Bool = false
        switch(ident) {
        case .showBalls : highlight = control.showBalls
        case .doInversion : highlight = control.doInversion
        case .fourGen : highlight = control.fourGen
        case .dfClamp : highlight = control.dfClamp
        case .stereo : highlight = isStereo
        case .rotate : highlight = isRotate
        case .texture : highlight = control.txtOnOff > 0
        case .morph : return isMorph ? wgMorphColor : wgBackgroundColor
        default : break
        }

        return highlight ? wgHighlightColor : wgBackgroundColor
    }
    
    func wgOptionSelected(_ ident: WgIdent, _ index: Int) {}
    func wgGetOptionString(_ ident: WgIdent) -> String { return "" }
    
    //MARK: -
    
    func reset() {
        isHighRes = false
        isMorph = false
        
        control.camera = float3(0.5586236, 1.1723881, -1.8257363)
        control.focus = float3(0.5693455, 1.1413786, -4.76854)
        control.zoom = 0.6141
        control.epsilon = 0.000700999982
        control.normalEpsilon = 0.00243199966
        
        control.lighting.position = float3(1.4000003, 4.2644997, 1.6055)
        control.lighting.diffuse = 0.653
        control.lighting.specular = 0.820
        
        control.color = float3(0.48, 0.029999973, 0.089999996)
        control.parallax = 0.0011
        control.fog = 180         // max distance
        
        control.fMaxSteps = 70
        control.fFinal_Iterations = 21
        control.fBox_Iterations = 17
        
        control.showBalls = true
        control.doInversion = true
        control.fourGen = false
        control.dfClamp = false
        control.Clamp_y = 0.221299887
        control.Clamp_DF = 0.00999999977
        control.box_size_x = 0.6318979
        control.box_size_z = 1.3839532
        control.KleinR = 1.9324
        control.KleinI = 0.04583
        
        control.InvCenter = float3(1.0517285, 0.7155759, 0.9883028)
        control.ReCenter = float3(0.0, 0.0, 0.1468)
        control.DeltaAngle = 5.5392437
        control.InvRadius = 2.06132293
        
        aData.endPosition = simd_float3x3([-0.713134, -0.670681, -0.147344], [0.000170747, -0.218116, 0.964759], [-0.683193, 0.68709, 0.152579])
        aData.transformMatrix = simd_float4x4([-0.713134, -0.670681, -0.147344, 0.0], [0.000170747, -0.218116, 0.964759, 0.0], [-0.683193, 0.68709, 0.152579, 0.0], [0.0, 0.0, 0.0, 1.0])
        
        alterAngle(0,0)
        updateImage()
        wg.morphReset()
        wg.hotKey("M")
    }
    
    //MARK: -
    
    func loadTexture(from image: NSImage) -> MTLTexture {
        let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
        
        let textureLoader = MTKTextureLoader(device: device)
        do {
            let textureOut = try textureLoader.newTexture(cgImage:cgImage)
            
            control.txtSize.x = Float(cgImage.width)
            control.txtSize.y = Float(cgImage.height)
            control.txtCenter.x = 0.5
            control.txtCenter.y = 0.5
            control.txtCenter.z = 0.01
            return textureOut
        }
        catch {
            fatalError("Can't load texture")
        }
    }
    
    func loadImageFile() {
        control.txtOnOff = 0
        
        let openPanel = NSOpenPanel()
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = false
        openPanel.canCreateDirectories = false
        openPanel.canChooseFiles = true
        openPanel.title = "Select Image for Texture"
        openPanel.allowedFileTypes = ["jpg","png"]
        
        openPanel.beginSheetModal(for:self.view.window!) { (response) in
            if response.rawValue == NSApplication.ModalResponse.OK.rawValue {
                let selectedPath = openPanel.url!.path
                
                if let image:NSImage = NSImage(contentsOfFile: selectedPath) {
                    self.coloringTexture = self.loadTexture(from: image)
                    self.control.txtOnOff = 1
                }
            }
            
            openPanel.close()
            
            if self.control.txtOnOff > 0 { // just loaded a texture
                self.wg.moveFocus(1)  // companion texture widgets
                self.updateImage()
            }
        }
    }
    
    //MARK: -
    
    func layoutViews() {
        let xs = view.bounds.width
        let ys = view.bounds.height
        let xBase:CGFloat = wg.isHidden ? 0 : 140
        
        if !wg.isHidden {
            wg.frame = CGRect(x:1, y:1, width:xBase-1, height:ys-2)
        }
        
        if isStereo {
            metalTextureViewR.isHidden = false
            let xs2:CGFloat = (xs - xBase)/2
            metalTextureViewL.frame = CGRect(x:xBase, y:0, width:xs2, height:ys)
            metalTextureViewR.frame = CGRect(x:xBase+xs2+1, y:0, width:xs2, height:ys) // +1 = 1 pixel of bkground between
        }
        else {
            metalTextureViewR.isHidden = true
            metalTextureViewL.frame = CGRect(x:xBase+1, y:1, width:xs-xBase-2, height:ys-2)
        }
        
        setImageViewResolution()
        updateImage()
    }
    
    func controlJustLoaded() {
        wg.refresh()
        setImageViewResolution()
        updateImage()
    }
    
    func setImageViewResolution() {
        control.xSize = Int32(metalTextureViewL.frame.width)
        control.ySize = Int32(metalTextureViewL.frame.height)
        if !isHighRes {
            control.xSize /= 2
            control.ySize /= 2
        }
        
        let xsz = Int(control.xSize)
        let ysz = Int(control.ySize)
        
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: xsz,
            height: ysz,
            mipmapped: false)
        
        outTextureL = device.makeTexture(descriptor: textureDescriptor)!
        outTextureR = device.makeTexture(descriptor: textureDescriptor)!
        
        metalTextureViewL.initialize(outTextureL)
        metalTextureViewR.initialize(outTextureR)
        
        let xs = xsz/threadGroupCount.width + 1
        let ys = ysz/threadGroupCount.height + 1
        threadGroups = MTLSize(width:xs, height:ys, depth: 1)
    }
    
    //MARK: -
    
    func calcRayMarch(_ who:Int) {
        var c = control
        if who == 0 { c.camera.x -= control.parallax }
        if who == 1 { c.camera.x += control.parallax }
        c.lighting.position = normalize(c.lighting.position)
        c.epsilon = control.epsilon / 100
        cBuffer.contents().copyMemory(from: &c, byteCount:MemoryLayout<Control>.stride)
        
        let commandBuffer = commandQueue.makeCommandBuffer()!
        let commandEncoder = commandBuffer.makeComputeCommandEncoder()!
        
        commandEncoder.setComputePipelineState(pipeline1)
        commandEncoder.setTexture(who == 0 ? outTextureL : outTextureR, index: 0)
        commandEncoder.setTexture(coloringTexture, index: 1)
        commandEncoder.setBuffer(cBuffer, offset: 0, index: 0)
        commandEncoder.dispatchThreadgroups(threadGroups, threadsPerThreadgroup: threadGroupCount)
        commandEncoder.endEncoding()
        
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }
    
    //MARK: -

    var isBusy:Bool = false
    
    func updateImage() {
        if isBusy { return }
        isBusy = true
        
        func toRectangular(_ sph:float3) -> float3 {
            let ss = sph.x * sin(sph.z);
            return float3( ss * cos(sph.y), ss * sin(sph.y), sph.x * cos(sph.z));
        }
        
        func toSpherical(_ rec:float3) -> float3 {
            return float3(length(rec),
                          atan2(rec.y,rec.x),
                          atan2(sqrt(rec.x*rec.x+rec.y*rec.y), rec.z));
        }
        
        control.viewVector = control.focus - control.camera
        control.topVector = toSpherical(control.viewVector)
        control.topVector.z += 1.5708
        control.topVector = toRectangular(control.topVector)
        control.sideVector = cross(control.viewVector,control.topVector)
        control.sideVector = normalize(control.sideVector) * length(control.topVector)
        
        control.Final_Iterations = Int32(control.fFinal_Iterations)
        control.Box_Iterations = Int32(control.fBox_Iterations)
        control.maxSteps = Int32(control.fMaxSteps);
        
        calcRayMarch(0)
        metalTextureViewL.display(metalTextureViewL.layer!)
        
        if isStereo {
            calcRayMarch(1)
            metalTextureViewR.display(metalTextureViewR.layer!)
        }
        
        isBusy = false
    }
    
    //MARK: -
    
    func alterAngle(_ dx:Float, _ dy:Float) {
        let center:CGFloat = 25
        arcBall.mouseDown(CGPoint(x: center, y: center))
        arcBall.mouseMove(CGPoint(x: center + CGFloat(dx), y: center + CGFloat(dy)))
        
        let direction = simd_make_float4(0,0.1,0,0)
        let rotatedDirection = simd_mul(aData.transformMatrix, direction)
        
        control.focus.x = rotatedDirection.x
        control.focus.y = rotatedDirection.y
        control.focus += control.camera
        
        updateImage()
    }
    
    func alterPosition(_ dx:Float, _ dy:Float, _ dz:Float) {
        func axisAlter(_ dir:float4, _ amt:Float) {
            let diff = simd_mul(aData.transformMatrix, dir) * amt / 50.0
            
            func alter(_ value: inout float3) {
                value.x -= diff.x
                value.y -= diff.y
                value.z -= diff.z
            }
            
            alter(&control.camera)
            alter(&control.focus)
        }
        
        let q:Float = optionKeyDown ? 1 : 0.1
        
        if shiftKeyDown {
            axisAlter(simd_make_float4(0,q,0,0),-dx * 2)
            axisAlter(simd_make_float4(0,0,q,0),dy)
        }
        else {
            axisAlter(simd_make_float4(q,0,0,0),dx)
            axisAlter(simd_make_float4(0,0,q,0),dy)
        }
        
        updateImage()
    }
    
    //MARK: -
    
    var shiftKeyDown:Bool = false
    var optionKeyDown:Bool = false
    var letterAKeyDown:Bool = false
    
    override func keyDown(with event: NSEvent) {
        super.keyDown(with: event)
        
        updateModifierKeyFlags(event)
        
        switch event.keyCode {
        case 123:   // Left arrow
            wg.hopValue(-1,0)
            return
        case 124:   // Right arrow
            wg.hopValue(+1,0)
            return
        case 125:   // Down arrow
            wg.hopValue(0,-1)
            return
        case 126:   // Up arrow
            wg.hopValue(0,+1)
            return
        case 43 :   // '<'
            wg.moveFocus(-1)
            return
        case 47 :   // '>'
            wg.moveFocus(1)
            return
        case 53 :   // Esc
            NSApplication.shared.terminate(self)
        case 0 :    // A
            letterAKeyDown = true
        case 18 :   // 1
            wg.isHidden = !wg.isHidden
            layoutViews()
        case 36 :   // <return>
            wg.togglealterValueViaMorph()
            return
        default:
            break
        }
        
        let keyCode = event.charactersIgnoringModifiers!.uppercased()
        //print("KeyDown ",keyCode,event.keyCode)
        
        wg.hotKey(keyCode)
    }
    
    override func keyUp(with event: NSEvent) {
        super.keyUp(with: event)
        
        wg.stopChanges()
        
        switch event.keyCode {
        case 0 :    // A
            letterAKeyDown = false
        default:
            break
        }        
    }
    
    //MARK: -
    
    func flippedYCoord(_ pt:NSPoint) -> NSPoint {
        var npt = pt
        npt.y = view.bounds.size.height - pt.y
        return npt
    }
    
    func updateModifierKeyFlags(_ ev:NSEvent) {
        let rv = ev.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue
        shiftKeyDown   = rv & (1 << 17) != 0
        optionKeyDown  = rv & (1 << 19) != 0
    }
    
    var pt = NSPoint()
    
    override func mouseDown(with event: NSEvent) {
        pt = flippedYCoord(event.locationInWindow)
    }
    
    override func mouseDragged(with event: NSEvent) {
        updateModifierKeyFlags(event)
        
        var npt = flippedYCoord(event.locationInWindow)
        npt.x -= pt.x
        npt.y -= pt.y
        wg.focusMovement(npt,1)
    }
    
    override func mouseUp(with event: NSEvent) {
        pt.x = 0
        pt.y = 0
        wg.focusMovement(pt,0)
    }
}

// ===============================================

class BaseNSView: NSView {
    override var acceptsFirstResponder: Bool { return true }
}
