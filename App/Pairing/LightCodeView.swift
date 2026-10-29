import SwiftUI
import CoreImage.CIFilterBuiltins
import LightCode

struct LightCodeView: View {
    let code:String
    var showsDetails = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var cells:[LightColor] { (try? LightCodeCodec.encode(code)) ?? [] }
    var body:some View {
        VStack(spacing:18) {
            TimelineView(.animation(minimumInterval:0.1,paused:reduceMotion)) { timeline in
                Canvas { context,size in
                    let width=min(size.width,size.height), inset=width*0.04, cell=width*0.92/12
                    let origin=CGPoint(x:(size.width-width)/2,y:(size.height-width)/2)
                    context.fill(Path(CGRect(origin:origin,size:CGSize(width:width,height:width))),with:.color(.white))
                    for index in cells.indices {
                        let color=cells[index]
                        let rect=CGRect(x:origin.x+inset+Double(index%12)*cell,y:origin.y+inset+Double(index/12)*cell,width:cell+0.3,height:cell+0.3)
                        let tint=Color(red:color.red,green:color.green,blue:color.blue)
                        context.fill(Path(rect),with:.color(tint))
                        guard index/12>0,index/12<11,index%12>0,index%12<11 else {continue}
                        let phase=reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate*0.55+Double(index)*2.17
                        let dot=CGRect(x:rect.midX+sin(phase)*cell*0.08-cell*0.08,y:rect.midY+cos(phase)*cell*0.08-cell*0.08,width:cell*0.16,height:cell*0.16)
                        context.drawLayer { layer in layer.addFilter(.shadow(color:tint.opacity(0.8),radius:cell*0.2));layer.fill(Path(ellipseIn:dot),with:.color(tint)) }
                    }
                }
            }
            .aspectRatio(1,contentMode:.fit)
            .accessibilityHidden(true)
            if showsDetails {
            Text(code).font(.system(.title,design:.monospaced).weight(.bold)).tracking(5)
                .accessibilityLabel("Kopplungscode \(code.map(String.init).joined(separator:" "))")
            if let qr=pairingQR(code:code) {
                Image(decorative:qr,scale:1).interpolation(.none).resizable().scaledToFit().frame(width:130,height:130).padding(10).background(.white,in:RoundedRectangle(cornerRadius:12)).accessibilityLabel("Alternativer QR-Code für dieselbe Fernseheranfrage")
            }
            Text("Lichtcode: experimentell · QR oder sechs Ziffern funktionieren als Alternative.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
    }
}

private func pairingQR(code:String) -> CGImage? {
    guard LightCodeCodec.isValidCode(code) else {return nil}
    let filter=CIFilter.qrCodeGenerator();filter.message=Data("film://pair?code=\(code)".utf8);filter.correctionLevel="M"
    guard let output=filter.outputImage else {return nil}
    let scaled=output.transformed(by:CGAffineTransform(scaleX:8,y:8));return CIContext().createCGImage(scaled,from:scaled.extent)
}
