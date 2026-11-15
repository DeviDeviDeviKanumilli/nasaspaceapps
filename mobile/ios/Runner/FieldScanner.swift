// Native ARKit capture for Field Scan. Flutter talks to it over:
//   MethodChannel  "field_scan/scanner"         commands (capabilities, prepare, start/stop recording, ...)
//   EventChannel   "field_scan/scanner/events"  status ~4 Hz, keyframe, warning, auto-stop events
//   PlatformView   "field_scan/ar_view"         camera preview (ARSCNView) sharing the same ARSession
// Output folder layout and conventions: contracts/SCAN_BUNDLE_V1.md.
import ARKit
import AVFoundation
import AudioToolbox
import CoreImage
import CoreLocation
import CryptoKit
import Flutter
import ImageIO
import SceneKit
import UIKit
import UniformTypeIdentifiers

struct TriggerConfig {
    var mode = "movement"          // movement | interval | both | manual
    var intervalS = 1.0
    var moveM: Float = 0.10
    var turnDeg: Float = 10
    var minGapS = 0.35
    var maxBlurPx: Float = 2.0
    var steadyWaitS = 1.5
    var photoEvery = 0             // 0 = no full-resolution photos; n = every n-th keyframe
}

struct FuseConfig {
    var enabled = true
    var voxelM: Float = 0.01
    var minConfidence: UInt8 = 1   // 0 low, 1 medium, 2 high
    var minRangeM: Float = 0.15
    var maxRangeM: Float = 5.0
    var maxVoxels = 1_500_000
    var hz = 3.0
    var minSamples = 2
}

final class FieldScanner: NSObject, ARSessionDelegate, FlutterStreamHandler, CLLocationManagerDelegate {
    static let shared = FieldScanner()

    let session = ARSession()
    private let arQueue = DispatchQueue(label: "fieldscan.ar")
    private let ioQueue = DispatchQueue(label: "fieldscan.io")
    private let fuseQueue = DispatchQueue(label: "fieldscan.fuse")
    private let ci = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
    private var sink: FlutterEventSink?
    private let speech = AVSpeechSynthesizer()
    private let location = CLLocationManager()
    private var lastFix: CLLocation?

    // session state (arQueue)
    private var running = false
    private var meshEnabled = false
    private var depthEnabled = false
    private var hiResAvailable = false
    private var tracking = "not_started"
    private var prevPose: simd_float4x4?
    private var prevT: TimeInterval = 0
    private var armedAt = Date.distantPast          // when tracking was last reset (session.run with .resetTracking)
    private var driftSince: TimeInterval = -1      // "normal" tracking but an impossible camera speed, since t
    private var angSpeed: Float = 0
    private var lastStatusT: TimeInterval = 0
    private var lastDepthStats: [String: Any] = [:]

    // recording state (arQueue unless noted)
    private var recording = false
    private var paused = false
    private var dir: URL?
    private var scanId = ""
    private var startedUTC = Date()
    private var startedT: TimeInterval = -1
    private var trig = TriggerConfig()
    private var fuse = FuseConfig()
    private var cues = (sound: false, speech: false)
    private var kfCount = 0
    private var photoCount = 0
    private var lastKFPose: simd_float4x4?
    private var lastKFT: TimeInterval = -1
    private var dueSince: TimeInterval = -1
    private var dueReason = ""
    private var manualPending = false
    private var kfBusy = false
    private var photoBusy = false
    private var lastFuseT: TimeInterval = -1
    private var fuseBusy = false
    private var limitedSince: TimeInterval = -1
    private var limitedTotal: TimeInterval = 0
    private var limitedEpisodes = 0
    private var maxKeyframes = 600
    private var maxSeconds: Double = 0
    private var minFreeMB = 500
    private var travelled: Float = 0
    private var lastTravelPos: SIMD3<Float>?
    private var blurRiskCount = 0
    private var interruptions = 0
    private var stopReason: String?

    // io state (ioQueue)
    private var files: [[String: Any]] = []
    private var kfHandle: FileHandle?
    private var logHandle: FileHandle?
    private var depthAgg = (valid: 0, total: 0, low: 0, med: 0, high: 0, frames: 0)
    private var rangeHist = [Int](repeating: 0, count: 11)   // 0.5 m bins 0..5 m, last = beyond

    // fusion (fuseQueue)
    private var grid: VoxelGrid?
    private var fusedFrames = 0

    // ------------------------------------------------------------------ registration
    static func register(with registrar: FlutterPluginRegistrar) {
        let s = FieldScanner.shared
        let ch = FlutterMethodChannel(name: "field_scan/scanner", binaryMessenger: registrar.messenger())
        ch.setMethodCallHandler { call, result in s.handle(call, result) }
        FlutterEventChannel(name: "field_scan/scanner/events", binaryMessenger: registrar.messenger()).setStreamHandler(s)
        registrar.register(ARPreviewFactory(), withId: "field_scan/ar_view")
        s.session.delegate = s
        s.session.delegateQueue = s.arQueue
        s.location.delegate = s
        s.location.desiredAccuracy = kCLLocationAccuracyBest
    }

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        sink = events; return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? { sink = nil; return nil }

    private func emit(_ m: [String: Any]) {
        DispatchQueue.main.async { self.sink?(m) }
    }

