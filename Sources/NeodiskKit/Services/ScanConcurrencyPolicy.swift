// Scan worker-pool sizing from active cores, derated by power and thermal state. Thermal state is
// re-sampled during traversal so a scan that heat-soaks sheds parallelism.

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public nonisolated enum ScanSourceProfile: Sendable {
    /// Internal APFS is the one source class where broad directory parallelism
    /// is predictably beneficial.
    case localParallel
    /// External/removable APFS may be SSD or rotational, so stay moderate.
    case localConservative
    /// Network filesystems amplify seeks/round trips under fan-out.
    case network
    /// Exotic or older local filesystems retain the historical small pool.
    case unsupported

    static func detect(for url: URL) -> ScanSourceProfile {
        probe(for: url).profile
    }

    /// One `statfs` yields both profile and device identity. `deviceID` is nil only when the path can't be
    /// stat'd, and the profile then falls back to `.unsupported`.
    #if canImport(Darwin)
    static func probe(for url: URL) -> (profile: ScanSourceProfile, deviceID: UInt64?) {
        var fileSystemStats = statfs()
        let statResult = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return statfs(path, &fileSystemStats)
        }
        guard statResult == 0 else { return (.unsupported, nil) }
        let deviceID = deviceID(from: fileSystemStats.f_fsid)
        guard fileSystemStats.f_flags & UInt32(MNT_LOCAL) != 0 else { return (.network, deviceID) }

        let fileSystemType = withUnsafeBytes(of: fileSystemStats.f_fstypename) { rawBuffer -> String in
            guard let base = rawBuffer.bindMemory(to: CChar.self).baseAddress else { return "" }
            return String(cString: base).lowercased()
        }
        guard fileSystemType == "apfs" else { return (.unsupported, deviceID) }

        let values = try? url.resourceValues(forKeys: [
            .volumeIsInternalKey,
            .volumeIsRemovableKey
        ])
        if values?.volumeIsInternal == true, values?.volumeIsRemovable != true {
            return (.localParallel, deviceID)
        }
        return (.localConservative, deviceID)
    }

    private static func deviceID(from fsid: fsid_t) -> UInt64 {
        let high = UInt64(UInt32(bitPattern: fsid.val.0)) << 32
        let low = UInt64(UInt32(bitPattern: fsid.val.1))
        return high | low
    }
    #elseif os(Linux)
    /// Linux statfs has no type name or MNT_LOCAL, so the profile comes from the mount table: network and
    /// FUSE fan out poorly, rotational or removable disks and FAT/exFAT/NTFS stay moderate.
    static func probe(for url: URL) -> (profile: ScanSourceProfile, deviceID: UInt64?) {
        var status = stat()
        let statResult = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return stat(path, &status)
        }
        guard statResult == 0 else { return (.unsupported, nil) }
        let deviceID = UInt64(status.st_dev)
        guard let fileSystemType = LinuxMountTable.fileSystemType(forPath: url.path) else {
            return (.unsupported, deviceID)
        }
        switch LinuxFileSystemClass(fileSystemType: fileSystemType) {
        case .network:
            return (.network, deviceID)
        case .foreign:
            return (.localConservative, deviceID)
        case .local, .memory:
            return (isRotationalOrRemovable(device: status.st_dev) ? .localConservative : .localParallel, deviceID)
        case .virtual:
            return (.unsupported, deviceID)
        }
    }

    /// Partitions keep the queue flags on their parent disk; virtual devices (major 0) have none.
    private static func isRotationalOrRemovable(device: dev_t) -> Bool {
        let major = (device >> 8) & 0xfff | (device >> 32) & ~0xfff
        let minor = device & 0xff | (device >> 12) & ~0xff
        guard major != 0 else { return false }
        let base = "/sys/dev/block/\(major):\(minor)"
        func flag(_ relativePath: String) -> Bool? {
            for candidate in ["\(base)/\(relativePath)", "\(base)/../\(relativePath)"] {
                if let text = try? String(contentsOfFile: candidate, encoding: .utf8) {
                    return text.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
                }
            }
            return nil
        }
        return flag("queue/rotational") == true || flag("removable") == true
    }
    #else
    static func probe(for url: URL) -> (profile: ScanSourceProfile, deviceID: UInt64?) {
        (.unsupported, nil)
    }
    #endif
}

/// Profile plus physical device: what the ruling needs to tell whether two scans would fight over one disk.
public nonisolated struct ScanSourceIdentity: Sendable, Equatable {
    public let profile: ScanSourceProfile
    /// The mount's `statfs` fsid, nil when unknown.
    public let deviceID: UInt64?

    public init(profile: ScanSourceProfile, deviceID: UInt64?) {
        self.profile = profile
        self.deviceID = deviceID
    }

    public static func detect(for target: ScanTarget) -> ScanSourceIdentity {
        let probe = ScanSourceProfile.probe(for: target.url)
        return ScanSourceIdentity(profile: probe.profile, deviceID: probe.deviceID)
    }
}

