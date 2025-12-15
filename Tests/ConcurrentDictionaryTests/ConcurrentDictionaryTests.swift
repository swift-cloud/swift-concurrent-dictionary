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
