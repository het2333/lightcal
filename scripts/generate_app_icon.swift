import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Original vector artwork: a leaf on a plate. No third-party image assets.
let context = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
let colors = [CGColor(srgbRed: 0.05, green: 0.58, blue: 0.40, alpha: 1), CGColor(srgbRed: 0.18, green: 0.78, blue: 0.53, alpha: 1)]
let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1])!
context.drawLinearGradient(gradient, start: CGPoint(x:0,y:0), end: CGPoint(x:1024,y:1024), options: [.drawsBeforeStartLocation,.drawsAfterEndLocation])
context.setFillColor(CGColor(gray: 0.98, alpha: 1))
context.fillEllipse(in: CGRect(x:208,y:196,width:608,height:608))
context.setStrokeColor(CGColor(srgbRed:0.82,green:0.95,blue:0.87,alpha:1))
context.setLineWidth(12)
context.strokeEllipse(in: CGRect(x:256,y:244,width:512,height:512))
context.setFillColor(CGColor(srgbRed:0.05,green:0.60,blue:0.38,alpha:1))
context.move(to:CGPoint(x:380,y:365))
context.addCurve(to:CGPoint(x:660,y:672),control1:CGPoint(x:296,y:591),control2:CGPoint(x:500,y:734))
context.addCurve(to:CGPoint(x:380,y:365),control1:CGPoint(x:733,y:457),control2:CGPoint(x:536,y:312))
context.closePath()
context.fillPath()
context.setStrokeColor(CGColor(gray:1,alpha:1))
context.setLineWidth(17)
context.setLineCap(.round)
context.move(to:CGPoint(x:405,y:391))
context.addCurve(to:CGPoint(x:616,y:625),control1:CGPoint(x:493,y:443),control2:CGPoint(x:527,y:538))
context.strokePath()
let image=context.makeImage()!
let output=URL(fileURLWithPath:CommandLine.arguments[1])
let destination=CGImageDestinationCreateWithURL(output as CFURL,UTType.png.identifier as CFString,1,nil)!
CGImageDestinationAddImage(destination,image,nil)
guard CGImageDestinationFinalize(destination) else { fatalError("Could not export app icon") }