/// How a new scan should treat one already running: run alongside it, hold
/// off, or take its place.
public enum ConcurrentScanRuling: Sendable, Equatable {
    /// The two sources don't contend — scan both at once.
    case runBoth
    /// Same contended disk and the new scan is an unsolicited refresh —
    /// leave the running scan alone and show the new target from cache.
    case deferNew
    /// Same contended disk and the new scan is explicit — stop the running
    /// one so the user's request gets the disk.
    case cancelOld
}

extension ScanSourceIdentity {
    /// Different devices, cloud or network sources never contend. On one local disk only the parallel
    /// profile runs two scans; otherwise an explicit scan wins and an implicit refresh yields.
    public static func ruling(
        running: ScanSourceIdentity,
        new: ScanSourceIdentity,
        newScanIsExplicit: Bool
    ) -> ConcurrentScanRuling {
        if running.deviceID == nil || new.deviceID == nil
            || running.deviceID != new.deviceID
            || running.profile == .network || new.profile == .network {
            return .runBoth
        }
        // Same local device from here.
        switch new.profile {
        case .localParallel:
            return .runBoth
        case .localConservative, .unsupported, .network:
            return newScanIsExplicit ? .cancelOld : .deferNew
        }
    }
}

/// Mirrors `ProcessInfo.ThermalState`, which only Apple platforms report; elsewhere it reads `.nominal`.
nonisolated enum ScanThermalState: Int, Sendable {
    case nominal, fair, serious, critical

    #if canImport(Darwin)
    init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .serious
        }
    }
    #endif
}

/// A point-in-time sample of the power/thermal inputs that derate worker
/// ceilings.
nonisolated struct ScanThermalConditions: Sendable {
    let thermalState: ScanThermalState
    let isLowPowerModeEnabled: Bool

    nonisolated static func current() -> ScanThermalConditions {
        #if canImport(Darwin)
        let processInfo = ProcessInfo.processInfo
        return ScanThermalConditions(
            thermalState: ScanThermalState(processInfo.thermalState),
            isLowPowerModeEnabled: processInfo.isLowPowerModeEnabled
        )
        #else
        return .nominal
        #endif
    }

    nonisolated static let nominal = ScanThermalConditions(
        thermalState: .nominal,
        isLowPowerModeEnabled: false
    )
}

