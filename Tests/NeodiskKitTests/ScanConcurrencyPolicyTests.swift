import Foundation
import Testing
@testable import NeodiskKit

/// Thread-safe mutable holder so tests can steer what the adaptive
/// concurrency's injected sampler returns.
private final class ConditionsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var conditions: ScanThermalConditions
    private(set) var sampleCount = 0

    init(_ conditions: ScanThermalConditions) {
        self.conditions = conditions
    }

    func set(_ newConditions: ScanThermalConditions) {
        lock.lock()
        defer { lock.unlock() }
        conditions = newConditions
    }

    func sample() -> ScanThermalConditions {
        lock.lock()
        defer { lock.unlock() }
        sampleCount += 1
        return conditions
    }
}

@Suite struct ScanConcurrencyPolicyTests {
    private let serious = ScanThermalConditions(thermalState: .serious, isLowPowerModeEnabled: false)
    private let fair = ScanThermalConditions(thermalState: .fair, isLowPowerModeEnabled: false)
    private let lowPower = ScanThermalConditions(thermalState: .nominal, isLowPowerModeEnabled: true)

    @Test func bulkTraversalUsesStorageAwareCeilings() {
        let parallel = ScanConcurrencyPolicy.directoryTraversalWorkerLimit(
            for: ScanOptions(),
            bulkEnumeration: true,
            sourceProfile: .localParallel,
            conditions: .nominal
        )
        let conservative = ScanConcurrencyPolicy.directoryTraversalWorkerLimit(
            for: ScanOptions(),
            bulkEnumeration: true,
            sourceProfile: .localConservative,
            conditions: .nominal
        )
        let network = ScanConcurrencyPolicy.directoryTraversalWorkerLimit(
            for: ScanOptions(),
            bulkEnumeration: true,
            sourceProfile: .network,
            conditions: .nominal
        )

        #expect(parallel > conservative)
        #expect(conservative >= network)
        #expect(parallel <= 24)
        #expect(conservative <= 8)
        #expect(network <= 4)
    }

    @Test func incrementalSubtreeConcurrencyDeratesUnderHeatAndLowPower() {
        #expect(ScanConcurrencyPolicy.incrementalSubtreeWorkerLimit(conditions: .nominal) == 2)
        #expect(ScanConcurrencyPolicy.incrementalSubtreeWorkerLimit(conditions: serious) == 1)
        #expect(ScanConcurrencyPolicy.incrementalSubtreeWorkerLimit(conditions: lowPower) == 1)
    }

    @Test func seriousThermalStateHalvesTraversalLimit() {
        let nominalLimit = ScanConcurrencyPolicy.directoryTraversalWorkerLimit(
            for: ScanOptions(), bulkEnumeration: true, conditions: .nominal
        )
        let seriousLimit = ScanConcurrencyPolicy.directoryTraversalWorkerLimit(
            for: ScanOptions(), bulkEnumeration: true, conditions: serious
        )
        #expect(seriousLimit == max(1, nominalLimit / 2))
    }

    @Test func fairThermalStateShedsOneWorker() {
        let nominalLimit = ScanConcurrencyPolicy.directoryTraversalWorkerLimit(
            for: ScanOptions(), bulkEnumeration: true, conditions: .nominal
        )
        let fairLimit = ScanConcurrencyPolicy.directoryTraversalWorkerLimit(
            for: ScanOptions(), bulkEnumeration: true, conditions: fair
        )
        #expect(fairLimit == max(1, nominalLimit - 1))
    }

    @Test func lowPowerModeHalvesTraversalLimit() {
        let nominalLimit = ScanConcurrencyPolicy.directoryTraversalWorkerLimit(
            for: ScanOptions(), bulkEnumeration: false, conditions: .nominal
        )
        let lowPowerLimit = ScanConcurrencyPolicy.directoryTraversalWorkerLimit(
            for: ScanOptions(), bulkEnumeration: false, conditions: lowPower
        )
        #expect(lowPowerLimit == max(1, nominalLimit / 2))
    }

