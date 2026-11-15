// Mac-side checks of ios/Runner/ScanMath.swift. Run: mobile/tools/test_scanmath.sh
import Foundation
import simd

var failures = 0
func check(_ ok: Bool, _ msg: String) { if !ok { failures += 1; print("FAIL: \(msg)") } else { print("ok   \(msg)") } }
func near(_ a: Float, _ b: Float, _ tol: Float) -> Bool { abs(a - b) <= tol }

// iPhone-like intrinsics for a 1920x1440 image; depth 256x192
let iw = 1920, dw = 256, dh = 192
let fx: Float = 1450, fy: Float = 1450, cx: Float = 959.5, cy: Float = 719.5

// 1. principal point maps onto the optical axis (-Z), at the given depth
let s = Float(iw) / Float(dw)
let ic = Int((cx + 0.5) / s - 0.5), jc = Int((cy + 0.5) / s - 0.5)
let p0 = ScanMath.unproject(i: ic, j: jc, depth: 2, dw: dw, iw: iw, fx: fx, fy: fy, cx: cx, cy: cy)
check(near(p0.z, -2, 1e-6) && abs(p0.x) < 0.01 && abs(p0.y) < 0.01, "principal point -> (0,0,-d): \(p0)")
// pixel to the right and below -> +X and -Y
let pr = ScanMath.unproject(i: dw - 1, j: dh - 1, depth: 1, dw: dw, iw: iw, fx: fx, fy: fy, cx: cx, cy: cy)
check(pr.x > 0 && pr.y < 0, "bottom-right pixel is +X, -Y in ARKit camera frame")

// 2. render the analytic depth of a world wall z = -3 seen from a rotated, translated camera, back-project, recover the wall
let yaw: Float = 20 * .pi / 180
var pose = simd_float4x4(simd_quatf(angle: yaw, axis: SIMD3(0, 1, 0)))
pose.columns.3 = SIMD4(0.4, 1.2, 0.5, 1)
var maxErr: Float = 0
for j in stride(from: 0, to: dh, by: 7) {
    for i in stride(from: 0, to: dw, by: 7) {
        // ray through the depth pixel centre, camera frame, at z-depth 1
        let r1 = ScanMath.unproject(i: i, j: j, depth: 1, dw: dw, iw: iw, fx: fx, fy: fy, cx: cx, cy: cy)
        let o = ScanMath.translation(pose)
        let dirW = ScanMath.transform(pose, r1) - o   // world direction for z-depth 1
        let t = (-3 - o.z) / dirW.z                   // z-depth that hits the wall
        let pw = ScanMath.transform(pose, ScanMath.unproject(i: i, j: j, depth: t, dw: dw, iw: iw, fx: fx, fy: fy, cx: cx, cy: cy))
        maxErr = max(maxErr, abs(pw.z + 3))
    }
}
check(maxErr < 1e-4, "wall z=-3 recovered from analytic depth, max error \(maxErr) m")

// 3. a 1 m wide target at 2 m spans fx*1/2 pixels in the image; check metric width through the depth grid
let half = Float(1450) * 0.5 / 2      // 362.5 image px each side
let iL = Int((cx - half + 0.5) / s - 0.5), iR = Int((cx + half + 0.5) / s - 0.5)
let a = ScanMath.unproject(i: iL, j: jc, depth: 2, dw: dw, iw: iw, fx: fx, fy: fy, cx: cx, cy: cy)
let b = ScanMath.unproject(i: iR, j: jc, depth: 2, dw: dw, iw: iw, fx: fx, fy: fy, cx: cx, cy: cy)
check(near(simd_distance(a, b), 1.0, 0.02), "1 m target at 2 m measures \(simd_distance(a, b)) m (depth-pixel quantisation \(2 * s / fx * 2) m)")

// 4. rotation angle and pitch
let r90 = simd_float4x4(simd_quatf(angle: .pi / 2, axis: SIMD3(1, 0, 0)))
check(near(ScanMath.rotationAngle(matrix_identity_float4x4, r90), .pi / 2, 1e-5), "rotation angle 90 deg")
check(near(ScanMath.pitchDeg(matrix_identity_float4x4), 0, 1e-4), "identity pose looks at the horizon")
let down = simd_float4x4(simd_quatf(angle: -.pi / 4, axis: SIMD3(1, 0, 0)))
check(near(ScanMath.pitchDeg(down), -45, 1e-3), "pitch -45 when tilted down")

// 5. EXIF orientation from gravity for each way the phone can sit on the rig
check(ScanMath.exifOrientation(gravityCamera: ScanMath.gravityInCamera(matrix_identity_float4x4)) == 1, "landscape (sensor-native) -> 1")
let flip = simd_float4x4(simd_quatf(angle: .pi, axis: SIMD3(0, 0, 1)))
check(ScanMath.exifOrientation(gravityCamera: ScanMath.gravityInCamera(flip)) == 3, "landscape upside down -> 3")
// landscape -> upright portrait = turning the phone clockwise as its user sees it = -90 deg about camera +Z
let portrait = simd_float4x4(simd_quatf(angle: -.pi / 2, axis: SIMD3(0, 0, 1)))
check(ScanMath.exifOrientation(gravityCamera: ScanMath.gravityInCamera(portrait)) == 6, "portrait upright -> 6")
let portraitInv = simd_float4x4(simd_quatf(angle: .pi / 2, axis: SIMD3(0, 0, 1)))
check(ScanMath.exifOrientation(gravityCamera: ScanMath.gravityInCamera(portraitInv)) == 8, "portrait upside down -> 8")

// 6. voxel keys and grid averaging
let k1 = ScanMath.voxelKey(SIMD3(-0.005, 0, 0), inv: 100), k2 = ScanMath.voxelKey(SIMD3(0.005, 0, 0), inv: 100)
check(k1 != k2, "voxel keys differ across zero")
let g = VoxelGrid(voxel: 0.01, maxVoxels: 10)
g.add(SIMD3(0.001, 0.002, 0.003), r: 10, g: 20, b: 30, confidence: 1)
g.add(SIMD3(0.003, 0.004, 0.005), r: 30, g: 40, b: 50, confidence: 2)
g.add(SIMD3(0.5, 0.5, 0.5), r: 0, g: 0, b: 0, confidence: 0)
let (data, n) = g.plyData(minSamples: 2, comments: ["test"])
check(n == 1 && g.size == 2, "min_samples filter keeps 1 of 2 voxels")
let body = data.suffix(18)
let x = body.withUnsafeBytes { $0.load(fromByteOffset: 0, as: Float.self) }
check(near(x, 0.002, 1e-7) && body[body.startIndex + 12] == 20 && body[body.startIndex + 15] == 2, "voxel mean position, colour and max confidence")
let cap = VoxelGrid(voxel: 0.01, maxVoxels: 2)
for q in 0..<5 { cap.add(SIMD3(Float(q), 0, 0), r: 0, g: 0, b: 0, confidence: 2) }
check(cap.size == 2 && cap.full && cap.droppedForCap == 3, "voxel cap enforced and reported")

// 7. colour conversion
let (gr, gg, gb) = ScanMath.ycbcrToRGB(y: 128, cb: 128, cr: 128)
check(gr == 128 && gg == 128 && gb == 128, "neutral YCbCr -> grey")

print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
