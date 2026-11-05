import Combine
import Foundation
import Network

@MainActor
final class OpenBikeControlServer: ObservableObject {
    private static let name = "Click Swift Bridge"
    private static let serviceType = "_openbikecontrol._tcp"
    private static let readyPacket = Data([0x02, 0xff, 0x01])

    private struct Client {
        let connection: NWConnection
        var ready = false
        var pendingWrites = 0
    }

    @Published private(set) var status = "Starting…"
    @Published private(set) var connectedClients = 0
    @Published private(set) var running = false

    private var listener: NWListener?
    private var clients: [ObjectIdentifier: Client] = [:]
    private var held: Set<ClickButton> = []

    func start() {
        guard listener == nil else { return }
        do {
            let parameters = NWParameters.tcp
            (parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options)?.noDelay = true
            let listener = try NWListener(using: parameters)
            let defaults = UserDefaults.standard
            let id = defaults.string(forKey: "OpenBikeControlID") ?? UUID().uuidString.lowercased()
            defaults.set(id, forKey: "OpenBikeControlID")
            listener.service = NWListener.Service(
                name: Self.name, type: Self.serviceType, txtRecord: NWTXTRecord([
                    "version": "1",
                    "id": id,
                    "name": Self.name,
                    "service-uuids": "d273f680-d548-419d-b9d1-fa0472345229",
                    "manufacturer": "Click Bridge",
                    "model": "Click-OBC-Bridge",
                ])
            )
            // Listener and client callbacks are delivered on the main queue.
            listener.newConnectionHandler = { [weak self, weak listener] connection in
                MainActor.assumeIsolated {
                    guard let self, let listener, self.listener === listener else {
                        connection.cancel()
                        return
                    }
                    self.accept(connection)
                }
            }
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                MainActor.assumeIsolated {
                    guard let self, let listener, self.listener === listener else { return }
                    switch state {
                    case .waiting(let error):
                        self.status = "OpenBikeControl waiting: \(error.localizedDescription)"
                    case .failed(let error):
                        self.stop()
                        self.status = "OpenBikeControl failed: \(error.localizedDescription)"
                    default:
                        break
                    }
                }
            }
            listener.serviceRegistrationUpdateHandler = { [weak self, weak listener] change in
                MainActor.assumeIsolated {
                    guard let self, let listener, self.listener === listener else { return }
                    switch change {
                    case .add:
                        self.status = "Waiting to connect"
                    case .remove:
                        self.status = "Looking for MyWhoosh…"
                    @unknown default:
                        break
                    }
                }
            }
            self.listener = listener
            running = true
            self.status = "Looking for MyWhoosh…"
            listener.start(queue: .main)
        } catch {
            self.status = "OpenBikeControl failed: \(error.localizedDescription)"
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        for client in clients.values { client.connection.cancel() }
        clients.removeAll()
        held.removeAll()
        connectedClients = 0
        running = false
    }

    func send(_ button: ClickButton, down: Bool) {
        if down {
            held.insert(button)
        } else {
            held.remove(button)
        }
        broadcast(Self.packet(button, down: down))
    }

    func releaseAll() {
        for button in ClickButton.allCases where held.contains(button) {
            broadcast(Self.packet(button, down: false))
        }
        held.removeAll()
    }

    nonisolated static func packet(_ button: ClickButton, down: Bool) -> Data {
        let action: UInt8 = switch button {
        case .b: 0x01
        case .plus: 0x02
        case .z: 0x18
        case .a: 0x19
        }
        return Data([0x01, action, down ? 0x01 : 0x00])
    }

    private func accept(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        clients[id] = Client(connection: connection)
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self, let client = self.clients[id] else { return }
                switch state {
                case .ready where !client.ready:
                    self.clients[id]?.ready = true
                    self.connectedClients += 1
                    self.send(Self.readyPacket, to: id)
                    self.receive(client.connection)
                case .failed, .cancelled:
                    self.remove(id)
                default:
                    break
                }
            }
        }
        connection.start(queue: .main)
    }

    private func receive(_ connection: NWConnection) {
        // The bridge has no haptic output; drain inbound data and watch for EOF.
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self, weak connection] _, _, done, error in
            MainActor.assumeIsolated {
                guard let self, let connection else { return }
                let id = ObjectIdentifier(connection)
                guard self.clients[id] != nil else { return }
                if done || error != nil {
                    self.remove(id)
                } else {
                    self.receive(connection)
                }
            }
        }
    }

    private func broadcast(_ packet: Data) {
        for (id, client) in clients where client.ready {
            send(packet, to: id)
        }
    }

    private func send(_ packet: Data, to id: ObjectIdentifier) {
        guard let client = clients[id] else { return }
        guard client.pendingWrites < 32 else {
            self.remove(id)
            return
        }
        self.clients[id]?.pendingWrites += 1
        client.connection.send(content: packet, completion: .contentProcessed { [weak self, weak connection = client.connection] error in
            MainActor.assumeIsolated {
                guard let self, connection != nil else { return }
                if error != nil {
                    self.remove(id)
                } else {
                    self.clients[id]?.pendingWrites -= 1
                }
            }
        })
    }

    private func remove(_ id: ObjectIdentifier) {
        guard let client = clients.removeValue(forKey: id) else { return }
        if client.ready { connectedClients -= 1 }
        client.connection.cancel()
    }
}
