// Pure geometry used by the scanner. No ARKit import so it can be unit-tested on the Mac with swiftc
// (see mobile/tools/test_scanmath.sh). Conventions are documented in contracts/SCAN_BUNDLE_V1.md.
import Foundation
import simd

enum ScanMath {
    /// Back-project depth pixel (i, j) of a depth map of size (dw, dh) whose RGB image has size (iw, ih)
    /// and RGB intrinsics K (column-major simd_float3x3, ARKit convention). Returns the point in the ARKit
    /// camera frame (+X right, +Y up, -Z forward), metres.
    @inline(__always)
    static func unproject(i: Int, j: Int, depth: Float, dw: Int, iw: Int, fx: Float, fy: Float, cx: Float, cy: Float) -> SIMD3<Float> {
        let s = Float(iw) / Float(dw)
        let u = (Float(i) + 0.5) * s - 0.5
        let v = (Float(j) + 0.5) * s - 0.5
        let x = (u - cx) * depth / fx
        let y = (v - cy) * depth / fy
        return SIMD3<Float>(x, -y, -depth)
    }

    @inline(__always)
    static func transform(_ m: simd_float4x4, _ p: SIMD3<Float>) -> SIMD3<Float> {
        let r = m * SIMD4<Float>(p.x, p.y, p.z, 1)
        return SIMD3<Float>(r.x, r.y, r.z)
    }

    /// Rotation angle (radians) between the rotation parts of two camera-to-world transforms.
    static func rotationAngle(_ a: simd_float4x4, _ b: simd_float4x4) -> Float {
        let ra = simd_float3x3(SIMD3(a.columns.0.x, a.columns.0.y, a.columns.0.z),
                               SIMD3(a.columns.1.x, a.columns.1.y, a.columns.1.z),
                               SIMD3(a.columns.2.x, a.columns.2.y, a.columns.2.z))
        let rb = simd_float3x3(SIMD3(b.columns.0.x, b.columns.0.y, b.columns.0.z),
                               SIMD3(b.columns.1.x, b.columns.1.y, b.columns.1.z),
                               SIMD3(b.columns.2.x, b.columns.2.y, b.columns.2.z))
        let r = ra.transpose * rb
        let tr = r.columns.0.x + r.columns.1.y + r.columns.2.z
        let c = max(-1, min(1, (tr - 1) / 2))
        return acos(c)
    }

    static func translation(_ m: simd_float4x4) -> SIMD3<Float> {
        SIMD3<Float>(m.columns.3.x, m.columns.3.y, m.columns.3.z)
    }

    /// Gravity direction expressed in the camera frame (world gravity is -Y in a gravity-aligned ARKit session).
    static func gravityInCamera(_ cameraToWorld: simd_float4x4) -> SIMD3<Float> {
        let g = SIMD3<Float>(0, -1, 0)
        let c0 = SIMD3(cameraToWorld.columns.0.x, cameraToWorld.columns.0.y, cameraToWorld.columns.0.z)
        let c1 = SIMD3(cameraToWorld.columns.1.x, cameraToWorld.columns.1.y, cameraToWorld.columns.1.z)
        let c2 = SIMD3(cameraToWorld.columns.2.x, cameraToWorld.columns.2.y, cameraToWorld.columns.2.z)
        return SIMD3<Float>(simd_dot(c0, g), simd_dot(c1, g), simd_dot(c2, g))   // R^T g
    }

    /// EXIF orientation (1, 3, 6, 8) that displays a sensor-native ARKit image with gravity pointing down.
    /// Works for any way the phone is mounted (portrait, landscape either way, upside down on a rig).
    static func exifOrientation(gravityCamera g: SIMD3<Float>) -> Int {
        if abs(g.x) > abs(g.y) {
            return g.x > 0 ? 6 : 8          // gravity toward image right: stored top is visual right
        }
        return g.y < 0 ? 1 : 3              // gravity toward image bottom: upright
    }

    /// Pitch of the optical axis above the horizon in degrees (negative = looking down).
    static func pitchDeg(_ cameraToWorld: simd_float4x4) -> Float {
        let fwd = -SIMD3<Float>(cameraToWorld.columns.2.x, cameraToWorld.columns.2.y, cameraToWorld.columns.2.z)
        return asin(max(-1, min(1, fwd.y))) * 180 / .pi
    }

    /// Estimated motion blur in RGB pixels from rotation only: angular speed x exposure x focal length.
    /// A heuristic: it ignores translation (small at field distances) and rolling shutter.
    static func rotationalBlurPx(angularSpeed: Float, exposure: Float, fx: Float) -> Float {
        angularSpeed * exposure * fx
    }