    // ------------------------------------------------------------------ method calls
    private func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        let a = call.arguments as? [String: Any] ?? [:]
        switch call.method {
        case "capabilities":
            result(capabilities())
        case "prepare":
            prepare(mesh: a["mesh"] as? Bool ?? true, hiRes: a["hiRes"] as? Bool ?? true)
            result(capabilities())
        case "startRecording":
            arQueue.async { result(self.startRecording(a)) }
        case "pause":
            arQueue.async { self.paused = true; self.log("paused", [:]); result(nil) }
        case "resume":
            arQueue.async { self.paused = false; self.log("resumed", [:]); result(nil) }
        case "captureNow":
            arQueue.async { self.manualPending = true; result(nil) }
        case "stopRecording":
            arQueue.async { self.stopRecording(reason: a["reason"] as? String ?? "user", result: result) }
        case "stopSession":
            arQueue.async {
                if !self.recording { self.session.pause(); self.running = false }
                result(nil)
            }
        case "keepAwake":
            UIApplication.shared.isIdleTimerDisabled = a["on"] as? Bool ?? false
            result(nil)
        case "setBrightness":
            if let v = a["value"] as? Double { UIScreen.main.brightness = CGFloat(v) }
            result(Double(UIScreen.main.brightness))
        case "speak":
            say(a["text"] as? String ?? "", force: true); result(nil)
        case "cue":
            playCue(a["name"] as? String ?? "tick", force: true); result(nil)
        case "requestLocation":
            requestLocation(); result(nil)
        case "freeSpaceMB":
            result(freeMB())
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func modelIdentifier() -> String {
        var u = utsname(); uname(&u)
        return withUnsafeBytes(of: &u.machine) { b in
            String(decoding: b.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }

    func capabilities() -> [String: Any] {
        let wt = ARWorldTrackingConfiguration.isSupported
        var hi = false
        if #available(iOS 16.0, *) { hi = ARWorldTrackingConfiguration.recommendedVideoFormatForHighResolutionFrameCapturing != nil }
        return [
            "arkit": wt,
            "sceneDepth": wt && ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth),
            "smoothedSceneDepth": wt && ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth),
            "mesh": wt && ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh),
            "meshClassification": wt && ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification),
            "highResFrames": wt && hi,
            "modelIdentifier": modelIdentifier(),
            "osVersion": UIDevice.current.systemVersion,
            "deviceName": UIDevice.current.model,
            "cameraPermission": AVCaptureDevice.authorizationStatus(for: .video).rawValue,
            "thermal": thermalName(),
            "freeMB": freeMB(),
        ]
    }

    private func prepare(mesh: Bool, hiRes: Bool) {
        guard ARWorldTrackingConfiguration.isSupported else { return }
        let c = ARWorldTrackingConfiguration()
        c.worldAlignment = .gravity
        c.isAutoFocusEnabled = true
        c.environmentTexturing = .none
        depthEnabled = ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
        if depthEnabled { c.frameSemantics.insert(.sceneDepth) }     // unsmoothed on purpose; smoothed is never used
        if mesh && ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) {
            c.sceneReconstruction = .meshWithClassification; meshEnabled = true
        } else if mesh && ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            c.sceneReconstruction = .mesh; meshEnabled = true
        } else { meshEnabled = false }
        hiResAvailable = false
        if #available(iOS 16.0, *), hiRes,
           let f = ARWorldTrackingConfiguration.recommendedVideoFormatForHighResolutionFrameCapturing {
            c.videoFormat = f; hiResAvailable = true
        }
        UIDevice.current.isBatteryMonitoringEnabled = true
        if !running { armedAt = Date() }
        session.run(c, options: running ? [] : [.resetTracking, .removeExistingAnchors])
        arQueue.async { self.running = true }
    }

    // ------------------------------------------------------------------ recording
    private func startRecording(_ a: [String: Any]) -> Any {
        if recording { return FlutterError(code: "busy", message: "Already recording", details: nil) }
        guard running else { return FlutterError(code: "not_running", message: "Camera session is not running", details: nil) }
        guard let path = a["dir"] as? String else { return FlutterError(code: "args", message: "dir missing", details: nil) }
        let d = URL(fileURLWithPath: path)
        do {
            try FileManager.default.createDirectory(at: d.appendingPathComponent("keyframes"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: d.appendingPathComponent("photos"), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: d.appendingPathComponent("keyframes.jsonl").path, contents: nil)
            FileManager.default.createFile(atPath: d.appendingPathComponent("log.jsonl").path, contents: nil)
        } catch {
            return FlutterError(code: "io", message: error.localizedDescription, details: nil)
        }
        if let t = a["trigger"] as? [String: Any] {
            trig.mode = t["mode"] as? String ?? trig.mode
            trig.intervalS = t["intervalS"] as? Double ?? trig.intervalS
            trig.moveM = Float(t["moveM"] as? Double ?? Double(trig.moveM))
            trig.turnDeg = Float(t["turnDeg"] as? Double ?? Double(trig.turnDeg))
            trig.minGapS = t["minGapS"] as? Double ?? trig.minGapS
            trig.maxBlurPx = Float(t["maxBlurPx"] as? Double ?? Double(trig.maxBlurPx))
            trig.steadyWaitS = t["steadyWaitS"] as? Double ?? trig.steadyWaitS
            trig.photoEvery = t["photoEvery"] as? Int ?? trig.photoEvery
        }
        if let f = a["fuse"] as? [String: Any] {
            fuse.enabled = f["enabled"] as? Bool ?? fuse.enabled
            fuse.voxelM = Float(f["voxelM"] as? Double ?? Double(fuse.voxelM))
            fuse.minConfidence = UInt8(f["minConfidence"] as? Int ?? Int(fuse.minConfidence))
            fuse.minRangeM = Float(f["minRangeM"] as? Double ?? Double(fuse.minRangeM))
            fuse.maxRangeM = Float(f["maxRangeM"] as? Double ?? Double(fuse.maxRangeM))
            fuse.maxVoxels = f["maxVoxels"] as? Int ?? fuse.maxVoxels
            fuse.hz = f["hz"] as? Double ?? fuse.hz
            fuse.minSamples = f["minSamples"] as? Int ?? fuse.minSamples
        }
        if let l = a["limits"] as? [String: Any] {
            maxKeyframes = l["maxKeyframes"] as? Int ?? maxKeyframes
            maxSeconds = l["maxSeconds"] as? Double ?? maxSeconds
            minFreeMB = l["minFreeMB"] as? Int ?? minFreeMB
        }
        cues = (a["sound"] as? Bool ?? false, a["speech"] as? Bool ?? false)
        if cues.speech { try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.duckOthers, .mixWithOthers]) }

        // In rig mode the camera stays armed between scans; drift built up while idle must not carry into this
        // scan. Start from fresh tracking when the session has been running a while (keyframes and fusion wait for
        // "normal" tracking, so the moments after the reset are skipped, not recorded).
        if Date().timeIntervalSince(armedAt) > 10, let cfg = session.configuration {
            session.run(cfg, options: [.resetTracking, .removeExistingAnchors])
            armedAt = Date()
            prevPose = nil
        }
        driftSince = -1
        dir = d
        scanId = a["scanId"] as? String ?? UUID().uuidString.lowercased()
        startedUTC = Date()
        startedT = -1
        kfCount = 0; photoCount = 0
        lastKFPose = nil; lastKFT = -1; dueSince = -1; dueReason = ""; manualPending = false
        kfBusy = false; photoBusy = false; lastFuseT = -1; fuseBusy = false
        limitedSince = -1; limitedTotal = 0; limitedEpisodes = 0
        travelled = 0; lastTravelPos = nil; blurRiskCount = 0; interruptions = 0; stopReason = nil
        paused = false
        let fc = fuse
        fuseQueue.sync { self.grid = fc.enabled && self.depthEnabled ? VoxelGrid(voxel: fc.voxelM, maxVoxels: fc.maxVoxels) : nil; self.fusedFrames = 0 }
        ioQueue.sync {
            self.files = []
            self.depthAgg = (0, 0, 0, 0, 0, 0)
            self.rangeHist = [Int](repeating: 0, count: 11)
            self.kfHandle = try? FileHandle(forWritingTo: d.appendingPathComponent("keyframes.jsonl"))
            self.logHandle = try? FileHandle(forWritingTo: d.appendingPathComponent("log.jsonl"))
        }
        if a["location"] as? Bool == true { DispatchQueue.main.async { self.requestLocation() } } else { lastFix = nil }
        recording = true
        log("recording_started", ["trigger_mode": trig.mode, "depth": depthEnabled, "mesh": meshEnabled, "hi_res": hiResAvailable && trig.photoEvery > 0])
        playCue("start"); say("Recording")
        return ["scanId": scanId, "depth": depthEnabled, "mesh": meshEnabled, "hiRes": hiResAvailable && trig.photoEvery > 0]
    }

    private func autoStop(_ reason: String, _ spoken: String) {
        guard recording, stopReason == nil else { return }
        stopReason = reason
        log("auto_stop", ["reason": reason])
        say(spoken)
        emit(["type": "autoStop", "reason": reason])
    }

    private func stopRecording(reason: String, result: @escaping FlutterResult) {
        guard recording, let d = dir else { result(FlutterError(code: "not_recording", message: "Not recording", details: nil)); return }
        recording = false
        if limitedSince >= 0, let t = session.currentFrame?.timestamp { limitedTotal += t - limitedSince; limitedSince = -1 }
        let endUTC = Date()
        let meshData = meshEnabled ? collectMesh() : nil
        let summaryBase: [String: Any] = [
            "scanId": scanId, "startUTC": iso(startedUTC), "endUTC": iso(endUTC),
            "keyframes": kfCount, "photos": photoCount,
            "depth": depthEnabled, "mesh": meshEnabled, "hiRes": hiResAvailable && trig.photoEvery > 0,
            "trigger": ["mode": trig.mode, "interval_s": trig.intervalS, "move_m": trig.moveM, "turn_deg": trig.turnDeg,
                        "min_gap_s": trig.minGapS, "max_blur_px": trig.maxBlurPx, "steady_wait_s": trig.steadyWaitS,
                        "photo_every": trig.photoEvery],
            "fuse": ["enabled": fuse.enabled && depthEnabled, "voxel_m": fuse.voxelM, "min_confidence": fuse.minConfidence,
                     "min_range_m": fuse.minRangeM, "max_range_m": fuse.maxRangeM, "max_voxels": fuse.maxVoxels,
                     "hz": fuse.hz, "min_samples": fuse.minSamples],
            "trackingLimitedS": limitedTotal, "trackingLimitedEpisodes": limitedEpisodes,
            "pathLengthM": travelled, "blurRiskKeyframes": blurRiskCount, "interruptions": interruptions,
            "stopReason": stopReason ?? reason,
            "modelIdentifier": modelIdentifier(), "osVersion": UIDevice.current.systemVersion,
        ]
        log("recording_stopped", ["reason": stopReason ?? reason])
        playCue("stop"); say("Saved \(kfCount) frames")
        let fix = lastFix
        // Wait for in-flight keyframes and fusion, then finish on the io queue.
        let fc = fuse
        let sid = scanId
        DispatchQueue.global(qos: .userInitiated).async {
            var waits = 0
            while waits < 100 {   // up to 5 s for an in-flight full-resolution photo
                var busy = false
                self.arQueue.sync { busy = self.photoBusy || self.kfBusy }
                if !busy { break }
                usleep(50_000); waits += 1
            }
            var plyInfo: [String: Any] = [:]
            self.fuseQueue.sync {
                if let g = self.grid {
                    let (data, n) = g.plyData(minSamples: fc.minSamples, comments: [
                        "Field Scan fused point cloud (DERIVED from ARKit sceneDepth keyframes)",
                        "scan_id \(sid)", "frame arkit_session_world, metres, right-handed, +Y up (gravity)",
                        "voxel_m \(fc.voxelM) min_confidence \(fc.minConfidence) range_m \(fc.minRangeM)-\(fc.maxRangeM) min_samples \(fc.minSamples)",
                        "confidence = highest ARKit level seen in the voxel (0 low,1 medium,2 high); samples = depth samples averaged",
                    ])
                    plyInfo = ["points": n, "voxels": g.size, "fusedFrames": self.fusedFrames, "capped": g.full, "droppedForCap": g.droppedForCap]
                    self.ioQueue.sync { self.writeFile(d, "point_cloud_fused.ply", data, role: "derived_point_cloud", mime: "application/x-ply",
                                                       lineage: "voxel average of keyframe-independent sceneDepth samples (see processing)") }
                }
                self.grid = nil
            }
            self.ioQueue.sync {
                if let m = meshData {
                    self.writeFile(d, "mesh_arkit.ply", m.0, role: "derived_mesh", mime: "application/x-ply",
                                   lineage: "ARKit scene reconstruction (ARMeshAnchor), world frame")
                    plyInfo["meshVertices"] = m.1; plyInfo["meshFaces"] = m.2; plyInfo["meshAnchors"] = m.3
                }
                self.writeThumbnail(d)
                try? self.kfHandle?.close(); self.kfHandle = nil
                try? self.logHandle?.close(); self.logHandle = nil
                for (name, role) in [("keyframes.jsonl", "keyframe_index"), ("log.jsonl", "capture_log")] {
                    if let data = try? Data(contentsOf: d.appendingPathComponent(name)) {
                        self.files.append(self.fileRecord(name, data, role: role, mime: "application/x-ndjson", lineage: "written during capture"))
                    }
                }
                var s = summaryBase
                for (k, v) in plyInfo { s[k] = v }
                let ag = self.depthAgg
                s["depthStats"] = ag.total > 0 ? [
                    "keyframes_with_depth": ag.frames,
                    "valid_fraction": Double(ag.valid) / Double(ag.total),
                    "confidence_fractions": ["low": Double(ag.low) / Double(ag.total), "medium": Double(ag.med) / Double(ag.total), "high": Double(ag.high) / Double(ag.total)],
                    "range_hist_0_5m_bins_0p5": self.rangeHist,
                ] as [String: Any] : NSNull()
                if let f = fix {
                    s["location"] = ["latitude": f.coordinate.latitude, "longitude": f.coordinate.longitude,
                                     "horizontal_accuracy_m": f.horizontalAccuracy, "altitude_m": f.altitude,
                                     "vertical_accuracy_m": f.verticalAccuracy, "fix_utc": self.iso(f.timestamp)]
                }
                s["files"] = self.files
                // Keep-awake is owned by the Dart side (AppState.updateAwake): a phone on the rig must stay awake
                // between scans, so stopping a recording does not touch it.
                DispatchQueue.main.async { result(s) }
            }
        }
    }

    // ------------------------------------------------------------------ ARSessionDelegate (arQueue)
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let t = frame.timestamp
        let pose = frame.camera.transform
        var linSpeed: Float = 0
        if let p = prevPose, t > prevT {
            angSpeed = ScanMath.rotationAngle(p, pose) / Float(t - prevT)
            linSpeed = simd_distance(ScanMath.translation(p), ScanMath.translation(pose)) / Float(t - prevT)
        }
        prevPose = pose; prevT = t

        let tr = trackingName(frame.camera.trackingState)
        if tr != tracking {
            if recording {
                log("tracking", ["state": tr])
                if tr != "normal" && limitedSince < 0 { limitedSince = t; limitedEpisodes += 1; say("Tracking limited. Move slower."); playCue("warn") }
                if tr == "normal" && limitedSince >= 0 { limitedTotal += t - limitedSince; limitedSince = -1 }
            }
            tracking = tr
        }

        if recording && !paused && stopReason == nil {
            if startedT < 0 { startedT = t }
            let pos = ScanMath.translation(pose)
            if tr == "normal" {
                if let lp = lastTravelPos { travelled += simd_distance(lp, pos) }
                lastTravelPos = pos
            } else { lastTravelPos = nil }
            // ARKit can lose its visual reference (lens blocked, dark, a blank surface right in front) and keep
            // integrating motion while still saying "normal": the camera then "moves" metres per second and every
            // later frame lands in the wrong place (seen 15 Nov 2026, up to 800 m/s). A phone being scanned with
            // does not move faster than 5 m/s; if it seems to for over a second, stop and say why.
            if tr == "normal" && linSpeed > 5 {
                if driftSince < 0 { driftSince = t; log("tracking_drift", ["speed_m_s": Double(linSpeed)]) }
                if t - driftSince > 1.0 {
                    autoStop("tracking_drift", "Tracking lost. Stopping. Point the camera at the scene.")
                }
            } else { driftSince = -1 }
            evaluateTrigger(frame, t: t, pose: pose, normal: tr == "normal")
            if fuse.enabled, depthEnabled, tr == "normal", !fuseBusy, t - lastFuseT >= 1.0 / max(0.2, fuse.hz),
               let dd = frame.sceneDepth {
                lastFuseT = t; fuseBusy = true
                let job = FuseJob(depth: dd.depthMap, conf: dd.confidenceMap, image: frame.capturedImage,
                                  K: frame.camera.intrinsics, imageW: Int(frame.camera.imageResolution.width), pose: pose)
                fuseQueue.async { self.runFuse(job); self.arQueue.async { self.fuseBusy = false } }
            }
            checkLimits(t)
        }
        if t - lastStatusT >= 0.25 { lastStatusT = t; emitStatus(frame) }
    }

    func sessionWasInterrupted(_ session: ARSession) {
        arQueue.async {
            if self.recording { self.interruptions += 1; self.log("interrupted", [:]) }
            self.emit(["type": "warning", "code": "interrupted", "message": "Camera interrupted (app in background or another app took the camera)."])
        }
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        arQueue.async { if self.recording { self.log("interruption_ended", ["note": "ARKit relocalizes; capture waits for normal tracking"]) } }
    }

    func sessionShouldAttemptRelocalization(_ session: ARSession) -> Bool { true }

    func session(_ session: ARSession, didFailWithError error: Error) {
        arQueue.async {
            if self.recording { self.log("session_error", ["error": error.localizedDescription]) }
            self.running = false
            self.emit(["type": "warning", "code": "session_failed", "message": error.localizedDescription])
        }
    }

    private func evaluateTrigger(_ frame: ARFrame, t: TimeInterval, pose: simd_float4x4, normal: Bool) {
        var due = ""
        if manualPending { due = "manual" }
        else if lastKFT < 0 { due = trig.mode == "manual" ? "" : "first" }
        else if t - lastKFT >= trig.minGapS {
            let moved = lastKFPose.map { simd_distance(ScanMath.translation($0), ScanMath.translation(pose)) } ?? 0
            let turned = lastKFPose.map { ScanMath.rotationAngle($0, pose) * 180 / .pi } ?? 0
            let byMove = moved >= trig.moveM || turned >= trig.turnDeg
            let byTime = t - lastKFT >= trig.intervalS
            switch trig.mode {
            case "movement": if byMove { due = moved >= trig.moveM ? "moved" : "turned" }
            case "interval": if byTime { due = "interval" }
            case "both": if byMove { due = moved >= trig.moveM ? "moved" : "turned" } else if byTime { due = "interval" }
            default: break
            }
        }
        if due.isEmpty { dueSince = -1; return }
        if dueSince < 0 { dueSince = t; dueReason = due }
        guard normal, !kfBusy else { return }        // never record while tracking is limited
        let K = frame.camera.intrinsics
        let blur = ScanMath.rotationalBlurPx(angularSpeed: angSpeed, exposure: Float(frame.camera.exposureDuration), fx: K[0][0])
        let waited = t - dueSince
        if blur > trig.maxBlurPx && waited < trig.steadyWaitS && dueReason != "manual" { return }
        let reason = dueReason
        manualPending = false; dueSince = -1
        writeKeyframe(frame, t: t, pose: pose, reason: reason, blur: blur, blurRisk: blur > trig.maxBlurPx)
    }

    private func checkLimits(_ t: TimeInterval) {
        if kfCount >= maxKeyframes { autoStop("max_keyframes", "Frame limit reached. Stopping."); return }
        if maxSeconds > 0 && startedT >= 0 && t - startedT >= maxSeconds { autoStop("max_duration", "Time limit reached. Stopping."); return }
        if Int(t * 4) % 20 == 0 {    // about every 5 s
            if freeMB() < minFreeMB { autoStop("low_storage", "Storage almost full. Stopping."); return }
            if ProcessInfo.processInfo.thermalState == .critical { autoStop("thermal_critical", "Phone too hot. Stopping."); return }
            let b = UIDevice.current.batteryLevel
            if b >= 0 && b < 0.05 && UIDevice.current.batteryState == .unplugged { autoStop("battery_low", "Battery low. Stopping."); return }
        }
    }

    // ------------------------------------------------------------------ keyframes
    private func writeKeyframe(_ frame: ARFrame, t: TimeInterval, pose: simd_float4x4, reason: String, blur: Float, blurRisk: Bool) {
        kfCount += 1
        let n = kfCount
        lastKFT = t; lastKFPose = pose
        if blurRisk { blurRiskCount += 1 }
        kfBusy = true
        let K = frame.camera.intrinsics
        let res = frame.camera.imageResolution
        let g = ScanMath.gravityInCamera(pose)
        let exif = ScanMath.exifOrientation(gravityCamera: g)
        var rec: [String: Any] = [
            "type": "keyframe", "index": n, "t_frame_s": t, "t_since_start_s": startedT >= 0 ? t - startedT : 0, "utc": iso(Date()),
            "trigger": reason,
            "image": ["file": String(format: "keyframes/kf_%05d.jpg", n), "width": Int(res.width), "height": Int(res.height),
                      "source": "ARFrame.capturedImage (YCbCr 420f) -> sRGB JPEG q0.9", "exif_orientation": exif],
            "intrinsics": ["fx": K[0][0], "fy": K[1][1], "cx": K[2][0], "cy": K[2][1], "for_width": Int(res.width), "for_height": Int(res.height)],
            "camera_to_world": colMajor(pose),
            "tracking": tracking,
            "exposure_s": frame.camera.exposureDuration, "exposure_offset": frame.camera.exposureOffset,
            "gravity_camera": [g.x, g.y, g.z], "pitch_deg": ScanMath.pitchDeg(pose),
            "angular_speed_rad_s": angSpeed, "blur_est_px": blur, "blur_risk": blurRisk,
        ]
        let image = frame.capturedImage
        let depth = frame.sceneDepth
        let takePhoto = hiResAvailable && trig.photoEvery > 0 && (n - 1) % trig.photoEvery == 0 && !photoBusy
        emit(["type": "keyframe", "index": n, "trigger": reason, "blurRisk": blurRisk])
        playCue("tick")
        if n % 25 == 0 { say("\(n) frames") }
        let d = dir!
        ioQueue.async {
            if let jpg = self.jpeg(image, orientation: exif) {
                self.writeFile(d, String(format: "keyframes/kf_%05d.jpg", n), jpg, role: "keyframe_rgb", mime: "image/jpeg", lineage: "ARFrame.capturedImage")
            }
            if let dd = depth {
                let (df, w, h) = self.copyPlane(dd.depthMap, bytesPerPixel: 4)
                self.writeFile(d, String(format: "keyframes/kf_%05d.f32", n), df, role: "keyframe_depth", mime: "application/octet-stream",
                               lineage: "ARFrame.sceneDepth.depthMap float32 metres (unsmoothed)")
                var depthRec: [String: Any] = ["file": String(format: "keyframes/kf_%05d.f32", n), "width": w, "height": h,
                                               "format": "float32_le_metres_row_major", "kind": "sceneDepth"]
                if let cm = dd.confidenceMap {
                    let (cf, _, _) = self.copyPlane(cm, bytesPerPixel: 1)
                    self.writeFile(d, String(format: "keyframes/kf_%05d.u8", n), cf, role: "keyframe_confidence", mime: "application/octet-stream",
                                   lineage: "ARFrame.sceneDepth.confidenceMap (0 low, 1 medium, 2 high)")
                    depthRec["confidence_file"] = String(format: "keyframes/kf_%05d.u8", n)
                    depthRec["stats"] = self.depthStats(df, cf)
                }
                rec["depth"] = depthRec
            }
            self.appendLine(self.kfHandle, rec)
            self.arQueue.async { self.kfBusy = false }
        }
        if takePhoto, #available(iOS 16.0, *) {
            photoBusy = true
            session.captureHighResolutionFrame { [weak self] hf, err in
                guard let self = self else { return }
                guard let hf = hf else {
                    self.arQueue.async { self.photoBusy = false; self.log("photo_failed", ["keyframe": n, "error": err?.localizedDescription ?? "unknown"]) }
                    return
                }
                let hp = hf.camera.transform
                let hK = hf.camera.intrinsics
                let hres = hf.camera.imageResolution
                let hg = ScanMath.gravityInCamera(hp)
                let hexif = ScanMath.exifOrientation(gravityCamera: hg)
                let img = hf.capturedImage
                let tr = self.trackingName(hf.camera.trackingState)
                self.arQueue.async { self.photoCount += 1 }
                self.ioQueue.async {
                    let name = String(format: "photos/ph_%05d.jpg", n)
                    if let jpg = self.jpeg(img, orientation: hexif) {
                        self.writeFile(d, name, jpg, role: "photo_full_resolution", mime: "image/jpeg", lineage: "ARSession.captureHighResolutionFrame")
                    }
                    self.appendLine(self.kfHandle, [
                        "type": "photo", "keyframe": n, "t_frame_s": hf.timestamp, "utc": self.iso(Date()),
                        "image": ["file": name, "width": Int(hres.width), "height": Int(hres.height), "exif_orientation": hexif],
                        "intrinsics": ["fx": hK[0][0], "fy": hK[1][1], "cx": hK[2][0], "cy": hK[2][1], "for_width": Int(hres.width), "for_height": Int(hres.height)],
                        "camera_to_world": self.colMajor(hp), "tracking": tr,
                        "exposure_s": hf.camera.exposureDuration, "gravity_camera": [hg.x, hg.y, hg.z],
                    ])
                    self.arQueue.async { self.photoBusy = false }
                }
            }
        }
    }

    private func depthStats(_ depth: Data, _ conf: Data) -> [String: Any] {
        var valid = 0, low = 0, med = 0, high = 0
        let n = conf.count
        var hist = [Int](repeating: 0, count: 11)
        depth.withUnsafeBytes { (dp: UnsafeRawBufferPointer) in
            conf.withUnsafeBytes { (cp: UnsafeRawBufferPointer) in
                let df = dp.bindMemory(to: Float.self)
                for i in 0..<min(n, df.count) {
                    let z = df[i]
                    switch cp[i] { case 0: low += 1; case 1: med += 1; default: high += 1 }
                    if z.isFinite && z > 0 {
                        valid += 1
                        hist[min(10, Int(z / 0.5))] += 1
                    }
                }
            }
        }
        depthAgg.valid += valid; depthAgg.total += n; depthAgg.low += low; depthAgg.med += med; depthAgg.high += high; depthAgg.frames += 1
        for i in 0..<11 { rangeHist[i] += hist[i] }
        let s: [String: Any] = ["valid_fraction": n > 0 ? Double(valid) / Double(n) : 0,
                                "confidence_fractions": ["low": Double(low) / Double(max(1, n)), "medium": Double(med) / Double(max(1, n)), "high": Double(high) / Double(max(1, n))],
                                "range_hist_0_5m_bins_0p5": hist]
        arQueue.async { self.lastDepthStats = s }
        return s
    }

    // ------------------------------------------------------------------ fusion (fuseQueue)
    private struct FuseJob {
        let depth: CVPixelBuffer
        let conf: CVPixelBuffer?
        let image: CVPixelBuffer
        let K: simd_float3x3
        let imageW: Int
        let pose: simd_float4x4
    }

    private func runFuse(_ j: FuseJob) {
        guard let g = grid else { return }
        CVPixelBufferLockBaseAddress(j.depth, .readOnly)
        CVPixelBufferLockBaseAddress(j.image, .readOnly)
        if let c = j.conf { CVPixelBufferLockBaseAddress(c, .readOnly) }
        defer {
            CVPixelBufferUnlockBaseAddress(j.depth, .readOnly)
            CVPixelBufferUnlockBaseAddress(j.image, .readOnly)
            if let c = j.conf { CVPixelBufferUnlockBaseAddress(c, .readOnly) }
        }
        let dw = CVPixelBufferGetWidth(j.depth), dh = CVPixelBufferGetHeight(j.depth)
        let dRow = CVPixelBufferGetBytesPerRow(j.depth)
        guard let dBase = CVPixelBufferGetBaseAddress(j.depth) else { return }
        let cBase = j.conf.flatMap { CVPixelBufferGetBaseAddress($0) }
        let cRow = j.conf.map { CVPixelBufferGetBytesPerRow($0) } ?? 0
        guard CVPixelBufferGetPlaneCount(j.image) >= 2,
              let yBase = CVPixelBufferGetBaseAddressOfPlane(j.image, 0),
              let uvBase = CVPixelBufferGetBaseAddressOfPlane(j.image, 1) else { return }
        let yRow = CVPixelBufferGetBytesPerRowOfPlane(j.image, 0)
        let uvRow = CVPixelBufferGetBytesPerRowOfPlane(j.image, 1)
        let iw = CVPixelBufferGetWidthOfPlane(j.image, 0), ih = CVPixelBufferGetHeightOfPlane(j.image, 0)
        let fx = j.K[0][0], fy = j.K[1][1], cx = j.K[2][0], cy = j.K[2][1]
        let s = Float(iw) / Float(dw)
        for jj in 0..<dh {
            let drow = dBase.advanced(by: jj * dRow).assumingMemoryBound(to: Float32.self)
            let crow = cBase?.advanced(by: jj * cRow).assumingMemoryBound(to: UInt8.self)
            for ii in 0..<dw {
                let z = drow[ii]
                if !(z.isFinite) || z < fuse.minRangeM || z > fuse.maxRangeM { continue }
                let c = crow?[ii] ?? 2
                if c < fuse.minConfidence { continue }
                let pc = ScanMath.unproject(i: ii, j: jj, depth: z, dw: dw, iw: iw, fx: fx, fy: fy, cx: cx, cy: cy)
                let pw = ScanMath.transform(j.pose, pc)
                let u = min(iw - 1, max(0, Int((Float(ii) + 0.5) * s)))
                let v = min(ih - 1, max(0, Int((Float(jj) + 0.5) * s)))
                let yv = yBase.advanced(by: v * yRow + u).assumingMemoryBound(to: UInt8.self).pointee
                let uvp = uvBase.advanced(by: (v / 2) * uvRow + (u / 2) * 2).assumingMemoryBound(to: UInt8.self)
                let (r, gg, b) = ScanMath.ycbcrToRGB(y: yv, cb: uvp[0], cr: uvp[1])
                g.add(pw, r: r, g: gg, b: b, confidence: c)
            }
        }
        fusedFrames += 1
    }

    // ------------------------------------------------------------------ mesh
    private func collectMesh() -> (Data, Int, Int, Int)? {
        guard let anchors = session.currentFrame?.anchors else { return nil }
        var latest: [UUID: ARMeshAnchor] = [:]
        for a in anchors { if let m = a as? ARMeshAnchor { latest[m.identifier] = m } }   // one entry per anchor id
        if latest.isEmpty { return nil }
        var verts: [Float] = []
        var faces: [UInt32] = []
        var cls: [UInt8] = []
        var hasCls = false
        for (_, m) in latest {
            let geo = m.geometry
            let base = UInt32(verts.count / 3)
            let vs = geo.vertices
            let vp = vs.buffer.contents()
            for i in 0..<vs.count {
                let p = vp.advanced(by: vs.offset + vs.stride * i).assumingMemoryBound(to: Float.self)
                let w = ScanMath.transform(m.transform, SIMD3<Float>(p[0], p[1], p[2]))
                verts.append(w.x); verts.append(w.y); verts.append(w.z)
            }
            let f = geo.faces
            let fp = f.buffer.contents()
            let c = geo.classification
            if c != nil { hasCls = true }
            for k in 0..<f.count {
                for q in 0..<3 {
                    let off = (k * 3 + q) * f.bytesPerIndex
                    let idx: UInt32 = f.bytesPerIndex == 4 ? fp.advanced(by: off).assumingMemoryBound(to: UInt32.self).pointee
                        : UInt32(fp.advanced(by: off).assumingMemoryBound(to: UInt16.self).pointee)
                    faces.append(base + idx)
                }
                if let c = c {
                    cls.append(c.buffer.contents().advanced(by: c.offset + c.stride * k).assumingMemoryBound(to: UInt8.self).pointee)
                } else { cls.append(0) }
            }
        }
        let nv = verts.count / 3, nf = faces.count / 3
        var h = "ply\nformat binary_little_endian 1.0\n"
        h += "comment Field Scan: ARKit scene reconstruction mesh (DERIVED by ARKit), arkit_session_world, metres, +Y up\n"
        h += "comment classification = ARMeshClassification (0 none,1 wall,2 floor,3 ceiling,4 table,5 seat,6 window,7 door): scene semantics, NOT geology\n"
        h += "comment anchors \(latest.count), each anchor's latest revision only\n"
        h += "element vertex \(nv)\nproperty float x\nproperty float y\nproperty float z\n"
        h += "element face \(nf)\nproperty list uchar uint vertex_indices\n"
        if hasCls { h += "property uchar classification\n" }
        h += "end_header\n"
        var d = Data(h.utf8)
        verts.withUnsafeBytes { d.append(contentsOf: $0) }
        d.reserveCapacity(d.count + nf * (hasCls ? 14 : 13))
        for k in 0..<nf {
            d.append(3)
            var a = faces[k * 3], b = faces[k * 3 + 1], c = faces[k * 3 + 2]
            withUnsafeBytes(of: &a) { d.append(contentsOf: $0) }
            withUnsafeBytes(of: &b) { d.append(contentsOf: $0) }
            withUnsafeBytes(of: &c) { d.append(contentsOf: $0) }
            if hasCls { d.append(cls[k]) }
        }
        return (d, nv, nf, latest.count)
    }

    // ------------------------------------------------------------------ status, cues, helpers
    private func emitStatus(_ frame: ARFrame) {
        let gsize = fuseBusy ? -1 : 0
        _ = gsize
        var pts = 0
        // grid size read without locking: an approximate live count is fine for the HUD
        pts = grid?.size ?? 0
        var meshV = 0
        if meshEnabled { for a in frame.anchors { if let m = a as? ARMeshAnchor { meshV += m.geometry.vertices.count } } }
        let g = ScanMath.gravityInCamera(frame.camera.transform)
        emit([
            "type": "status", "tracking": tracking, "recording": recording, "paused": paused,
            "keyframes": kfCount, "photos": photoCount, "fusedPoints": pts, "meshVertices": meshV,
            "elapsedS": recording && startedT >= 0 ? frame.timestamp - startedT : 0,
            "pathM": travelled, "angularSpeed": angSpeed,
            "blurPx": ScanMath.rotationalBlurPx(angularSpeed: angSpeed, exposure: Float(frame.camera.exposureDuration), fx: frame.camera.intrinsics[0][0]),
            "pitchDeg": ScanMath.pitchDeg(frame.camera.transform), "exif": ScanMath.exifOrientation(gravityCamera: g),
            "depth": lastDepthStats, "thermal": thermalName(), "battery": Double(UIDevice.current.batteryLevel),
            "limitedS": limitedTotal + (limitedSince >= 0 ? frame.timestamp - limitedSince : 0),
        ])
    }

    private func playCue(_ name: String, force: Bool = false) {
        guard cues.sound || force else { return }
        let id: SystemSoundID
        switch name {
        case "start": id = 1113
        case "stop": id = 1114
        case "warn": id = 1073
        default: id = 1104
        }
        AudioServicesPlaySystemSound(id)
    }

    private func say(_ text: String, force: Bool = false) {
        guard (cues.speech || force), !text.isEmpty else { return }
        DispatchQueue.main.async {
            let u = AVSpeechUtterance(string: text)
            u.rate = 0.52
            self.speech.speak(u)
        }
    }

    private func requestLocation() {
        let st = location.authorizationStatus
        if st == .notDetermined { location.requestWhenInUseAuthorization() }
        location.requestLocation()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        if let l = locations.last { lastFix = l; emit(["type": "location", "accuracyM": l.horizontalAccuracy]) }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        emit(["type": "warning", "code": "location", "message": "Location unavailable: \(error.localizedDescription)"])
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways { manager.requestLocation() }
    }

    private func trackingName(_ s: ARCamera.TrackingState) -> String {
        switch s {
        case .normal: return "normal"
        case .notAvailable: return "not_available"
        case .limited(let r):
            switch r {
            case .initializing: return "limited_initializing"
            case .excessiveMotion: return "limited_excessive_motion"
            case .insufficientFeatures: return "limited_insufficient_features"
            case .relocalizing: return "limited_relocalizing"
            @unknown default: return "limited_other"
            }
        }
    }

    private func thermalName() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    func freeMB() -> Int {
        let u = URL(fileURLWithPath: NSHomeDirectory())
        if let v = try? u.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage {
            return Int(v / 1_000_000)
        }
        return -1
    }

    private func colMajor(_ m: simd_float4x4) -> [Float] {
        [m.columns.0.x, m.columns.0.y, m.columns.0.z, m.columns.0.w,
         m.columns.1.x, m.columns.1.y, m.columns.1.z, m.columns.1.w,
         m.columns.2.x, m.columns.2.y, m.columns.2.z, m.columns.2.w,
         m.columns.3.x, m.columns.3.y, m.columns.3.z, m.columns.3.w]
    }

    private let isoFmt: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()

    private func iso(_ d: Date) -> String { isoFmt.string(from: d) }

    private func log(_ event: String, _ extra: [String: Any]) {
        var m = extra
        m["event"] = event
        m["utc"] = iso(Date())
        ioQueue.async { self.appendLine(self.logHandle, m) }
        emit(["type": "log", "event": event])
    }

    // ioQueue only
    private func appendLine(_ h: FileHandle?, _ m: [String: Any]) {
        guard let h = h, let d = try? JSONSerialization.data(withJSONObject: m, options: [.sortedKeys]) else { return }
        h.write(d); h.write(Data([0x0A]))
    }

    private func fileRecord(_ rel: String, _ data: Data, role: String, mime: String, lineage: String) -> [String: Any] {
        let h = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return ["path": rel, "bytes": data.count, "sha256": h, "role": role, "mime": mime, "lineage": lineage]
    }

    // ioQueue only
    private func writeFile(_ d: URL, _ rel: String, _ data: Data, role: String, mime: String, lineage: String) {
        do {
            try data.write(to: d.appendingPathComponent(rel), options: .atomic)
            files.append(fileRecord(rel, data, role: role, mime: mime, lineage: lineage))
        } catch {
            appendLine(logHandle, ["event": "write_failed", "file": rel, "error": error.localizedDescription, "utc": iso(Date())])
            emit(["type": "warning", "code": "write_failed", "message": "Could not save \(rel): \(error.localizedDescription)"])
        }
    }

    private func copyPlane(_ pb: CVPixelBuffer, bytesPerPixel: Int) -> (Data, Int, Int) {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let row = CVPixelBufferGetBytesPerRow(pb)
        var d = Data(count: w * h * bytesPerPixel)
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return (d, w, h) }
        d.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
            for j in 0..<h {
                memcpy(dst.baseAddress!.advanced(by: j * w * bytesPerPixel), base.advanced(by: j * row), w * bytesPerPixel)
            }
        }
        return (d, w, h)
    }

    private func jpeg(_ pb: CVPixelBuffer, orientation: Int) -> Data? {
        let img = CIImage(cvPixelBuffer: pb)
        guard let cg = ci.createCGImage(img, from: img.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        let props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.9, kCGImagePropertyOrientation: orientation]
        CGImageDestinationAddImage(dest, cg, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    // ioQueue only: a 512 px preview from the middle keyframe, orientation applied.
    private func writeThumbnail(_ d: URL) {
        guard kfCount > 0 else { return }
        let mid = max(1, (kfCount + 1) / 2)
        let src = d.appendingPathComponent(String(format: "keyframes/kf_%05d.jpg", mid))
        guard let s = CGImageSourceCreateWithURL(src as CFURL, nil) else { return }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 512,
                                     kCGImageSourceCreateThumbnailWithTransform: true]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(s, 0, opts as CFDictionary) else { return }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        if CGImageDestinationFinalize(dest) {
            writeFile(d, "thumbnail.jpg", out as Data, role: "thumbnail", mime: "image/jpeg", lineage: String(format: "downscaled keyframes/kf_%05d.jpg", mid))
        }
    }
}

