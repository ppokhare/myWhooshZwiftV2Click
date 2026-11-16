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

    private static let firmwareUUID = CBUUID(string: "2A26")
    private let keepAwakeOptIn = CommandLine.arguments.contains("--experimental-right-keep-awake")
    private var keepAwake = ClickKeepAwake()
    private var keepAwakeTask: Task<Void, Never>?
    private var keepAwakeTimeout: Task<Void, Never>?
    private var keepAwakeCharacteristics: [ClickKeepAwake.Channel: CBCharacteristic] = [:]
    private var firmware: Data?
    private var rightPod = false
    private var keepAwakeSubscribed = false

    private let log = ClickLog()
    private let testRideOnResponse = CommandLine.arguments.contains("--ride-on-with-response")

    enum KeepAwakeStatus: String {
        case waitingForPod = "Waiting for pod"
        case checkingPod = "Checking pod"
        case waitingForWrite = "Waiting for Bluetooth write"
        case active = "Active"
        case unavailable = "Unavailable until reconnect"
        case disabled = "Disabled · Restart to retry"
    }

    @Published private(set) var status = "Starting Bluetooth…"
    @Published private(set) var ready = false
    @Published private(set) var keepAwakeStatus: KeepAwakeStatus?

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
        log.info("Experimental right keep-awake requested: \(self.keepAwakeOptIn); firmware-update writes have unknown flash effects")
        if keepAwakeOptIn { keepAwakeStatus = .waitingForPod }
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
        ackPending = false
        if keepAwake.inFlight { disableKeepAwake("connection ended at stage \(keepAwake.state)") }
        keepAwake.cancelStart()
        if keepAwakeOptIn, keepAwake.state != .disabled { keepAwakeStatus = .waitingForPod }
        keepAwakeTask?.cancel()
        keepAwakeTask = nil
        keepAwakeTimeout?.cancel()
        keepAwakeTimeout = nil
        keepAwakeCharacteristics.removeAll()
        firmware = nil
        rightPod = false
        keepAwakeSubscribed = false
        ready = false
        maintenance?.cancel()
        maintenance = nil
        deadline?.cancel()
        deadline = nil
        writeCharacteristic = nil
        pendingSubscriptions.removeAll()
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
            if let self, keepAwakeOptIn, keepAwake.state != .disabled {
                keepAwakeStatus = .checkingPod
                armKeepAwakeTimeout(after: .seconds(5)) { connection in
                    let reason = connection.firmware == nil ? "firmware revision unavailable" : "missing update characteristic"
                    connection.disableKeepAwake(reason)
                }
                prepareKeepAwake()
            }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled, let self else { return }
                guard !keepAwake.blocksOrdinaryWrites else { continue }
                if let lastAck, lastAck.duration(to: .now) >= .seconds(15) {
                    log.info("Maintenance tick: protocol ACK instead of RideOn")
                    acknowledge()
                } else {
                    _ = write(Self.rideOn)
                }
            }
        }
    }

    private func disableKeepAwake(_ reason: String) {
        guard keepAwakeStatus != .disabled else { return }
        keepAwake.disable()
        keepAwakeTask?.cancel()
        keepAwakeTimeout?.cancel()
        keepAwakeStatus = .disabled
        log.error("Experimental keep-awake disabled until app restart: \(reason)")
        if ackPending { acknowledge() }
    }

    private func prepareKeepAwake() {
        guard keepAwakeOptIn, keepAwake.state != .disabled, ready,
              let firmware, let pod else { return }
        guard ClickKeepAwake.eligible(optIn: keepAwakeOptIn, rightPod: rightPod, firmware: firmware) else {
            disableKeepAwake("requires right pod firmware exactly 1.2.0")
            return
        }
        guard keepAwakeCharacteristics.count == 2 else { return }
        if !keepAwakeSubscribed {
            keepAwakeSubscribed = true
            armKeepAwakeTimeout(after: .seconds(5)) {
                $0.disableKeepAwake("notification subscription timed out")
            }
            for characteristic in keepAwakeCharacteristics.values {
                pod.setNotifyValue(true, for: characteristic)
            }
            return
        }
        guard keepAwakeCharacteristics.values.allSatisfy({ $0.isNotifying }),
              keepAwakeTask == nil else { return }
        keepAwakeTimeout?.cancel()
        keepAwakeTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, keepAwake.state == .idle else { return }
                let nextCycle = ContinuousClock.now + .seconds(55)
                keepAwake.requestStart()
                startKeepAwake()
                try? await Task.sleep(until: nextCycle, clock: .continuous)
            }
        }
    }

    private func armKeepAwakeTimeout(after delay: Duration, _ onTimeout: @escaping (ClickConnection) -> Void) {
        keepAwakeTimeout?.cancel()
        keepAwakeTimeout = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            onTimeout(self)
        }
    }

    private func startKeepAwake() {
        guard keepAwake.state == .waitingForCapacity,
              let (pod, characteristic) = keepAwakeTarget(.control) else { return }
        guard let command = keepAwake.begin(canSend: pod.canSendWriteWithoutResponse) else {
            guard keepAwakeStatus != .waitingForWrite else { return }
            keepAwakeStatus = .waitingForWrite
            log.info("Experimental keep-awake deferred: write backpressure before opening command")
            armKeepAwakeTimeout(after: .seconds(2)) {
                $0.cancelKeepAwakeStart("write backpressure exceeded two seconds")
            }
            return
        }
        submitKeepAwake(command, to: pod, characteristic: characteristic)
    }

    private func cancelKeepAwakeStart(_ reason: String) {
        keepAwake.cancelStart()
        keepAwakeTask?.cancel()
        keepAwakeTimeout?.cancel()
        keepAwakeStatus = .unavailable
        log.error("Experimental keep-awake unavailable until reconnect: \(reason) before opening command")
        if ackPending { acknowledge() }
    }

    private func keepAwakeTarget(_ channel: ClickKeepAwake.Channel) -> (CBPeripheral, CBCharacteristic)? {
        let stage = keepAwake.state
        guard let pod, pod.state == .connected else {
            if keepAwake.inFlight {
                disableKeepAwake("disconnected at stage \(stage)")
            } else {
                cancelKeepAwakeStart("disconnected")
            }
            return nil
        }
        guard let characteristic = keepAwakeCharacteristics[channel], keepAwakeCharacteristics.count == 2 else {
            disableKeepAwake("missing update characteristic for \(channel) at stage \(stage)")
            return nil
        }
        guard keepAwakeCharacteristics.values.allSatisfy({ $0.isNotifying }) else {
            disableKeepAwake("lost update notifications at stage \(stage)")
            return nil
        }
        return (pod, characteristic)
    }

    private func sendKeepAwake(_ command: ClickKeepAwake.Write) {
        guard let (pod, characteristic) = keepAwakeTarget(command.channel) else { return }
        guard pod.canSendWriteWithoutResponse else {
            disableKeepAwake("write backpressure at stage \(keepAwake.state)")
            return
        }
        submitKeepAwake(command, to: pod, characteristic: characteristic)
    }

    private func submitKeepAwake(_ command: ClickKeepAwake.Write, to pod: CBPeripheral, characteristic: CBCharacteristic) {
        armKeepAwakeTimeout(after: .seconds(5)) {
            $0.disableKeepAwake("reply timed out at stage \($0.keepAwake.state)")
        }
        pod.writeValue(command.bytes, for: characteristic, type: .withoutResponse)
        log.info("Experimental keep-awake write: \(command.channel.rawValue), \(command.bytes as NSData)")
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
        ackPending = keepAwake.blocksOrdinaryWrites || !write(Self.ack)
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
        rightPod = true // The manufacturer-role guard above accepts only the right Click V2.
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
            var requested = [Self.asyncRX, Self.syncRX, Self.syncTX]
            if keepAwakeOptIn {
                requested += [Self.firmwareUUID, CBUUID(string: ClickKeepAwake.Channel.data.rawValue),
                              CBUUID(string: ClickKeepAwake.Channel.control.rawValue)]
            }
            peripheral.discoverCharacteristics(requested, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard peripheral === pod, deadline != nil, error == nil,
              let characteristics = service.characteristics else { return }
        if keepAwakeOptIn, keepAwake.state != .disabled {
            for characteristic in characteristics {
                if characteristic.uuid == Self.firmwareUUID, service.uuid == CBUUID(string: "180A"),
                   characteristic.properties.contains(.read) {
                    peripheral.readValue(for: characteristic)
                }
                for channel in [ClickKeepAwake.Channel.data, .control]
                where characteristic.uuid == CBUUID(string: channel.rawValue) && service.uuid == CBUUID(string: "FC82") {
                    guard characteristic.properties.contains([.notify, .writeWithoutResponse]) else {
                        disableKeepAwake("unsupported GATT properties")
                        continue
                    }
                    keepAwakeCharacteristics[channel] = characteristic
                }
            }
            prepareKeepAwake()
        }
        guard
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
        guard peripheral === pod else { return }
        if keepAwakeCharacteristics.values.contains(where: { $0 === characteristic }) {
            if error != nil || !characteristic.isNotifying {
                disableKeepAwake("notification subscription failed or lost on \(characteristic.uuid) at stage \(keepAwake.state)")
            } else { prepareKeepAwake() }
            return
        }
        guard pendingSubscriptions.remove(characteristic.uuid) != nil else { return }
        if characteristic.uuid == Self.asyncRX, error != nil || !characteristic.isNotifying {
            endSession()
        } else {
            handshake()
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === pod else { return }
        if keepAwakeOptIn, characteristic.uuid == Self.firmwareUUID {
            guard error == nil, let value = characteristic.value else {
                disableKeepAwake("firmware read failed")
                return
            }
            firmware = value
            prepareKeepAwake()
            return
        }
        if let channel = keepAwakeCharacteristics.first(where: { $0.value === characteristic })?.key {
            guard keepAwake.state != .disabled else { return }
            guard error == nil, let value = characteristic.value else {
                disableKeepAwake("reply read failed on \(channel) at stage \(keepAwake.state)")
                return
            }
            let stage = keepAwake.state
            let command = keepAwake.receive(value, on: channel)
            if keepAwake.state == .disabled {
                disableKeepAwake("unexpected reply on \(channel) at stage \(stage)")
            } else if let command {
                sendKeepAwake(command)
            } else {
                keepAwakeTimeout?.cancel()
                if keepAwakeStatus != .active { keepAwakeStatus = .active }
                log.info("Experimental keep-awake sequence completed")
                if ackPending { acknowledge() }
            }
            return
        }
        guard writeCharacteristic != nil, error == nil,
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
        guard peripheral === pod else { return }
        startKeepAwake()
        if ackPending, !keepAwake.blocksOrdinaryWrites { acknowledge() }
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
