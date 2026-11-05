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
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func stop() {
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

    private func retry(_ peripheral: CBPeripheral) {
        guard peripheral === pod else { return }
        resetSession()
        pod = nil
        guard central != nil else { return }

        status = "Reconnecting…"
        reconnect?.cancel()
        reconnect = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.scan()
        }
    }

    private func handshake() {
        guard !sessionStarted, pendingSubscriptions.isEmpty, writeCharacteristic != nil else { return }
        sessionStarted = true
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
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled, let self else { return }
                if let lastAck, lastAck.duration(to: .now) >= .seconds(15) {
                    acknowledge()
                } else {
                    _ = write(Self.rideOn)
                }
            }
        }
    }

    private func write(_ data: Data) -> Bool {
        guard let pod, pod.state == .connected, let characteristic = writeCharacteristic else { return false }
        if characteristic.properties.contains(.writeWithoutResponse) {
            guard pod.canSendWriteWithoutResponse else { return false }
            pod.writeValue(data, for: characteristic, type: .withoutResponse)
        } else {
            pod.writeValue(data, for: characteristic, type: .withResponse)
        }
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
        central.connect(peripheral)
        deadline = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled, let self else { return }
            status = "Connection timed out · Retrying"
            endSession()
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard peripheral === pod, deadline != nil else {
            central.cancelPeripheralConnection(peripheral)
            return
        }
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        retry(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        retry(peripheral)
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
        guard peripheral === pod, sessionStarted, error == nil, let frame = characteristic.value else { return }
        if characteristic.uuid == Self.asyncRX {
            if frame.starts(with: [0xff, 0x03]) {
                acknowledge()
            } else {
                for (button, down) in buttons.update(frame) {
                    onButton?(button, down)
                }
            }
        } else if characteristic.uuid == Self.syncTX, frame.starts(with: Self.rideOn) {
            acknowledge()
        }
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        if peripheral === pod, ackPending { acknowledge() }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if peripheral === pod, characteristic === writeCharacteristic, error != nil {
            endSession()
        }
    }
}
