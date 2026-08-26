import Foundation
#if canImport(HealthKit)
import HealthKit
#endif
#if os(macOS)
import Security
#endif
#if canImport(Darwin)
import Darwin
#endif

/// Why `HKHealthStore.isHealthDataAvailable()` said no.
///
/// On the Mac that one boolean collapses at least five separate causes into a
/// single unhelpful `false`, and the fixes for them have nothing in common —
/// one is a build setting, one is a Developer-portal capability, one is the
/// hardware, and two are on your iPhone. So rather than show the user a dead
/// end, check each cause we can actually observe and say which one it is.
///
/// Every check is best-effort: a `.unknown` means we could not determine it,
/// never that it is broken.
public struct HealthKitDiagnostic: Identifiable, Hashable, Sendable {
    public enum Status: Hashable, Sendable {
        case ok
        case problem
        case unknown

        public var symbolName: String {
            switch self {
            case .ok: return "checkmark.circle.fill"
            case .problem: return "exclamationmark.triangle.fill"
            case .unknown: return "questionmark.circle"
            }
        }
    }

    public let id: String
    public let title: String
    public let status: Status
    /// What we observed.
    public let detail: String
    /// What to do about it, when there is something to do.
    public let remedy: String?

    public init(id: String, title: String, status: Status, detail: String, remedy: String? = nil) {
        self.id = id
        self.title = title
        self.status = status
        self.detail = detail
        self.remedy = remedy
    }
}

public enum HealthKitDiagnostics {

    /// Runs every check, cheapest first. Ordered so the first `.problem` in the
    /// list is the one worth fixing first — later checks can only be
    /// meaningful once the earlier ones pass.
    public static func run() -> [HealthKitDiagnostic] {
        var checks: [HealthKitDiagnostic] = []
        checks.append(builtWithHealthKit)
        #if os(macOS)
        checks.append(systemVersion)
        checks.append(hardware)
        checks.append(entitlement)
        checks.append(provisioningProfile)
        checks.append(iCloudAccount)
        #endif
        checks.append(dataStore)
        return checks
    }

    /// The single next action, chosen from the first failing check.
    public static func nextStep(in checks: [HealthKitDiagnostic]) -> String? {
        checks.first { $0.status == .problem }?.remedy
            ?? checks.first { $0.status == .unknown }?.remedy
    }

    /// Plain text for the "Copy diagnostics" button, so a report can be pasted
    /// into a bug rather than retyped from a screenshot.
    public static func report(_ checks: [HealthKitDiagnostic] = run()) -> String {
        checks.map { check in
            let mark: String
            switch check.status {
            case .ok: mark = "[ok]"
            case .problem: mark = "[!!]"
            case .unknown: mark = "[??]"
            }
            let remedy = check.remedy.map { "\n     → \($0)" } ?? ""
            return "\(mark) \(check.title): \(check.detail)\(remedy)"
        }
        .joined(separator: "\n")
    }

    // MARK: - Individual checks

    private static var builtWithHealthKit: HealthKitDiagnostic {
        #if canImport(HealthKit)
        .init(id: "sdk", title: "Built with HealthKit", status: .ok,
              detail: "The HealthKit framework is linked into this build.")
        #else
        .init(id: "sdk", title: "Built with HealthKit", status: .problem,
              detail: "This build does not link HealthKit.",
              remedy: "Build against the macOS 26 SDK or later, or use Import from export.zip instead.")
        #endif
    }

    private static var dataStore: HealthKitDiagnostic {
        #if canImport(HealthKit)
        let available = HKHealthStore.isHealthDataAvailable()
        return .init(
            id: "store", title: "Health data store",
            status: available ? .ok : .problem,
            detail: available
                ? "HealthKit has a store on this device."
                : "HKHealthStore.isHealthDataAvailable() returned false.",
            remedy: available ? nil : "Work through the failing checks above — this is the symptom, not the cause."
        )
        #else
        return .init(id: "store", title: "Health data store", status: .unknown,
                     detail: "Cannot be checked without HealthKit.")
        #endif
    }

