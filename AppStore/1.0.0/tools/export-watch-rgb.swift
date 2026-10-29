// Lossless App Store format export: remove the alpha channel from opaque
// simulator screenshots without changing their layout, text or dimensions.
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppStore/1.0.0")
for (index,name) in ["player","library","folder","transfer"].enumerated() {
    let input = root.appendingPathComponent("screenshots/raw/watch-\(name).png")
    let output = root.appendingPathComponent(String(format:"screenshots/watch/%02d.png",index+1))
    guard let source=CGImageSourceCreateWithURL(input as CFURL,nil),
          let image=CGImageSourceCreateImageAtIndex(source,0,nil),
          let context=CGContext(data:nil,width:image.width,height:image.height,
            bitsPerComponent:8,bytesPerRow:image.width*4,
            space:CGColorSpace(name:CGColorSpace.sRGB)!,
            bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue) else { fatalError("Unable to read screenshot") }
    context.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height))
    guard let rgb=context.makeImage(),
          let destination=CGImageDestinationCreateWithURL(output as CFURL,UTType.png.identifier as CFString,1,nil) else { fatalError("Unable to export screenshot") }
    CGImageDestinationAddImage(destination,rgb,nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("PNG export failed") }
    print(output.lastPathComponent)
}
