import Cocoa
import CoreBluetooth
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var ble: BlePeripheral?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)
    RegisterGeneratedPlugins(registry: flutterViewController)
    ble = BlePeripheral(messenger: flutterViewController.engine.binaryMessenger)

    super.awakeFromNib()

    // The nib's default frame is 800x600; open at a usable size (fits a 13" MacBook Air) and centre it.
    self.minSize = NSSize(width: 1100, height: 720)
    let visible = self.screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    let size = NSSize(width: min(1440, visible.width), height: min(900, visible.height))
    self.setFrame(NSRect(origin: .zero, size: size), display: true)
    self.center()
    self.title = "Field Station"
  }
}

/// Desktop side of the phone <-> desktop BLE link (contracts/BLE_PROTOCOL_V1.md).
///
/// This is a dumb radio: it advertises the service, serves the `info` characteristic,
/// passes every `rx` write to Dart unchanged, and sends `tx` notifications that Dart asks for.
/// Framing, pairing proofs, MACs and commands live in the Python service (fieldstation/protocol.py).
final class BlePeripheral: NSObject, CBPeripheralManagerDelegate, FlutterStreamHandler {
  static let serviceUUID = CBUUID(string: "2ED62242-2267-41EC-BA7D-A321B67A1B8A")
  static let infoUUID = CBUUID(string: "9BC2CC53-AFB3-4C24-AEBC-912AF3962D9B")
  static let rxUUID = CBUUID(string: "2C4DE982-D089-429A-9945-5FF10A4935A3")
  static let txUUID = CBUUID(string: "00A3B417-650E-4ABE-8F9C-5332D2E0A07A")

  private let methods: FlutterMethodChannel
  private let eventsChannel: FlutterEventChannel
  private var sink: FlutterEventSink?
  private var manager: CBPeripheralManager?
  private var txChar: CBMutableCharacteristic?
  private var serviceAdded = false
  private var wantAdvertising = false
  private var localName = "Field Station"
  private var info = Data("{}".utf8)
  private var centrals: [UUID: CBCentral] = [:]
  private var pending: [(CBCentral, Data)] = []   // notifications waiting for peripheralManagerIsReady

  init(messenger: FlutterBinaryMessenger) {
    methods = FlutterMethodChannel(name: "fieldstation/ble", binaryMessenger: messenger)
    eventsChannel = FlutterEventChannel(name: "fieldstation/ble/events", binaryMessenger: messenger)
    super.init()
    eventsChannel.setStreamHandler(self)
    methods.setMethodCallHandler { [weak self] call, result in self?.handle(call, result) }
  }

  // MARK: Flutter

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    sink = events
    emitState()
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    sink = nil
    return nil
  }

  private func emit(_ m: [String: Any]) {
    DispatchQueue.main.async { self.sink?(m) }
  }

  private func stateName() -> String {
    guard let m = manager else { return "unknown" }
    switch m.state {
    case .poweredOn: return "poweredOn"
    case .poweredOff: return "poweredOff"
    case .unauthorized: return "unauthorized"
    case .unsupported: return "unsupported"
    case .resetting: return "resetting"
    default: return "unknown"
    }
  }

  private func emitState() {
    emit(["type": "state", "bluetooth": stateName(), "advertising": manager?.isAdvertising ?? false])
  }

  private func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "start":
      if let b = args["info_b64"] as? String, let d = Data(base64Encoded: b) { info = d }
      if let n = args["local_name"] as? String, !n.isEmpty { localName = String(n.prefix(28)) }
      wantAdvertising = true
      if manager == nil {
        // Creating the manager triggers the macOS Bluetooth permission prompt the first time.
        manager = CBPeripheralManager(delegate: self, queue: nil)
      } else {
        setUpAndAdvertise()
      }
      result(true)
    case "stop":
      wantAdvertising = false
      manager?.stopAdvertising()
      emitState()
      result(true)
    case "setInfo":
      if let b = args["info_b64"] as? String, let d = Data(base64Encoded: b) { info = d }
      result(true)
    case "notify":
      guard let cid = args["central"] as? String, let uuid = UUID(uuidString: cid), let central = centrals[uuid],
            let b = args["data_b64"] as? String, let data = Data(base64Encoded: b) else {
        result(false)
        return
      }
      pending.append((central, data))
      flush()
      result(true)
    case "state":
      result(["bluetooth": stateName(), "advertising": manager?.isAdvertising ?? false,
              "centrals": centrals.keys.map { $0.uuidString }])
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: CoreBluetooth

  private func setUpAndAdvertise() {
    guard let m = manager, m.state == .poweredOn else { return }
    if !serviceAdded {
      let infoC = CBMutableCharacteristic(type: Self.infoUUID, properties: [.read], value: nil, permissions: [.readable])
      let rxC = CBMutableCharacteristic(type: Self.rxUUID, properties: [.write], value: nil, permissions: [.writeable])
      let txC = CBMutableCharacteristic(type: Self.txUUID, properties: [.notify], value: nil, permissions: [.readable])
      let svc = CBMutableService(type: Self.serviceUUID, primary: true)
      svc.characteristics = [infoC, rxC, txC]
      txChar = txC
      m.add(svc)
      return  // advertise after didAdd
    }
    if wantAdvertising && !m.isAdvertising {
      m.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [Self.serviceUUID],
                          CBAdvertisementDataLocalNameKey: localName])
    }
  }

  func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
    if peripheral.state == .poweredOn {
      setUpAndAdvertise()
    } else {
      serviceAdded = false
      centrals.removeAll()
      pending.removeAll()
    }
    emitState()
  }

  func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
    if let e = error {
      emit(["type": "error", "message": "add service failed: \(e.localizedDescription)"])
      return
    }
    serviceAdded = true
    setUpAndAdvertise()
  }

  func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
    if let e = error { emit(["type": "error", "message": "advertising failed: \(e.localizedDescription)"]) }
    emitState()
  }

  func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
    guard request.characteristic.uuid == Self.infoUUID else {
      peripheral.respond(to: request, withResult: .requestNotSupported)
      return
    }
    if request.offset > info.count {
      peripheral.respond(to: request, withResult: .invalidOffset)
      return
    }
    request.value = info.subdata(in: request.offset..<info.count)
    peripheral.respond(to: request, withResult: .success)
  }

  func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
    for r in requests where r.characteristic.uuid != Self.rxUUID {
      peripheral.respond(to: r, withResult: .requestNotSupported)
      return
    }
    for r in requests {
      centrals[r.central.identifier] = r.central
      if let v = r.value {
        emit(["type": "rx", "central": r.central.identifier.uuidString, "data_b64": v.base64EncodedString(),
              "max_chunk": r.central.maximumUpdateValueLength])
      }
    }
    if let first = requests.first { peripheral.respond(to: first, withResult: .success) }
  }

  func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
    centrals[central.identifier] = central
    emit(["type": "subscribed", "central": central.identifier.uuidString, "max_chunk": central.maximumUpdateValueLength])
  }

  func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
    centrals.removeValue(forKey: central.identifier)
    emit(["type": "unsubscribed", "central": central.identifier.uuidString])
  }

  func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
    flush()
  }

  private func flush() {
    guard let m = manager, let tx = txChar else { return }
    while let (central, data) = pending.first {
      if !m.updateValue(data, for: tx, onSubscribedCentrals: [central]) { return }  // queue full; resume when ready
      pending.removeFirst()
    }
  }
}