nonisolated enum ScanConcurrencyPolicy {
    static let directoryClassificationParallelThreshold = 128
    // Shared budget for concurrent child metadata reads across traversal and classification workers.
    static let directoryMetadataWorkerBudgetMaximum = 16

    /// Independent I/O-bound `getattrlist` reads, so they oversubscribe cores modestly; still halves under
    /// thermal or low-power pressure.
    static func cloneMetadataFetchWorkerLimit(
        conditions: ScanThermalConditions = .current()
    ) -> Int {
        hardwareAwareWorkerLimit(
            minimum: 4,
            processorMultiplier: 2,
            maximum: directoryMetadataWorkerBudgetMaximum,
            conditions: conditions
        )
    }

    static func atomicSummaryWorkerLimit(for options: ScanOptions) -> Int {
        if let optionLimit = options.tuning.atomicSummaryWorkerLimit {
            return max(1, optionLimit)
        }

        if let environmentLimit = ProcessInfo.processInfo.environment["NEODISK_SCAN_ATOMIC_SUMMARY_WORKERS"]
            .flatMap(Int.init) {
            return max(1, environmentLimit)
        }

        // Leave one cooperative thread free: filling every thread starves the loop that dispatches packages,
        // so the bar sits near empty then jumps. Costs no measurable wall time.
        let cooperativeWidth = max(1, ProcessInfo.processInfo.activeProcessorCount)
        return min(
            hardwareAwareWorkerLimit(minimum: 4, processorDivisor: 1, maximum: 8),
            max(1, cooperativeWidth - 1)
        )
    }

    static func incrementalSubtreeWorkerLimit(
        conditions: ScanThermalConditions = .current()
    ) -> Int {
        if let environmentLimit = ProcessInfo.processInfo.environment["NEODISK_SCAN_INCREMENTAL_SUBTREE_WORKERS"]
            .flatMap(Int.init) {
            return max(1, environmentLimit)
        }
        // Each subtree has its own bounded pools; two roots give I/O overlap without unbounded fan-out.
        if conditions.isLowPowerModeEnabled {
            return 1
        }
        switch conditions.thermalState {
        case .serious, .critical:
            return 1
        case .fair, .nominal:
            return 2
        }
    }

    /// Explicit traversal-worker override from options or environment;
    /// nil means the limit is hardware-derived (and thermally adaptive).
    static func directoryTraversalWorkerOverride(for options: ScanOptions) -> Int? {
        if let optionLimit = options.tuning.directoryTraversalWorkerLimit {
            return max(1, optionLimit)
        }

        if let environmentLimit = ProcessInfo.processInfo.environment["NEODISK_SCAN_DIRECTORY_TRAVERSAL_WORKERS"]
            .flatMap(Int.init) {
            return max(1, environmentLimit)
        }

        return nil
    }

    static func directoryTraversalWorkerLimit(
        for options: ScanOptions,
        bulkEnumeration: Bool = false,
        sourceProfile: ScanSourceProfile = .localParallel,
        conditions: ScanThermalConditions = .current()
    ) -> Int {
        if let override = directoryTraversalWorkerOverride(for: options) {
            return override
        }

        // Bulk enumeration leaves the traversal pool as the only parallelism; cores/2 starves it
        // (~15.1s vs ~10.2s on a 470k-file fixture, 10 cores).
        if bulkEnumeration {
            switch sourceProfile {
            case .localParallel:
                // getattrlistbulk self-contends in the kernel past ~8 readers (on `~`, 59-65s at 20 workers vs
                // 36-44s at 8), so cap at physical cores but no more than that.
                return hardwareAwareWorkerLimit(
                    minimum: 4,
                    processorMultiplier: 1,
                    maximum: 8,
                    conditions: conditions
                )
            case .localConservative:
                return hardwareAwareWorkerLimit(minimum: 4, processorDivisor: 1, maximum: 8, conditions: conditions)
            case .network, .unsupported:
                return hardwareAwareWorkerLimit(minimum: 2, processorDivisor: 2, maximum: 4, conditions: conditions)
            }
        }

        return hardwareAwareWorkerLimit(minimum: 2, processorDivisor: 2, maximum: 8, conditions: conditions)
    }

    /// Explicit classification-worker override from options or environment;
    /// nil means the limit is hardware-derived (and thermally adaptive).
    static func directoryClassificationWorkerOverride(for options: ScanOptions) -> Int? {
        if let optionLimit = options.tuning.directoryClassificationWorkerLimit {
            return max(1, optionLimit)
        }

        if let environmentLimit = ProcessInfo.processInfo.environment["NEODISK_SCAN_DIRECTORY_CLASSIFICATION_WORKERS"]
            .flatMap(Int.init) {
            return max(1, environmentLimit)
        }

        return nil
    }

    static func directoryClassificationWorkerLimit(
        for options: ScanOptions,
        conditions: ScanThermalConditions = .current()
    ) -> Int {
        if let override = directoryClassificationWorkerOverride(for: options) {
            return override
        }

        return hardwareAwareWorkerLimit(minimum: 2, processorDivisor: 2, maximum: 8, conditions: conditions)
    }

    static func effectiveDirectoryClassificationWorkerLimit(
        traversalWorkerLimit: Int,
        classificationWorkerLimit: Int,
        conditions: ScanThermalConditions = .current()
    ) -> Int {
        guard traversalWorkerLimit > 1 else {
            return classificationWorkerLimit
        }

        let sharedMetadataBudget = sharedMetadataWorkerBudget(conditions: conditions)
        let perDirectoryLimit = max(1, sharedMetadataBudget / max(1, traversalWorkerLimit))
        return min(classificationWorkerLimit, perDirectoryLimit)
    }

    private static func sharedMetadataWorkerBudget(conditions: ScanThermalConditions) -> Int {
        let activeProcessorCount = max(1, ProcessInfo.processInfo.activeProcessorCount)
        var limit = min(
            max(4, activeProcessorCount * 2),
            directoryMetadataWorkerBudgetMaximum
        )

        if conditions.isLowPowerModeEnabled {
            limit = max(1, limit / 2)
        }

        switch conditions.thermalState {
        case .serious, .critical:
            limit = max(1, limit / 2)
        case .fair:
            limit = max(1, limit - 2)
        case .nominal:
            break
        }

        return limit
    }

    private static func hardwareAwareWorkerLimit(
        minimum: Int,
        processorDivisor: Int,
        maximum: Int,
        conditions: ScanThermalConditions = .current()
    ) -> Int {
        let activeProcessorCount = max(1, ProcessInfo.processInfo.activeProcessorCount)
        var limit = min(max(minimum, activeProcessorCount / max(1, processorDivisor)), maximum)

        if conditions.isLowPowerModeEnabled {
            limit = max(1, limit / 2)
        }

        switch conditions.thermalState {
        case .serious, .critical:
            limit = max(1, limit / 2)
        case .fair:
            limit = max(1, limit - 1)
        case .nominal:
            break
        }

        return limit
    }

    private static func hardwareAwareWorkerLimit(
        minimum: Int,
        processorMultiplier: Int,
        maximum: Int,
        conditions: ScanThermalConditions = .current()
    ) -> Int {
        let activeProcessorCount = max(1, ProcessInfo.processInfo.activeProcessorCount)
        var limit = min(max(minimum, activeProcessorCount * max(1, processorMultiplier)), maximum)

        if conditions.isLowPowerModeEnabled {
            limit = max(1, limit / 2)
        }

        switch conditions.thermalState {
        case .serious, .critical:
            limit = max(1, limit / 2)
        case .fair:
            limit = max(1, limit - 1)
        case .nominal:
            break
        }

        return limit
    }
}

