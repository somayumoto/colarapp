import Foundation
import Metal

struct U {
    var viewport: SIMD2<Float> = SIMD2(112, 64)
    var source: SIMD2<Float> = SIMD2(112, 32)
    var range: SIMD4<Float> = SIMD4(0, 1, 128.0 / 255, 1)
    var coefficients: SIMD4<Float> = SIMD4(1.5748, -0.187324, -0.468124, 1.8556)
    var flags: SIMD4<Int32> = SIMD4(0, 0, 1, 1)
    var parameters: SIMD4<Float> = SIMD4(1, 0, 0, 0)
}
// Uses the shipping shader source and executes it on the Mac GPU, independently of camera access.
let path = CommandLine.arguments[1]
let device = MTLCreateSystemDefaultDevice()!
let library = try device.makeLibrary(source: String(contentsOfFile: path, encoding: .utf8), options: nil)
let descriptor = MTLRenderPipelineDescriptor()
descriptor.vertexFunction = library.makeFunction(name: "comparisonVertex")
descriptor.fragmentFunction = library.makeFunction(name: "comparisonFragment")
descriptor.colorAttachments[0].pixelFormat = .rgba8Unorm
let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
let queue = device.makeCommandQueue()!
func texture(_ format: MTLPixelFormat, width: Int = 1, height: Int = 1, bytes: [UInt8]) -> MTLTexture {
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
    d.storageMode = .shared
    d.usage = .shaderRead
    let t = device.makeTexture(descriptor: d)!
    bytes.withUnsafeBytes { t.replace(region: MTLRegionMake2D(0,0,width,height), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: width * (format == .rg8Unorm ? 2 : 1)) }
    return t
}
func render(_ u: U, y: MTLTexture? = nil, c: MTLTexture? = nil) -> [UInt8] {
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 112, height: 64, mipmapped: false)
    d.storageMode = .shared; d.usage = [.renderTarget]
    let output = device.makeTexture(descriptor: d)!
    let p = MTLRenderPassDescriptor(); p.colorAttachments[0].texture = output; p.colorAttachments[0].loadAction = .clear; p.colorAttachments[0].storeAction = .store
    let b = queue.makeCommandBuffer()!; let e = b.makeRenderCommandEncoder(descriptor: p)!
    e.setRenderPipelineState(pipeline)
    var u = u; e.setFragmentBytes(&u, length: MemoryLayout<U>.stride, index: 0)
    e.setFragmentTexture(y ?? texture(.r8Unorm, bytes: [0]), index: 0)
    e.setFragmentTexture(c ?? texture(.rg8Unorm, bytes: [128,128]), index: 1)
    e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3); e.endEncoding(); b.commit(); b.waitUntilCompleted()
    if let error = b.error { fatalError("GPU failure: \(error)") }
    var bytes = [UInt8](repeating: 0, count: 112*64*4)
    bytes.withUnsafeMutableBytes { output.getBytes($0.baseAddress!, bytesPerRow: 112*4, from: MTLRegionMake2D(0,0,112,64), mipmapLevel: 0) }
    return bytes
}
func rgb(_ bytes: [UInt8], _ x: Int, _ y: Int) -> SIMD3<Float> {
    let i = (y*112+x)*4
    return SIMD3(Float(bytes[i]),Float(bytes[i+1]),Float(bytes[i+2])) / 255
}
var checks = 0
func expect(_ actual: SIMD3<Float>, _ expected: SIMD3<Float>, _ name: String, tolerance: Float = 0.012) {
    let diff = abs(actual.x-expected.x)+abs(actual.y-expected.y)+abs(actual.z-expected.z)
    guard diff < tolerance else { fatalError("\(name): \(actual) vs \(expected), delta \(diff)") }
    checks += 1
}
let colors: [SIMD3<Float>] = [SIMD3(1,0,0), SIMD3(1,0.4,0), SIMD3(1,1,0), SIMD3(0,1,0), SIMD3(0,1,1), SIMD3(0,0,1), SIMD3(1,0,1)]
for mode in 0...3 {
    for strength: Float in [0, 0.5, 1] {
        var u = U(); u.flags.x = Int32(mode); u.parameters.x = strength
        let output = render(u)
        for (i, original) in colors.enumerated() {
            let mapped: SIMD3<Float>
            switch mode {
            case 0: mapped = SIMD3(0,0,original.x)
            case 1: mapped = SIMD3(original.z,original.y,original.x)
            case 2:
                let gray = original.x*0.2126+original.y*0.7152+original.z*0.0722
                let dominance = max(0,original.x-max(original.y,original.z))
                mapped = SIMD3<Float>(repeating: gray)*(1-dominance)+SIMD3<Float>(0,0,1)*dominance
            default: mapped = original
            }
            expect(rgb(output,i*16+8,16), original*(1-strength)+mapped*strength, "mode\(mode) strength\(strength) swatch\(i)")
            expect(rgb(output,i*16+8,48), original, "bottom unchanged mode\(mode) strength\(strength) swatch\(i)")
        }
    }
}
for full in [true,false] {
    for coefficients: SIMD4<Float> in [SIMD4(1.402,-0.344136,-0.714136,1.772), SIMD4(1.5748,-0.187324,-0.468124,1.8556)] {
        let kr: Float = coefficients.x == 1.402 ? 0.299 : 0.2126
        let kb: Float = coefficients.x == 1.402 ? 0.114 : 0.0722
        for color: SIMD3<Float> in [SIMD3(1,0,0),SIMD3(0,1,0),SIMD3(0,0,1)] {
            let y = kr*color.x + (1-kr-kb)*color.y + kb*color.z
            let cb = (color.z-y)/coefficients.w
            let cr = (color.x-y)/coefficients.x
            func byte(_ value: Float) -> UInt8 { UInt8(min(255,max(0,value.rounded()))) }
            let yByte = byte(full ? y*255 : 16+y*219)
            let cbByte = byte(128+cb*(full ? 255 : 224))
            let crByte = byte(128+cr*(full ? 255 : 224))
            var u = U(); u.flags = SIMD4(3,0,0,1); u.coefficients = coefficients
            u.range = SIMD4(full ? 0 : 16.0/255, full ? 1 : 255.0/219,128.0/255,full ? 1 : 255.0/224)
            let output = render(u,y:texture(.r8Unorm,bytes:[yByte]),c:texture(.rg8Unorm,bytes:[cbByte,crByte]))
            expect(rgb(output,56,16),color,"YCbCr RGB fixture full=\(full) matrix=\(coefficients.x) color=\(color)",tolerance:0.025)
        }
        for value in [0,255] {
            var u = U(); u.flags = SIMD4(3,0,0,1); u.coefficients = coefficients
            u.range = SIMD4(full ? 0 : 16.0/255, full ? 1 : 255.0/219,128.0/255,full ? 1 : 255.0/224)
            let encoded = full ? value : (value == 0 ? 16 : 235)
            let bytes = render(u,y:texture(.r8Unorm,bytes:[UInt8(encoded)]),c:texture(.rg8Unorm,bytes:[128,128]))
            expect(rgb(bytes,56,16), SIMD3<Float>(repeating:Float(value)/255), "\(full ? "full" : "video") neutral\(value)")
        }
    }
}
for rotation in 0...3 {
    for fill in [false,true] {
        var u = U(); u.source = SIMD2(16,8); u.flags = SIMD4(3,Int32(rotation),0,fill ? 1 : 0)
        let gradient: [UInt8] = (0..<128).map { index in
            let horizontal = (index % 16) * 8
            let vertical = (index / 16) * 4
            return UInt8(32 + horizontal + vertical)
        }
        let y = texture(.r8Unorm,width:16,height:8,bytes:gradient)
        let result = render(u,y:y,c:texture(.rg8Unorm,bytes:[128,128]))
        for row in 0..<32 {
            for col in 0..<112 { expect(rgb(result,col,row),rgb(result,col,row+32),"same frame, rotation\(rotation), fill\(fill)") }
        }
    }
}
// Four different corners distinguish clockwise orientation, in addition to panel equality.
let cornerLuma = texture(.r8Unorm,width:2,height:2,bytes:[32,96,160,224])
let corners = [(47,7),(64,7),(47,24),(64,24)]
let rotations: [[Float]] = [[32,96,160,224],[160,32,224,96],[224,160,96,32],[96,224,32,160]]
for rotation in 0...3 {
    var u = U(); u.source = SIMD2(2,2); u.flags = SIMD4(3,Int32(rotation),0,0)
    let output = render(u,y:cornerLuma,c:texture(.rg8Unorm,bytes:[128,128]))
    for (i,point) in corners.enumerated() {
        expect(rgb(output,point.0,point.1), SIMD3<Float>(repeating: rotations[rotation][i]/255), "clockwise rotation\(rotation) corner\(i)")
    }
    expect(rgb(output,0,16),SIMD3(0.025,0.03,0.045),"aspect-fit letterbox")
    u.flags.w = 1
    let filled = render(u,y:cornerLuma,c:texture(.rg8Unorm,bytes:[128,128]))
    if rgb(filled,0,16).x < 0.1 { fatalError("aspect-fill should fill the panel") }
    checks += 1
}
print("PASS: \(checks) Metal pixel assertions; modes, intensities, YCbCr range/matrices, all rotations, matched split crops. Uniform stride \(MemoryLayout<U>.stride). GPU: \(device.name)")
