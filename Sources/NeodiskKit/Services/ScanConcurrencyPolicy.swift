//
//  ScanConcurrencyPolicy.swift
//  Neodisk
//
//  Worker-pool sizing for the scan engine. Limits derive from hardware
//  (active cores) derated by the machine's power/thermal conditions.
//  Thermal state is re-sampled on a throttle during traversal (see
//  AdaptiveScanConcurrency) so a scan that starts cold and heat-soaks over
//  minutes sheds parallelism instead of running on the ceiling frozen at
//  scan setup.
//

import Foundation
import Darwin

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

    /// One `statfs` yielding both the traversal profile and the mount's
    /// device identity, so callers that need both (concurrency ruling) don't
    /// pay two syscalls. `deviceID` is nil only when the path can't be
    /// stat'd; the profile then falls back to `.unsupported`.
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
}

/// A scan target's traversal profile paired with the physical device it lives
/// on — the inputs the concurrency ruling needs to decide whether two scans
/// can share the machine without fighting over one disk.
public nonisolated struct ScanSourceIdentity: Sendable, Equatable {
    public let profile: ScanSourceProfile
    /// The mount's `statfs` fsid; nil for `cloudscan://` targets, which have
    /// no local device and never contend with an on-disk scan.
    public let deviceID: UInt64?

    public init(profile: ScanSourceProfile, deviceID: UInt64?) {
        self.profile = profile
        self.deviceID = deviceID
    }

    public static func detect(for target: ScanTarget) -> ScanSourceIdentity {
        if target.kind == .cloud {
            // Cloud accounts stream over the network; no local device.
            return ScanSourceIdentity(profile: .network, deviceID: nil)
        }
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
    /// Whether a new scan may run concurrently with one already in flight.
    /// Different devices, a cloud source on either side (no local device), or
    /// a network source on either side never contend, so they run together.
    /// On one local device, only the internally-parallel profile fans out
    /// safely to two scans; conservative/exotic disks serialize — an explicit
    /// new scan wins the disk, an implicit refresh yields to the running one.
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

/// A point-in-time sample of the power/thermal inputs that derate worker
/// ceilings.
nonisolated struct ScanThermalConditions: Sendable {
    let thermalState: ProcessInfo.ThermalState
    let isLowPowerModeEnabled: Bool

    nonisolated static func current() -> ScanThermalConditions {
        let processInfo = ProcessInfo.processInfo
        return ScanThermalConditions(
            thermalState: processInfo.thermalState,
            isLowPowerModeEnabled: processInfo.isLowPowerModeEnabled
        )
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

    /// Bounded worker count for the clone-family private-size reads in
    /// finalize (`CloneDeduplicator`). These are independent, I/O-bound
    /// `getattrlist` reads, so they oversubscribe cores modestly; the
    /// hardware-aware helper still halves under thermal/low-power pressure and
    /// the shared metadata budget caps the ceiling.
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

        return hardwareAwareWorkerLimit(minimum: 4, processorDivisor: 1, maximum: 8)
    }

    static func incrementalSubtreeWorkerLimit(
        conditions: ScanThermalConditions = .current()
    ) -> Int {
        if let environmentLimit = ProcessInfo.processInfo.environment["NEODISK_SCAN_INCREMENTAL_SUBTREE_WORKERS"]
            .flatMap(Int.init) {
            return max(1, environmentLimit)
        }
        // Each subtree owns its own bounded traversal and summary pools. Two
        // independent roots expose useful I/O overlap without multiplying the
        // full-scan ceilings into an unbounded machine-wide fan-out.
        if conditions.isLowPowerModeEnabled {
            return 1
        }
        switch conditions.thermalState {
        case .serious, .critical:
            return 1
        case .fair, .nominal:
            return 2
        @unknown default:
            return 1
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

        // Bulk enumeration turns each directory into one fat, self-
        // contained work unit with no intra-directory sub-workers, so the
        // traversal pool is the only parallelism left — cores/2 measurably
        // starves it (~15.1s vs ~10.2s on a 470k-file fixture, 10 cores).
        if bulkEnumeration {
            switch sourceProfile {
            case .localParallel:
                // getattrlistbulk self-contends in the kernel past ~8 concurrent
                // readers: on `~` (1.6M files) traversal wall was 59-65s at 20
                // workers vs 36-44s at 8 while summed sys CPU ballooned 56→64s
                // for zero wall gain (PERFORMANCE.md, 2026-07-17). Cap width at
                // physical cores but no more than that contention knee.
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
        @unknown default:
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
        @unknown default:
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
        @unknown default:
            break
        }

        return limit
    }
}

/// Live worker ceilings for one scan's traversal loop.
///
/// `refreshIfDue()` re-samples thermal conditions at most once per
/// `sampleInterval` (default 250 ms) and re-derives the traversal and
/// per-directory classification ceilings from the fresh sample. The
/// traversal dispatcher only launches new directory tasks while it is under
/// the ceiling, so a lowered ceiling sheds parallelism as in-flight tasks
/// drain — nothing is cancelled. Explicit option/environment overrides pin
/// their ceiling for the whole scan.
///
/// `thermalState` lags real DVFS throttling, so this is a coarse
/// mitigation aimed at multi-minute scans; short scans never leave the
/// initial sample.
///
/// Single-consumer by design: mutated only from the traversal loop.
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

    /// The ceiling under nominal conditions — what the scan can grow back to
    /// once thermal or low-power pressure clears. Sizes fixed pools (the
    /// directory I/O executor) so a scan started under pressure is not
    /// capped for its whole life; the adaptive in-flight limit still sheds
    /// parallelism while pressure lasts.
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
