#if os(iOS)
import SwiftUI
import AVFoundation
import Vision
import CoreImage
import LightCode

/// No camera image leaves this object. Starting and stopping are bound to the
/// visible scanner; light, QR and printed digits require two complete readings.
nonisolated final class PairingCamera: NSObject, ObservableObject, @unchecked Sendable, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureMetadataOutputObjectsDelegate {
    let session=AVCaptureSession()
    @MainActor @Published var message:String?
    @MainActor @Published var detectedCode:String?
    private let queue=DispatchQueue(label:"film.pairing.camera")
    private var readings=ConsistentLightReadings()
    private var configured=false
    private var active=false
    private var accepted=false
    private var lastFrameTime=0.0
    private var lastCandidateTime=0.0
    @MainActor private var wantsCamera=false
    private let context=CIContext(options:[.cacheIntermediates:false])
    @MainActor func start() {
        wantsCamera=true;detectedCode=nil;message=nil
        switch AVCaptureDevice.authorizationStatus(for:.video) {
        case .authorized: startAuthorized()
        case .notDetermined: AVCaptureDevice.requestAccess(for:.video) { [weak self] granted in Task { @MainActor in if granted, self?.wantsCamera == true {self?.startAuthorized()} else {self?.message="Der Kamerazugriff wurde nicht erlaubt. Gib den Code unten ein."} } }
        default: message="Kein Kamerazugriff. Du kannst den Code unten eingeben oder die Kamera in den Einstellungen erlauben."
        }
    }
    @MainActor private func startAuthorized() {
        guard wantsCamera else {return}
        queue.async { [weak self] in
            guard let self else {return};self.active=true;self.accepted=false;self.readings.reset()
            do {
                if !self.configured {try self.configure();self.configured=true}
                if self.active,!self.session.isRunning {self.session.startRunning()}
            } catch {Task { @MainActor in self.message="Die Kamera ist nicht verfügbar. Gib den Code unten ein."}}
        }
    }
    @MainActor func stop() {wantsCamera=false;queue.async {[weak self] in guard let self else {return};self.active=false;self.readings.reset();if self.session.isRunning {self.session.stopRunning()} } }
    private func configure() throws {
        session.beginConfiguration();defer {session.commitConfiguration()};session.sessionPreset = .hd1280x720
        guard let device=AVCaptureDevice.default(.builtInWideAngleCamera,for:.video,position:.back) else {throw PairingClientError.invalidResponse}
        let input=try AVCaptureDeviceInput(device:device)
        guard session.canAddInput(input) else {throw PairingClientError.invalidResponse};session.addInput(input)
        let video=AVCaptureVideoDataOutput();video.videoSettings=[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA];video.alwaysDiscardsLateVideoFrames=true;video.setSampleBufferDelegate(self,queue:queue)
        guard session.canAddOutput(video) else {throw PairingClientError.invalidResponse};session.addOutput(video)
        let metadata=AVCaptureMetadataOutput();guard session.canAddOutput(metadata) else {throw PairingClientError.invalidResponse};session.addOutput(metadata);metadata.setMetadataObjectsDelegate(self,queue:queue);metadata.metadataObjectTypes=[.qr]
    }
    func metadataOutput(_ output:AVCaptureMetadataOutput,didOutput metadataObjects:[AVMetadataObject],from connection:AVCaptureConnection) {
        guard active,!accepted else {return}
        for object in metadataObjects {if let value=(object as? AVMetadataMachineReadableCodeObject)?.stringValue,let code=LightCodeCodec.parseMarker(value) {receive(code);return}}
    }
    func captureOutput(_ output:AVCaptureOutput,didOutput sampleBuffer:CMSampleBuffer,from connection:AVCaptureConnection) {
        guard active,!accepted,let buffer=CMSampleBufferGetImageBuffer(sampleBuffer) else {return}
        let now=CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        guard now-lastFrameTime>0.22 else {return};lastFrameTime=now
        let text = VNRecognizeTextRequest()
        text.recognitionLevel = .accurate
        text.usesLanguageCorrection = false
        text.minimumTextHeight = 0.025
        do {
            try VNImageRequestHandler(cvPixelBuffer:buffer,orientation:.up,options:[:]).perform([text])
            let codes = Set((text.results ?? []).compactMap { observation -> String? in
                guard let candidate = observation.topCandidates(1).first, candidate.confidence >= 0.8 else { return nil }
                return LightCodeCodec.parseCameraDigits(candidate.string)
            })
            if codes.count == 1, let code = codes.first { receive(code); return }
        } catch { /* Keep QR and legacy optical fallback available. */ }
        let request=VNDetectRectanglesRequest();request.maximumObservations=5;request.minimumAspectRatio=0.55;request.maximumAspectRatio=1;request.minimumSize=0.16;request.quadratureTolerance=35
        do {
            try VNImageRequestHandler(cvPixelBuffer:buffer,orientation:.up,options:[:]).perform([request])
            for rect in request.results ?? [] {if let code=decode(buffer:buffer,rectangle:rect) {receive(code);return}}
            // Optical misses do not reset a concurrently observed QR marker.
        } catch {readings.reset()}
    }
    private func receive(_ code:String) {
        let now=ProcessInfo.processInfo.systemUptime
        if now-lastCandidateTime>1.5 {readings.reset()};lastCandidateTime=now
        guard let consistent=readings.accept(code) else {return};accepted=true;active=false
        if session.isRunning {session.stopRunning()}
        Task { @MainActor [weak self] in self?.detectedCode=consistent}
    }
    private func decode(buffer:CVPixelBuffer,rectangle:VNRectangleObservation) -> String? {
        let image=CIImage(cvPixelBuffer:buffer),width=image.extent.width,height=image.extent.height
        func vector(_ point:CGPoint)->CIVector {CIVector(x:point.x*width,y:point.y*height)}
        guard let filter=CIFilter(name:"CIPerspectiveCorrection",parameters:[kCIInputImageKey:image,"inputTopLeft":vector(rectangle.topLeft),"inputTopRight":vector(rectangle.topRight),"inputBottomRight":vector(rectangle.bottomRight),"inputBottomLeft":vector(rectangle.bottomLeft)]),let corrected=filter.outputImage else {return nil}
        let scale=144/corrected.extent.width
        let normalized=corrected.transformed(by:CGAffineTransform(translationX:-corrected.extent.minX,y:-corrected.extent.minY)).transformed(by:CGAffineTransform(scaleX:scale,y:144/corrected.extent.height))
        var pixels=[UInt8](repeating:0,count:144*144*4)
        context.render(normalized,toBitmap:&pixels,rowBytes:144*4,bounds:CGRect(x:0,y:0,width:144,height:144),format:.RGBA8,colorSpace:CGColorSpaceCreateDeviceRGB())
        var colors=[LightColor]()
        for row in 0..<12 {for column in 0..<12 {
            let x=Int((0.04+(Double(column)+0.5)/12*0.92)*144)
            let y=Int((0.04+(Double(row)+0.5)/12*0.92)*144)
            var sum=[Double](repeating:0,count:3)
            for dy in -1...1 {for dx in -1...1 {let index=((y+dy)*144+x+dx)*4;for channel in 0..<3 {sum[channel]+=Double(pixels[index+channel])/255}}}
            colors.append(LightColor(sum[0]/9,sum[1]/9,sum[2]/9))
        }}
        // Core Image raster rows can be inverted relative to camera orientation.
        if let code=LightCodeCodec.decode(colors) {return code}
        return LightCodeCodec.decode((0..<144).map {colors[(11-$0/12)*12+$0%12]})
    }
}

struct PairingCameraPreview: UIViewRepresentable {
    let camera:PairingCamera
    final class Preview:UIView {
        override class var layerClass:AnyClass {AVCaptureVideoPreviewLayer.self}
        var preview:AVCaptureVideoPreviewLayer {layer as! AVCaptureVideoPreviewLayer}
    }
    func makeUIView(context:Context)->Preview {let view=Preview();view.preview.session=camera.session;view.preview.videoGravity = .resizeAspectFill;return view}
    func updateUIView(_ view:Preview,context:Context) {}
    static func dismantleUIView(_ view:Preview,coordinator:()) {view.preview.session=nil}
}
#endif