    #if os(macOS)

    private static var systemVersion: HealthKitDiagnostic {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let text = "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        let recent = version.majorVersion >= 26
        return .init(
            id: "os", title: "macOS version",
            status: recent ? .ok : .problem,
            detail: "Running macOS \(text).",
            remedy: recent ? nil : "Mac apps only get a HealthKit store on macOS 26 (Tahoe) or later. Until then use Import from export.zip."
        )
    }

    /// HealthKit on the Mac needs real hardware — the store does not exist in a
    /// virtual machine, and no amount of signing or iCloud settings will
    /// conjure one.
    private static var hardware: HealthKitDiagnostic {
        guard let virtual = isVirtualMachine else {
            return .init(id: "hardware", title: "Mac hardware", status: .unknown,
                         detail: "Could not determine whether this is a virtual machine.")
        }
        return .init(
            id: "hardware", title: "Mac hardware",
            status: virtual ? .problem : .ok,
            detail: virtual ? "Running inside a virtual machine." : "Running on real Mac hardware.",
            remedy: virtual ? "HealthKit has no store inside a VM. Run MyHealth on the Mac itself." : nil
        )
    }

    /// The entitlement being in `Config/MyHealth.entitlements` is not the same
    /// as it being in the signature: if the App ID does not have the HealthKit
    /// capability enabled, the profile does not carry it and the signed binary
    /// silently ships without it. Ask the running process, not the source.
    private static var entitlement: HealthKitDiagnostic {
        switch selfEntitlement("com.apple.developer.healthkit") {
        case .some(true):
            return .init(id: "entitlement", title: "HealthKit entitlement", status: .ok,
                         detail: "com.apple.developer.healthkit is present in this binary's signature.")
        case .some(false):
            return .init(
                id: "entitlement", title: "HealthKit entitlement", status: .problem,
                detail: "com.apple.developer.healthkit is missing from this binary's signature.",
                remedy: "In Xcode, select the MyHealth target → Signing & Capabilities → + Capability → HealthKit. Adding it to the .entitlements file by hand is not enough: the capability has to be enabled on the App ID so the provisioning profile carries it."
            )
        case .none:
            return .init(id: "entitlement", title: "HealthKit entitlement", status: .unknown,
                         detail: "Could not read this binary's code signature.")
        }
    }

    private static var provisioningProfile: HealthKitDiagnostic {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/embedded.provisionprofile")
        let embedded = FileManager.default.fileExists(atPath: url.path)
        return .init(
            id: "profile", title: "Provisioning profile",
            status: embedded ? .ok : .problem,
            detail: embedded ? "A provisioning profile is embedded in the app bundle."
                             : "No provisioning profile is embedded in the app bundle.",
            remedy: embedded ? nil : "The app is not signed with a development profile, so restricted entitlements like HealthKit are not honoured. Set a Team on the target and let Xcode sign it automatically."
        )
    }

    /// The Mac never talks to the Watch. Samples arrive over iCloud Health
    /// sync, which needs the same Apple Account signed in here.
    private static var iCloudAccount: HealthKitDiagnostic {
        let signedIn = FileManager.default.ubiquityIdentityToken != nil
        return .init(
            id: "icloud", title: "iCloud account",
            status: signedIn ? .ok : .problem,
            detail: signedIn ? "Signed in to iCloud on this Mac."
                             : "No iCloud account is available to this app.",
            remedy: signedIn
                ? nil
                : "Sign in to iCloud in System Settings with the same Apple Account as your iPhone, then check Health is switched on under iCloud on the phone."
        )
    }

    // MARK: - Primitives

    private static var isVirtualMachine: Bool? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.hv_vmm_present", &value, &size, nil, 0) == 0 else { return nil }
        return value != 0
    }

    private static func selfEntitlement(_ key: String) -> Bool? {
        guard let task = SecTaskCreateFromSelf(nil) else { return nil }
        guard let value = SecTaskCopyValueForEntitlement(task, key as CFString, nil) else { return false }
        return (value as? Bool) ?? true
    }

    #endif
}