    @Test func explicitOptionOverrideIgnoresThermalState() {
        let options = ScanOptions(tuning: .init(directoryTraversalWorkerLimit: 5))
        let limit = ScanConcurrencyPolicy.directoryTraversalWorkerLimit(
            for: options, bulkEnumeration: true, conditions: serious
        )
        #expect(limit == 5)
    }

    @Test func adaptiveCeilingDropsWhenScanHeatSoaks() {
        let box = ConditionsBox(.nominal)
        var concurrency = AdaptiveScanConcurrency(
            options: ScanOptions(),
            bulkEnumeration: true,
            sampleInterval: .zero,
            sampleConditions: { box.sample() }
        )
        let nominalCeiling = concurrency.traversalWorkerLimit

        box.set(serious)
        concurrency.refreshIfDue()
        #expect(concurrency.traversalWorkerLimit == max(1, nominalCeiling / 2))

        box.set(.nominal)
        concurrency.refreshIfDue()
        #expect(concurrency.traversalWorkerLimit == nominalCeiling)
    }

    @Test func adaptiveCeilingThrottlesSampling() {
        let box = ConditionsBox(.nominal)
        var concurrency = AdaptiveScanConcurrency(
            options: ScanOptions(),
            bulkEnumeration: true,
            sampleInterval: .seconds(3_600),
            sampleConditions: { box.sample() }
        )
        let initialSampleCount = box.sampleCount
        let nominalCeiling = concurrency.traversalWorkerLimit

        box.set(serious)
        for _ in 0..<100 {
            concurrency.refreshIfDue()
        }
        #expect(box.sampleCount == initialSampleCount)
        #expect(concurrency.traversalWorkerLimit == nominalCeiling)
    }

    @Test func adaptiveCeilingWithOverridesStaysPinned() {
        let box = ConditionsBox(.nominal)
        var concurrency = AdaptiveScanConcurrency(
            options: ScanOptions(tuning: .init(directoryClassificationWorkerLimit: 3, directoryTraversalWorkerLimit: 4)),
            bulkEnumeration: false,
            sampleInterval: .zero,
            sampleConditions: { box.sample() }
        )
        #expect(concurrency.traversalWorkerLimit == 4)

        box.set(serious)
        concurrency.refreshIfDue()
        #expect(concurrency.traversalWorkerLimit == 4)
    }

    @Test func classificationLimitDividesSharedMetadataBudget() {
        let box = ConditionsBox(.nominal)
        var concurrency = AdaptiveScanConcurrency(
            options: ScanOptions(),
            bulkEnumeration: false,
            sampleInterval: .zero,
            sampleConditions: { box.sample() }
        )
        let expectedNominal = ScanConcurrencyPolicy.effectiveDirectoryClassificationWorkerLimit(
            traversalWorkerLimit: ScanConcurrencyPolicy.directoryTraversalWorkerLimit(
                for: ScanOptions(), bulkEnumeration: false, conditions: .nominal
            ),
            classificationWorkerLimit: ScanConcurrencyPolicy.directoryClassificationWorkerLimit(
                for: ScanOptions(), conditions: .nominal
            ),
            conditions: .nominal
        )
        #expect(concurrency.classificationWorkerLimit == expectedNominal)

        box.set(serious)
        concurrency.refreshIfDue()
        let expectedSerious = ScanConcurrencyPolicy.effectiveDirectoryClassificationWorkerLimit(
            traversalWorkerLimit: ScanConcurrencyPolicy.directoryTraversalWorkerLimit(
                for: ScanOptions(), bulkEnumeration: false, conditions: serious
            ),
            classificationWorkerLimit: ScanConcurrencyPolicy.directoryClassificationWorkerLimit(
                for: ScanOptions(), conditions: serious
            ),
            conditions: serious
        )
        #expect(concurrency.classificationWorkerLimit == expectedSerious)
        #expect(concurrency.classificationWorkerLimit >= 1)
    }
}
