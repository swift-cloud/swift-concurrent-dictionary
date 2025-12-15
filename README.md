# ConcurrentDictionary

A high-performance, thread-safe dictionary for Swift using striped locking for minimal contention.

## Features

- Thread-safe read and write access from multiple concurrent tasks
- Striped locking strategy for high throughput
- Compile-time configurable stripe count
- Zero dependencies beyond Swift standard library and [XXH3](https://github.com/swift-cloud/swift-xxh3)
- Full `Sendable` conformance

## Requirements

- Swift 6.0+
- macOS 15.0+ / iOS 18.0+ / tvOS 18.0+ / watchOS 11.0+

## Installation

Add the package to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/swift-cloud/swift-concurrent-dictionary.git", from: "1.0.0")
]
```

Then add the dependency to your target:

```swift
.target(
    name: "YourTarget",
    dependencies: [
        .product(name: "ConcurrentDictionary", package: "swift-concurrent-dictionary")
    ]
)
```

## Usage

### Creating a Dictionary

The stripe count is specified as a compile-time generic parameter. Choose a value based on your expected concurrency level:

```swift
import ConcurrentDictionary

// Create a dictionary with 16 stripes (good for moderate concurrency)
let cache = ConcurrentDictionary<16, String, Data>()

// Create a dictionary with 64 stripes (for high concurrency scenarios)
let highConcurrencyCache = ConcurrentDictionary<64, URL, Response>()
```

### Basic Operations

```swift
let dict = ConcurrentDictionary<8, String, Int>()

// Set a value
dict["score"] = 100

// Get a value
if let score = dict["score"] {
    print("Score: \(score)")
}

// Remove a value
dict["score"] = nil

// Or use removeValue to get the old value
if let removed = dict.removeValue(forKey: "score") {
    print("Removed: \(removed)")
}
```

### Default Values

```swift
let settings = ConcurrentDictionary<8, String, String>()

// Get with a default (does not store the default)
let theme = settings["theme", default: "light"]

// Update existing value or set new one
settings.updateValue("dark", forKey: "theme")
```

### Atomic Get-or-Set

Use `getOrSetValue` when you need atomic get-or-insert semantics:

```swift
let cache = ConcurrentDictionary<16, String, ExpensiveObject>()

// If key exists, returns existing value
// If key is absent, inserts and returns the new value
// The entire operation is atomic
let value = cache.getOrSetValue(ExpensiveObject(), forKey: "key")
```

### Atomic Increment (Numeric Values)

For numeric values, use `incrementValue` for atomic counter operations:

```swift
let counters = ConcurrentDictionary<8, String, Int>()

// Increment (starts at 0 if key doesn't exist)
counters.incrementValue(forKey: "page_views", by: 1)
counters.incrementValue(forKey: "page_views", by: 1)

// Decrement
counters.incrementValue(forKey: "page_views", by: -1)

// Get the new value
let views = counters.incrementValue(forKey: "api_calls", by: 1) // Returns 1
```

### Concurrent Access

The dictionary is safe to use from multiple concurrent tasks:

```swift
let metrics = ConcurrentDictionary<16, String, Int>()

await withTaskGroup(of: Void.self) { group in
    // Spawn 1000 concurrent tasks
    for i in 0..<1000 {
        group.addTask {
            metrics.incrementValue(forKey: "requests", by: 1)
            metrics["task-\(i)"] = i
        }
    }
}

print("Total requests: \(metrics["requests", default: 0])")
print("Total entries: \(metrics.count)")
```

### Cache Pattern

```swift
actor DataService {
    private let cache = ConcurrentDictionary<32, URL, Data>()
    
    func fetchData(from url: URL) async throws -> Data {
        // Check cache first
        if let cached = cache[url] {
            return cached
        }
        
        // Fetch and cache
        let data = try await URLSession.shared.data(from: url).0
        cache[url] = data
        return data
    }
    
    func clearCache() {
        cache.removeAll()
    }
}
```

## Performance Considerations

### Stripe Count

The stripe count determines the level of parallelism:

| Stripe Count | Use Case |
|--------------|----------|
| 4-8 | Low concurrency, memory constrained |
| 16-32 | Moderate concurrency (recommended default) |
| 64+ | High concurrency, many concurrent writers |

### Operations Complexity

| Operation | Complexity |
|-----------|------------|
| `subscript` (get/set) | O(1) average |
| `removeValue` | O(1) average |
| `updateValue` | O(1) average |
| `getOrSetValue` | O(1) average |
| `incrementValue` | O(1) average |
| `count` | O(stripes) |
| `isEmpty` | O(stripes) |

### Best Practices

1. **Avoid frequent `count`/`isEmpty` checks** - These acquire all stripe locks sequentially
2. **Choose appropriate stripe count** - Too few causes contention, too many wastes memory
3. **Use `getOrSetValue` for caches** - Provides atomic get-or-insert semantics
4. **Use `incrementValue` for counters** - Atomic increment without race conditions

## License

MIT License