// ---------------------------------------------------------------------- camera preview platform view
final class ARPreviewFactory: NSObject, FlutterPlatformViewFactory {
    func create(withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?) -> FlutterPlatformView {
        ARPreview(frame: frame, args: args as? [String: Any] ?? [:])
    }
    func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol { FlutterStandardMessageCodec.sharedInstance() }
}

final class ARPreview: NSObject, FlutterPlatformView, ARSCNViewDelegate {
    private let sceneView: ARSCNView
    private let showMesh: Bool

    init(frame: CGRect, args: [String: Any]) {
        sceneView = ARSCNView(frame: frame)
        showMesh = args["mesh"] as? Bool ?? true
        super.init()
        sceneView.session = FieldScanner.shared.session
        sceneView.automaticallyUpdatesLighting = false
        sceneView.rendersCameraGrain = false
        sceneView.delegate = self
        sceneView.isUserInteractionEnabled = false
        sceneView.backgroundColor = .black      // black, not white, when no camera feed is available
    }

    func view() -> UIView { sceneView }

    func renderer(_ renderer: SCNSceneRenderer, nodeFor anchor: ARAnchor) -> SCNNode? {
        guard showMesh, let m = anchor as? ARMeshAnchor else { return nil }
        let n = SCNNode(geometry: Self.wireframe(m.geometry))
        return n
    }

    func renderer(_ renderer: SCNSceneRenderer, didUpdate node: SCNNode, for anchor: ARAnchor) {
        guard showMesh, let m = anchor as? ARMeshAnchor else { return }
        node.geometry = Self.wireframe(m.geometry)
    }

    static func wireframe(_ g: ARMeshGeometry) -> SCNGeometry {
        let v = g.vertices
        let src = SCNGeometrySource(buffer: v.buffer, vertexFormat: v.format, semantic: .vertex,
                                    vertexCount: v.count, dataOffset: v.offset, dataStride: v.stride)
        let f = g.faces
        let data = Data(bytes: f.buffer.contents(), count: f.count * f.indexCountPerPrimitive * f.bytesPerIndex)
        let el = SCNGeometryElement(data: data, primitiveType: .triangles, primitiveCount: f.count, bytesPerIndex: f.bytesPerIndex)
        let geo = SCNGeometry(sources: [src], elements: [el])
        let mat = SCNMaterial()
        mat.fillMode = .lines
        mat.diffuse.contents = UIColor(red: 0.98, green: 0.62, blue: 0.24, alpha: 0.55)
        mat.isDoubleSided = true
        mat.lightingModel = .constant
        geo.materials = [mat]
        return geo
    }
}
