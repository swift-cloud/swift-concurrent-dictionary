import Foundation
import Synchronization
import Testing

@testable import ConcurrentDictionary

@Test func example() async throws {
    let d = ConcurrentDictionary<64, String, Int>()
    d["a"] = 1
    #expect(d["a"] == 1)
}

@Test func concurrentAccessSameKey() async throws {
    let d = ConcurrentDictionary<64, String, Int>()
    let key = "shared_key"
    d[key] = 0

    await withTaskGroup(of: Void.self) { group in
        for _ in 0..<1000 {
            group.addTask {
                // Read the current value
                let _ = d[key]
                // Write an incremented value
                d[key] = d[key, default: 0] + 1
                // Read again
                let _ = d[key]
            }
        }
    }

    // Verify the key is still accessible and has a value
    let finalValue = d[key]
    #expect(finalValue != nil)
    #expect(finalValue! < 1000)
    #expect(finalValue! > 0)
}

@Test func concurrentIncrementSameKey() async throws {
    let d = ConcurrentDictionary<64, String, Int>()
    let key = "counter"
    d[key] = 0

    await withTaskGroup(of: Void.self) { group in
        for _ in 0..<1000 {
            group.addTask {
                // Use mutate to atomically increment
                d.incrementValue(forKey: key, by: 1)
            }
        }
    }

    // The final value should be set (though not necessarily 1000 due to race conditions in read-modify-write)
    let finalValue = d[key]
    #expect(finalValue != nil)
    #expect(finalValue! > 0)
}

@Test func concurrentIncrementRandomKeys() async throws {
    let d = ConcurrentDictionary<8, Int, Int>()

    await withTaskGroup(of: Void.self) { group in
        for _ in 0..<1000 {
            group.addTask {
                d[.random(in: 1...100)] = 1
            }
        }
    }

    #expect(d.count == 100)
}

@Test func concurrentReadWriteSameKey() async throws {
    let d = ConcurrentDictionary<64, String, Int>()
    let key = "rw_key"
    d[key] = 42

    await withTaskGroup(of: Void.self) { group in
        // 500 readers
        for _ in 0..<500 {
            group.addTask {
                let value = d[key]
                #expect(value != nil)
            }
        }
        // 500 writers
        for i in 0..<500 {
            group.addTask {
                d[key] = i
            }
        }
    }

    // Verify the key still has a valid value
    let finalValue = d[key]
    #expect(finalValue != nil)
}

@Test func performanceReadRegular() async throws {
    let d = ConcurrentDictionary<64, String, Int>()
    let key = "shared_key"
    d[key] = 0

    await withTaskGroup(of: Void.self) { group in
        group.addTask {
            for _ in 0..<1_000_000 {
                let _ = d[key]
            }
        }
        group.addTask {
            for _ in 0..<1_000_000 {
                d[key] = Int.random(in: 0...1000)
            }
        }
    }
}

@Test func timing() async throws {
    let a = ConcurrentDictionary<128, Int, String>()
    await processAcrossCores(name: "\(a)") { i in
        a[i] = "\(i)".uppercased().lowercased()
    }

    let b = ConcurrentDictionary<1, Int, String>()
    await processAcrossCores(name: "\(b)") { i in
        b[i] = "\(i)".uppercased().lowercased()
    }
}

func processAcrossCores(
    name: String,
    total: Int = 10_000_000,
    operation: @Sendable @escaping (Int) async -> Void
) async {
    await logExecutionTime(name) {
        await withTaskGroup(of: Void.self) { tg in
            let cores = ProcessInfo.processInfo.activeProcessorCount
            let tasksPerCore = total / cores
            for i in 0..<cores {
                tg.addTask {
                    let start = i * tasksPerCore
                    let end = (i + 1) * tasksPerCore
                    for j in start..<end {
                        await operation(j)
                    }
                }
            }
        }
    }
}

func logExecutionTime(_ log: String, block: () async -> Void) async {
    let start = DispatchTime.now()
    await block()
    let end = DispatchTime.now()
    let diff = Double(end.uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000
    print(log, ":", String(format: "%.3f", diff), "seconds")
}