/// Live worker ceilings, re-sampled from thermal conditions at most every `sampleInterval`. A lowered
/// ceiling sheds parallelism as tasks drain, never by cancelling. Mutated only from the traversal loop.
nonisolated struct AdaptiveScanConcurrency {
    private let deriveTraversalLimit: @Sendable (ScanThermalConditions) -> Int
    private let deriveClassificationLimit: @Sendable (ScanThermalConditions) -> Int
    private let sampleConditions: @Sendable () -> ScanThermalConditions
    private let sampleInterval: Duration
    private var lastSampledAt: ContinuousClock.Instant
    private(set) var traversalWorkerLimit: Int
    /// Per-directory child-classification limit, already divided down by the
    /// shared metadata budget across traversal workers.
    private(set) var classificationWorkerLimit: Int

    init(
        options: ScanOptions,
        bulkEnumeration: Bool,
        sourceProfile: ScanSourceProfile = .localParallel,
        sampleInterval: Duration = .milliseconds(250),
        sampleConditions: @escaping @Sendable () -> ScanThermalConditions = ScanThermalConditions.current
    ) {
        let traversalOverride = ScanConcurrencyPolicy.directoryTraversalWorkerOverride(for: options)
        let classificationOverride = ScanConcurrencyPolicy.directoryClassificationWorkerOverride(for: options)

        let deriveTraversalLimit: @Sendable (ScanThermalConditions) -> Int = { conditions in
            traversalOverride ?? ScanConcurrencyPolicy.directoryTraversalWorkerLimit(
                for: options,
                bulkEnumeration: bulkEnumeration,
                sourceProfile: sourceProfile,
                conditions: conditions
            )
        }
        let deriveClassificationLimit: @Sendable (ScanThermalConditions) -> Int = { conditions in
            let base = classificationOverride ?? ScanConcurrencyPolicy.directoryClassificationWorkerLimit(
                for: options,
                conditions: conditions
            )
            return ScanConcurrencyPolicy.effectiveDirectoryClassificationWorkerLimit(
                traversalWorkerLimit: deriveTraversalLimit(conditions),
                classificationWorkerLimit: base,
                conditions: conditions
            )
        }

        let initialConditions = sampleConditions()
        self.deriveTraversalLimit = deriveTraversalLimit
        self.deriveClassificationLimit = deriveClassificationLimit
        self.sampleConditions = sampleConditions
        self.sampleInterval = sampleInterval
        self.lastSampledAt = ContinuousClock.now
        self.traversalWorkerLimit = deriveTraversalLimit(initialConditions)
        self.classificationWorkerLimit = deriveClassificationLimit(initialConditions)
    }

    /// Sizes fixed pools so a scan started under pressure isn't capped for life; the adaptive in-flight
    /// limit still sheds parallelism while pressure lasts.
    var undegradedTraversalWorkerLimit: Int {
        deriveTraversalLimit(.nominal)
    }

    mutating func refreshIfDue(now: ContinuousClock.Instant = .now) {
        guard now - lastSampledAt >= sampleInterval else { return }
        lastSampledAt = now
        let conditions = sampleConditions()
        let previousLimit = traversalWorkerLimit
        traversalWorkerLimit = deriveTraversalLimit(conditions)
        classificationWorkerLimit = deriveClassificationLimit(conditions)
        if traversalWorkerLimit != previousLimit {
            ScanTiming.note(
                "concurrency derate traversal \(previousLimit)->\(traversalWorkerLimit) "
                + "thermal=\(conditions.thermalState.rawValue) lowPower=\(conditions.isLowPowerModeEnabled)"
            )
        }
    }
}
