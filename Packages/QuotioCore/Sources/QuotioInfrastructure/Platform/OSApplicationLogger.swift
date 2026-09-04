import OSLog
import QuotioApplication

public struct OSApplicationLogger: ApplicationLogging {
    private let logger: Logger

    public init(subsystem: String, category: String) {
        logger = Logger(subsystem: subsystem, category: category)
    }

    public func write(_ level: ApplicationLogLevel, message: String) {
        switch level {
        case .debug:
            logger.debug("\(message, privacy: .public)")
        case .info:
            logger.info("\(message, privacy: .public)")
        case .warning:
            logger.warning("\(message, privacy: .public)")
        case .error:
            logger.error("\(message, privacy: .public)")
        }
    }
}
