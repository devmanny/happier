import Foundation
import Network

/// Whether this device has a usable network path. The store only words its offline notice with it
/// ("no network" or "the server doesn't answer"); whether the relay is reached is `connection`'s.
public protocol NetworkPathMonitor: AnyObject, Sendable {
    func start(_ onChange: @escaping @Sendable (_ satisfied: Bool) -> Void)
    func cancel()
}

/// The system's path monitor.
public final class SystemNetworkPathMonitor: NetworkPathMonitor {
    private let monitor = NWPathMonitor()

    public init() {}

    public func start(_ onChange: @escaping @Sendable (_ satisfied: Bool) -> Void) {
        monitor.pathUpdateHandler = { path in onChange(path.status == .satisfied) }
        monitor.start(queue: DispatchQueue(label: "dev.happier.network-path"))
    }

    public func cancel() { monitor.cancel() }
}
