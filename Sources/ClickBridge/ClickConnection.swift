import Combine
import CoreBluetooth
import Foundation

@MainActor
final class ClickConnection: NSObject, ObservableObject {
    private static let asyncRX = CBUUID(string: "00000002-19ca-4651-86e5-fa29dcdd09d1")
    private static let syncRX = CBUUID(string: "00000003-19ca-4651-86e5-fa29dcdd09d1")
    private static let syncTX = CBUUID(string: "00000004-19ca-4651-86e5-fa29dcdd09d1")
    private static let rideOn = Data("RideOn".utf8)
    private static let ack = Data([0xff, 0x04, 0x00])

    private let log = ClickLog()
    private let testRideOnResponse = CommandLine.arguments.contains("--ride-on-with-response")

    @Published private(set) var status = "Starting Bluetooth…"
    @Published private(set) var ready = false

    var onButton: ((ClickButton, Bool) -> Void)?
    var onReset: (() -> Void)?

    private var central: CBCentralManager?
    private var pod: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var buttons = ClickButtons()
    private var maintenance: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var reconnect: Task<Void, Never>?
    private var pendingSubscriptions: Set<CBUUID> = []
    private var ackPending = false
    private var lastAck: ContinuousClock.Instant?
    private var sessionStarted = false

    func start() {
        log.info("Starting bridge; requested RideOn response test: \(self.testRideOnResponse)")
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func stop() {
        log.info("Stopping bridge")
        if let central, central.isScanning { central.stopScan() }
        reconnect?.cancel()
        endSession()
        central?.delegate = nil
        central = nil
    }

    private func scan() {
        guard let central, pod == nil else { return }
        switch central.state {
        case .poweredOn:
            status = "Press a button to wake it"
            if !central.isScanning {
                log.info("Scanning for right pod")
                central.scanForPeripherals(withServices: nil)
            }
        case .poweredOff: status = "Bluetooth is off"
        case .unauthorized: status = "Allow Bluetooth in System Settings"
        case .unsupported: status = "Bluetooth is unavailable"
        default: status = "Waiting for Bluetooth…"
        }
    }

    private func resetSession() {
        ready = false
        maintenance?.cancel()
        maintenance = nil
        deadline?.cancel()
        deadline = nil
        writeCharacteristic = nil
        pendingSubscriptions.removeAll()
        ackPending = false
        lastAck = nil
        sessionStarted = false
        buttons = ClickButtons()
        onReset?()
    }

    private func endSession() {
        resetSession()
        if let central, central.state == .poweredOn, let pod {
            central.cancelPeripheralConnection(pod)
        }
    }

    private func retry(_ peripheral: CBPeripheral, after delay: Duration) {
        guard peripheral === pod else { return }
        resetSession()
        pod = nil
        guard central != nil else { return }

        status = "Reconnecting…"
        reconnect?.cancel()
        guard delay > .zero else {
            scan()
            return
        }
        reconnect = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.scan()
        }
    }

    private func handshake() {
        guard !sessionStarted, pendingSubscriptions.isEmpty, writeCharacteristic != nil else { return }
        sessionStarted = true
        log.info("Starting handshake")
        maintenance = Task { [weak self] in
            let setup = [Self.rideOn + Data([0x02, 0x03]), Data([0x00, 0x08, 0x00]), Data([0x00, 0x08, 0x10])]
            for message in setup {
                guard !Task.isCancelled else { return }
                while self?.write(message) == false {
                    try? await Task.sleep(for: .milliseconds(100))
                    guard !Task.isCancelled else { return }
                }
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { return }
            }
            self?.deadline?.cancel()
            self?.ready = true
            self?.status = "Connected"
            self?.log.info("Bridge ready for buttons")
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled, let self else { return }
                if let lastAck, lastAck.duration(to: .now) >= .seconds(15) {
                    log.info("Maintenance tick: protocol ACK instead of RideOn")
                    acknowledge()
                } else {
                    _ = write(Self.rideOn)
                }
            }
        }
    }

    private func write(_ data: Data) -> Bool {
        let isRideOn = data == Self.rideOn
        guard let pod, pod.state == .connected, let characteristic = writeCharacteristic else {
            if isRideOn { log.info("RideOn skipped: write characteristic or connection unavailable") }
            return false
        }
        let supportsCommand = characteristic.properties.contains(.writeWithoutResponse)
        let supportsRequest = characteristic.properties.contains(.write)
        let useResponse = !supportsCommand || (isRideOn && testRideOnResponse && supportsRequest)
        if !useResponse, !pod.canSendWriteWithoutResponse {
            if isRideOn { log.info("RideOn skipped: write without response backpressure") }
            return false
        }
        if isRideOn { log.info("RideOn submitted; with response: \(useResponse)") }
        pod.writeValue(data, for: characteristic, type: useResponse ? .withResponse : .withoutResponse)
        return true
    }

    private func acknowledge() {
        ackPending = !write(Self.ack)
        if !ackPending { lastAck = .now }
    }
}

