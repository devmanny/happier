import HappierKit
import MetricKit
#if os(iOS)
import UIKit
#endif

/// Hands every MetricKit report the system delivers (crashes, hangs, daily metrics) to the store,
/// which saves it in the account for `happier diagnostics pull`. MetricKit needs no entitlement; it
/// delivers at most about once a day, and diagnostics again on the next launch after a crash.
final class MetricKitReports: NSObject, MXMetricManagerSubscriber {
    private let store: HappierStore

    init(store: HappierStore) {
        self.store = store
        super.init()
        MXMetricManager.shared.add(self)
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        save(payloads.map { $0.jsonRepresentation() }, kind: .metric)
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        save(payloads.map { $0.jsonRepresentation() }, kind: .diagnostic)
    }

    private func save(_ reports: [Data], kind: DeviceDiagnostic.Kind) {
        let store = store
        Task { @MainActor in
            // Delivered right after launch, possibly before a window restored the account.
            store.restore()
            let origin = Self.origin()
            for report in reports { await store.saveDeviceDiagnostic(report, kind: kind, origin: origin) }
        }
    }

    @MainActor private static func origin() -> DeviceDiagnostic.Origin {
        let info = Bundle.main.infoDictionary
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let osVersion = "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        #if os(iOS)
        let os = "\(UIDevice.current.systemName) \(osVersion)"
        #else
        let os = "macOS \(osVersion)"
        #endif
        return DeviceDiagnostic.Origin(model: hardwareModel(), os: os,
                                       appVersion: info?["CFBundleShortVersionString"] as? String ?? "",
                                       build: info?["CFBundleVersion"] as? String ?? "")
    }

    /// The hardware identifier, e.g. `iPhone17,1` or `Mac16,10`.
    private static func hardwareModel() -> String {
        #if os(iOS)
        var system = utsname()
        uname(&system)
        return withUnsafeBytes(of: system.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        #else
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &model, &size, nil, 0)
        return String(decoding: model.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        #endif
    }
}
