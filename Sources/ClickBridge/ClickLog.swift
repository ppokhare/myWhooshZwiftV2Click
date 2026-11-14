import Darwin
import Foundation
import OSLog

@MainActor
final class ClickLog {
    private let logger = Logger(subsystem: "ClickBridge", category: "Bluetooth")
    private let timestamp = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private var file: FileHandle?

    init() {
        guard let path = Bundle.main.object(forInfoDictionaryKey: "ClickBridgeLogPath") as? String else { return }
        let descriptor = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        guard descriptor >= 0 else {
            logger.error("Could not open ride log at \(path, privacy: .public); errno \(errno)")
            return
        }
        file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
        append(message)
    }

    func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        append("ERROR \(message)")
    }

    private func append(_ message: String) {
        guard let file else { return }
        let line = "\(Date().formatted(timestamp)) [\(ProcessInfo.processInfo.processIdentifier)] \(message)\n"
        do {
            try file.write(contentsOf: Data(line.utf8))
        } catch {
            logger.error("Could not write ride log: \(String(describing: error), privacy: .public)")
            self.file = nil
        }
    }
}