extension ClickConnection: @preconcurrency CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state != .poweredOn {
            resetSession()
            pod = nil
        }
        scan()
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        // Manufacturer payload includes the little-endian Zwift company ID and pod role.
        guard pod == nil,
              let manufacturer = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
              manufacturer.starts(with: [0x4a, 0x09, 0x0a]) else { return }

        central.stopScan()
        pod = peripheral
        peripheral.delegate = self
        status = "Connecting…"
        log.info("Right pod advertised; connecting")
        central.connect(peripheral)
        deadline = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled, let self else { return }
            log.error("Handshake deadline expired; closing connection")
            status = "Connection timed out · Retrying"
            endSession()
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard peripheral === pod, deadline != nil else {
            central.cancelPeripheralConnection(peripheral)
            return
        }
        log.info("BLE connected; discovering services")
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        if peripheral === pod {
            log.error("BLE connection failed: \(String(describing: error))")
        }
        retry(peripheral, after: .seconds(2))
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        if peripheral === pod {
            log.info("BLE disconnected: \(String(describing: error))")
        }
        retry(peripheral, after: .zero)
    }
}

extension ClickConnection: @preconcurrency CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard peripheral === pod, deadline != nil else { return }
        guard error == nil, let services = peripheral.services, !services.isEmpty else {
            endSession()
            return
        }
        for service in services {
            peripheral.discoverCharacteristics([Self.asyncRX, Self.syncRX, Self.syncTX], for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard peripheral === pod, deadline != nil, error == nil,
              let characteristics = service.characteristics,
              let notifications = characteristics.first(where: { $0.uuid == Self.asyncRX }),
              let writes = characteristics.first(where: { $0.uuid == Self.syncRX }),
              writes.properties.contains(.writeWithoutResponse) || writes.properties.contains(.write),
              writeCharacteristic == nil else { return }

        writeCharacteristic = writes
        log.info("Write modes supported: with response \(writes.properties.contains(.write)), without response \(writes.properties.contains(.writeWithoutResponse))")
        let subscriptions = characteristics.filter { $0 === notifications || $0.uuid == Self.syncTX }
        pendingSubscriptions = Set(subscriptions.map(\.uuid))
        for characteristic in subscriptions {
            peripheral.setNotifyValue(true, for: characteristic)
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard peripheral === pod, pendingSubscriptions.remove(characteristic.uuid) != nil else { return }
        if characteristic.uuid == Self.asyncRX, error != nil || !characteristic.isNotifying {
            endSession()
        } else {
            handshake()
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === pod, writeCharacteristic != nil, error == nil,
              let frame = characteristic.value else { return }
        if characteristic.uuid == Self.asyncRX {
            if sessionStarted, frame.starts(with: [0xff, 0x03]) {
                acknowledge()
            } else {
                for (button, down) in buttons.update(frame) {
                    log.info("Button \(String(describing: button)); down: \(down)")
                    onButton?(button, down)
                }
            }
        } else if sessionStarted, characteristic.uuid == Self.syncTX, frame.starts(with: Self.rideOn) {
            acknowledge()
        }
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        if peripheral === pod, ackPending { acknowledge() }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === pod, characteristic === writeCharacteristic else { return }
        // With both modes supported, only the experimental RideOn requests a response.
        let writeName = characteristic.properties.contains(.writeWithoutResponse) ? "RideOn" : "Characteristic"
        if let error {
            log.error("\(writeName) write failed; closing connection: \(String(describing: error))")
            endSession()
        } else {
            log.info("\(writeName) write acknowledged")
        }
    }
}