    /// Voxel key packing 21 bits per axis (covers +-10 km at 1 cm voxels).
    @inline(__always)
    static func voxelKey(_ p: SIMD3<Float>, inv: Float) -> Int64 {
        let ix = Int64((p.x * inv).rounded(.down)) + (1 << 20)
        let iy = Int64((p.y * inv).rounded(.down)) + (1 << 20)
        let iz = Int64((p.z * inv).rounded(.down)) + (1 << 20)
        return (ix & 0x1FFFFF) | ((iy & 0x1FFFFF) << 21) | ((iz & 0x1FFFFF) << 42)
    }

    /// Full-range BT.601 YCbCr to RGB (ARKit capturedImage is 420f).
    @inline(__always)
    static func ycbcrToRGB(y: UInt8, cb: UInt8, cr: UInt8) -> (UInt8, UInt8, UInt8) {
        let yf = Float(y), cbf = Float(cb) - 128, crf = Float(cr) - 128
        let r = yf + 1.402 * crf
        let g = yf - 0.344136 * cbf - 0.714136 * crf
        let b = yf + 1.772 * cbf
        func c(_ v: Float) -> UInt8 { UInt8(max(0, min(255, v.rounded()))) }
        return (c(r), c(g), c(b))
    }
}

/// Voxel-averaging accumulator for the fused cloud. Not thread-safe: use from one queue.
final class VoxelGrid {
    let voxel: Float
    let maxVoxels: Int
    private var index: [Int64: Int32] = [:]
    private(set) var sx: [Float] = [], sy: [Float] = [], sz: [Float] = []
    private(set) var sr: [UInt32] = [], sg: [UInt32] = [], sb: [UInt32] = []
    private(set) var count: [UInt16] = []
    private(set) var conf: [UInt8] = []
    private(set) var full = false
    var droppedForCap = 0

    init(voxel: Float, maxVoxels: Int) {
        self.voxel = voxel
        self.maxVoxels = maxVoxels
        index.reserveCapacity(min(maxVoxels, 400_000))
    }

    var size: Int { count.count }

    @inline(__always)
    func add(_ p: SIMD3<Float>, r: UInt8, g: UInt8, b: UInt8, confidence: UInt8) {
        let k = ScanMath.voxelKey(p, inv: 1 / voxel)
        if let ii = index[k] {
            let i = Int(ii)
            if count[i] == UInt16.max { return }
            sx[i] += p.x; sy[i] += p.y; sz[i] += p.z
            sr[i] += UInt32(r); sg[i] += UInt32(g); sb[i] += UInt32(b)
            count[i] += 1
            if confidence > conf[i] { conf[i] = confidence }
            return
        }
        if count.count >= maxVoxels { full = true; droppedForCap += 1; return }
        index[k] = Int32(count.count)
        sx.append(p.x); sy.append(p.y); sz.append(p.z)
        sr.append(UInt32(r)); sg.append(UInt32(g)); sb.append(UInt32(b))
        count.append(1); conf.append(confidence)
    }

    /// Binary little-endian PLY: float x y z, uchar red green blue, uchar confidence (max ARKit level seen),
    /// ushort samples (depth samples averaged into the voxel). Only voxels with >= minSamples are written.
    func plyData(minSamples: Int, comments: [String]) -> (Data, Int) {
        var keep: [Int] = []
        keep.reserveCapacity(count.count)
        for i in 0..<count.count where Int(count[i]) >= minSamples { keep.append(i) }
        var header = "ply\nformat binary_little_endian 1.0\n"
        for c in comments { header += "comment \(c.replacingOccurrences(of: "\n", with: " "))\n" }
        header += "element vertex \(keep.count)\nproperty float x\nproperty float y\nproperty float z\n"
        header += "property uchar red\nproperty uchar green\nproperty uchar blue\nproperty uchar confidence\nproperty ushort samples\nend_header\n"
        var d = Data(header.utf8)
        d.reserveCapacity(d.count + keep.count * 18)
        var buf = [UInt8](repeating: 0, count: 18)
        for i in keep {
            let n = Float(count[i])
            var x = sx[i] / n, y = sy[i] / n, z = sz[i] / n
            withUnsafeBytes(of: &x) { buf[0] = $0[0]; buf[1] = $0[1]; buf[2] = $0[2]; buf[3] = $0[3] }
            withUnsafeBytes(of: &y) { buf[4] = $0[0]; buf[5] = $0[1]; buf[6] = $0[2]; buf[7] = $0[3] }
            withUnsafeBytes(of: &z) { buf[8] = $0[0]; buf[9] = $0[1]; buf[10] = $0[2]; buf[11] = $0[3] }
            let c = UInt32(count[i])
            buf[12] = UInt8(min(255, (sr[i] + c / 2) / c))
            buf[13] = UInt8(min(255, (sg[i] + c / 2) / c))
            buf[14] = UInt8(min(255, (sb[i] + c / 2) / c))
            buf[15] = conf[i]
            buf[16] = UInt8(count[i] & 0xFF); buf[17] = UInt8(count[i] >> 8)
            d.append(contentsOf: buf)
        }
        return (d, keep.count)
    }
}
