import Synchronization
import XXH3

/// A thread-safe dictionary that supports concurrent read and write access from multiple threads.
///
/// `ConcurrentDictionary` uses a striped locking strategy to minimize contention and maximize
/// throughput in highly concurrent scenarios. Instead of using a single lock for the entire
/// dictionary, it partitions keys across multiple independent buckets (stripes), each protected
/// by its own mutex. This allows operations on different stripes to proceed in parallel.
///
/// The number of stripes is specified at compile time via the `count` generic parameter.
/// A higher stripe count reduces contention but increases memory overhead. Common values
/// range from 8 to 64, depending on expected concurrency levels.
///
/// ## Topics
///
/// ### Creating a Dictionary
/// - ``init()``
///
/// ### Accessing Values
/// - ``subscript(key:)``
/// - ``subscript(key:default:)``
///
/// ### Adding and Updating Values
/// - ``updateValue(_:forKey:)``
/// - ``getOrSetValue(_:forKey:)``
///
/// ### Removing Values
/// - ``removeValue(forKey:)``
///
/// ### Inspecting the Dictionary
/// - ``count``
/// - ``isEmpty``
///
/// ## Example Usage
///
/// ```swift
/// // Create a concurrent dictionary with 16 stripes
/// let cache = ConcurrentDictionary<16, String, Data>()
///
/// // Access from multiple concurrent tasks
/// await withTaskGroup(of: Void.self) { group in
///     for i in 0..<1000 {
///         group.addTask {
///             cache["key-\(i)"] = Data()
///         }
///     }
/// }
/// ```
///
/// ## Performance Considerations
///
/// - **Stripe Count**: Choose a stripe count that balances memory usage with expected concurrency.
///   Too few stripes may cause contention; too many wastes memory.
/// - **Hash Distribution**: Keys are distributed across stripes using XXH3 hashing, which provides
///   excellent distribution characteristics.
/// - **Count/isEmpty**: These properties must acquire all stripe locks and should be used sparingly
///   in performance-critical code.
///
/// - Note: The `count` generic parameter must be a positive integer known at compile time.
///
/// - Important: While individual operations are atomic, compound operations (read-then-write)
///   are not automatically atomic. Use ``getOrSetValue(_:forKey:)`` for atomic get-or-set semantics.
public final class ConcurrentDictionary<let count: Int, Key: Hashable, Value: Sendable>: Sendable {

    /// The array of mutex-protected dictionary stripes.
    ///
    /// Each stripe contains a portion of the key-value pairs, distributed by hash.
    /// Using `InlineArray` ensures the stripes are stored contiguously in memory.
    private let stripes: InlineArray<count, Mutex<[Key: Value]>>

    /// The stripe count as an unsigned integer for efficient modulo operations during hashing.
    private let unsignedCount: UInt64

    /// Creates an empty concurrent dictionary.
    ///
    /// Initializes all stripes with empty dictionaries. The stripe count is determined
    /// by the `count` generic parameter specified at the type level.
    ///
    /// - Complexity: O(*n*), where *n* is the stripe count.
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Create a dictionary with 8 stripes for moderate concurrency
    /// let dict = ConcurrentDictionary<8, String, Int>()
    ///
    /// // Create a dictionary with 64 stripes for high concurrency
    /// let highConcurrencyDict = ConcurrentDictionary<64, URL, Response>()
    /// ```
    public init() {
        self.unsignedCount = .init(count)
        self.stripes = .init { _ in .init([:]) }
    }

    /// Performs a mutation on the stripe containing the given key.
    ///
    /// This method handles the stripe selection and locking logic used by all public operations.
    /// It computes the XXH3 hash of the key, determines the appropriate stripe index, and
    /// executes the provided closure while holding the stripe's lock.
    ///
    /// - Parameters:
    ///   - key: The key used to determine which stripe to lock.
    ///   - body: A closure that receives an `inout` reference to the stripe's dictionary.
    ///           The closure can read or modify the dictionary and return a value.
    ///
    /// - Returns: The value returned by the `body` closure.
    ///
    /// - Throws: Rethrows any error thrown by the `body` closure.
    ///
    /// - Complexity: O(1) for stripe selection, plus the complexity of the `body` closure.
    fileprivate func mutate<T: Sendable>(
        forKey key: Key,
        _ body: (inout [Key: Value]) throws -> T
    ) rethrows -> T {
        let hash = XXH3.hash(key)
        let index = Int(hash % unsignedCount)
        return try stripes[unchecked: index].withLock { dict in
            try body(&dict)
        }
    }

    /// Performs a mutation on all stripes in the dictionary.
    ///
    /// This method executes the provided closure on each stripe's dictionary sequentially,
    /// acquiring the stripe locks one at a time.
    ///
    /// This method is used internally by operations that need to access or modify all stripes,
    /// such as ``count``, ``isEmpty``, and ``removeAll(keepingCapacity:)``.
    ///
    /// - Parameter body: A closure that receives an `inout` reference to each stripe's dictionary
    ///                   in sequence. The closure can read or modify the dictionary.
    ///
    /// - Throws: Rethrows any error thrown by the `body` closure.
    ///
    /// - Complexity: O(*s*), where *s* is the stripe count, plus the complexity of executing
    ///   the `body` closure *s* times.
    fileprivate func mutateAll(
        _ body: (inout [Key: Value]) throws -> Void
    ) rethrows {
        for index in 0..<count {
            try stripes[unchecked: index].withLock { dict in
                try body(&dict)
            }
        }
    }

    /// Accesses the value associated with the given key for reading and writing.
    ///
    /// Use this subscript to get or set values in the dictionary. When reading, returns `nil`
    /// if the key is not present. When writing `nil`, removes the key from the dictionary.
    ///
    /// - Parameter key: The key to look up or modify.
    ///
    /// - Returns: The value associated with `key`, or `nil` if the key is not present.
    ///
    /// - Complexity: O(1) average for both get and set operations.
    ///
    /// ## Example
    ///
    /// ```swift
    /// let cache = ConcurrentDictionary<16, String, Int>()
    ///
    /// // Set a value
    /// cache["answer"] = 42
    ///
    /// // Get a value
    /// if let value = cache["answer"] {
    ///     print("Found: \(value)")
    /// }
    ///
    /// // Remove a value by setting to nil
    /// cache["answer"] = nil
    /// ```
    public subscript(key: Key) -> Value? {
        get {
            mutate(forKey: key) {
                $0[key]
            }
        }
        set {
            mutate(forKey: key) {
                $0[key] = newValue
            }
        }
    }

    /// Accesses the value associated with the given key, returning a default if the key is not present.
    ///
    /// Use this subscript when you want to ensure a value is always returned. If the key exists,
    /// its associated value is returned. If not, the `defaultValue` is evaluated and returned
    /// (but not stored in the dictionary).
    ///
    /// - Parameters:
    ///   - key: The key to look up.
    ///   - defaultValue: An autoclosure that provides a default value when `key` is not found.
    ///                   The closure is only evaluated if the key is absent.
    ///
    /// - Returns: The value associated with `key`, or `defaultValue()` if the key is not present.
    ///
    /// - Complexity: O(1) average.
    ///
    /// - Note: Unlike ``getOrSetValue(_:forKey:)``, this subscript does **not** store the default
    ///   value in the dictionary when reading. Use `getOrSetValue` for atomic get-or-insert semantics.
    ///
    /// ## Example
    ///
    /// ```swift
    /// let scores = ConcurrentDictionary<8, String, Int>()
    ///
    /// // Returns 0 if "player1" doesn't exist (but doesn't store it)
    /// let score = scores["player1", default: 0]
    ///
    /// // Set using the default subscript
    /// scores["player1", default: 0] = 100
    /// ```
    public subscript(key: Key, default defaultValue: @autoclosure () -> Value) -> Value {
        get {
            mutate(forKey: key) {
                $0[key] ?? defaultValue()
            }
        }
        set {
            mutate(forKey: key) {
                $0[key] = newValue
            }
        }
    }

    /// Removes the value associated with the given key.
    ///
    /// This method removes the key-value pair from the dictionary if it exists and returns
    /// the removed value. If the key is not present, the dictionary remains unchanged and
    /// `nil` is returned.
    ///
    /// - Parameter key: The key to remove.
    ///
    /// - Returns: The value that was removed, or `nil` if the key was not present.
    ///
    /// - Complexity: O(1) average.
    ///
    /// ## Example
    ///
    /// ```swift
    /// let cache = ConcurrentDictionary<16, String, Data>()
    /// cache["image"] = imageData
    ///
    /// // Remove and get the old value
    /// if let removed = cache.removeValue(forKey: "image") {
    ///     print("Removed \(removed.count) bytes")
    /// }
    ///
    /// // Removing a non-existent key returns nil
    /// let nothing = cache.removeValue(forKey: "nonexistent") // nil
    /// ```
    @discardableResult
    public func removeValue(forKey key: Key) -> Value? {
        mutate(forKey: key) {
            $0.removeValue(forKey: key)
        }
    }

    /// Removes all key-value pairs from the dictionary.
    ///
    /// This method removes all elements from every stripe in the dictionary. Each stripe
    /// is locked individually during the removal operation, and the locks are acquired
    /// sequentially across all stripes.
    ///
    /// - Parameter keepCapacity: If `true`, the dictionary's underlying storage capacity
    ///   is preserved. If `false`, the underlying storage is released. The default is `false`.
    ///
    /// - Complexity: O(*s*), where *s* is the stripe count. Each stripe lock must be acquired
    ///   sequentially to clear its contents.
    ///
    /// ## Example
    ///
    /// ```swift
    /// let cache = ConcurrentDictionary<16, String, Data>()
    /// cache["key1"] = Data()
    /// cache["key2"] = Data()
    ///
    /// // Remove all entries and release memory
    /// cache.removeAll()
    ///
    /// // Remove all entries but keep capacity for reuse
    /// cache.removeAll(keepingCapacity: true)
    /// ```
    public func removeAll(keepingCapacity keepCapacity: Bool = false) {
        mutateAll {
            $0.removeAll(keepingCapacity: keepCapacity)
        }
    }

    /// Updates the value stored in the dictionary for the given key, or adds a new key-value pair.
    ///
    /// This method inserts or updates a value for the specified key. If the key already exists,
    /// the old value is replaced and returned. If the key is new, the value is inserted and
    /// `nil` is returned.
    ///
    /// - Parameters:
    ///   - value: The new value to store.
    ///   - key: The key to associate with `value`.
    ///
    /// - Returns: The old value that was replaced, or `nil` if the key was newly inserted.
    ///
    /// - Complexity: O(1) average.
    ///
    /// ## Example
    ///
    /// ```swift
    /// let settings = ConcurrentDictionary<8, String, String>()
    ///
    /// // Insert a new key (returns nil)
    /// let old1 = settings.updateValue("dark", forKey: "theme") // nil
    ///
    /// // Update existing key (returns old value)
    /// let old2 = settings.updateValue("light", forKey: "theme") // "dark"
    /// ```
    @discardableResult
    public func updateValue(_ value: Value, forKey key: Key) -> Value? {
        mutate(forKey: key) {
            $0.updateValue(value, forKey: key)
        }
    }

    /// Returns the existing value for a key, or inserts and returns a new value if the key is absent.
    ///
    /// This method provides atomic get-or-insert semantics. If the key exists, its value is returned
    /// without modification. If the key is absent, the provided value is inserted and then returned.
    /// The entire operation is performed atomically within a single lock acquisition.
    ///
    /// This is particularly useful for implementing caches or memoization where you want to avoid
    /// duplicate work when multiple threads request the same key simultaneously.
    ///
    /// - Parameters:
    ///   - value: The value to insert if the key is not already present.
    ///   - key: The key to look up or insert.
    ///
    /// - Returns: The existing value if present, otherwise the newly inserted `value`.
    ///
    /// - Complexity: O(1) average.
    ///
    /// - Important: The `value` parameter is always evaluated, even if the key exists.
    ///   If computing the value is expensive, consider using a lazy initialization pattern.
    ///
    /// ## Example
    ///
    /// ```swift
    /// let cache = ConcurrentDictionary<16, URL, Data>()
    ///
    /// // Multiple concurrent calls for the same key will only insert once
    /// let data = cache.getOrSetValue(expensiveComputation(), forKey: url)
    ///
    /// // Implementing a simple cache pattern
    /// func getCachedData(for url: URL) -> Data {
    ///     cache.getOrSetValue(fetchData(from: url), forKey: url)
    /// }
    /// ```
    public func getOrSetValue(_ value: @autoclosure () -> Value, forKey key: Key) -> Value {
        mutate(forKey: key) {
            if let existingValue = $0[key] {
                return existingValue
            }
            let newValue = value()
            $0[key] = newValue
            return newValue
        }
    }

    /// The total number of key-value pairs in the dictionary.
    ///
    /// This property iterates through all stripes and sums their counts. Each stripe must be
    /// locked during the count operation, making this an expensive operation that should be
    /// used sparingly in performance-critical code.
    ///
    /// - Complexity: O(*s*), where *s* is the stripe count. Each stripe lock must be acquired
    ///   sequentially.
    ///
    /// - Warning: The returned count represents a snapshot and may be stale immediately after
    ///   returning if other threads are concurrently modifying the dictionary.
    ///
    /// ## Example
    ///
    /// ```swift
    /// let dict = ConcurrentDictionary<8, String, Int>()
    /// dict["a"] = 1
    /// dict["b"] = 2
    /// print(dict.count) // 2
    /// ```
    public var count: Int {
        var count = 0
        mutateAll {
            count += $0.count
        }
        return count
    }

    /// A Boolean value indicating whether the dictionary is empty.
    ///
    /// This property checks whether the total count of elements is zero. Like ``count``,
    /// it requires acquiring all stripe locks and should be used sparingly.
    ///
    /// - Complexity: O(*s*), where *s* is the stripe count.
    ///
    /// ## Example
    ///
    /// ```swift
    /// let dict = ConcurrentDictionary<8, String, Int>()
    /// print(dict.isEmpty) // true
    ///
    /// dict["key"] = 42
    /// print(dict.isEmpty) // false
    /// ```
    public var isEmpty: Bool {
        var isEmpty = true
        mutateAll {
            isEmpty = isEmpty && $0.isEmpty
        }
        return isEmpty
    }
}

// MARK: - Numeric Extensions

extension ConcurrentDictionary where Value: Numeric {

    /// Atomically increments the value for a key by the specified amount.
    ///
    /// This method provides atomic increment semantics for numeric values. If the key exists,
    /// its value is incremented by `amount`. If the key is absent, it is initialized to `amount`
    /// (treating the missing value as zero).
    ///
    /// The entire read-modify-write operation is performed atomically within a single lock
    /// acquisition, preventing race conditions in concurrent counter scenarios.
    ///
    /// - Parameters:
    ///   - key: The key whose value should be incremented.
    ///   - amount: The amount to add to the current value. Can be negative for decrementing.
    ///
    /// - Returns: The new value after incrementing.
    ///
    /// - Complexity: O(1) average.
    ///
    /// ## Example
    ///
    /// ```swift
    /// let counters = ConcurrentDictionary<8, String, Int>()
    ///
    /// // Increment a new key (starts at 0, becomes 1)
    /// let count1 = counters.incrementValue(forKey: "visits", by: 1) // 1
    ///
    /// // Increment again
    /// let count2 = counters.incrementValue(forKey: "visits", by: 1) // 2
    ///
    /// // Decrement using negative amount
    /// let count3 = counters.incrementValue(forKey: "visits", by: -1) // 1
    ///
    /// // Works with any Numeric type
    /// let floatCounters = ConcurrentDictionary<8, String, Double>()
    /// floatCounters.incrementValue(forKey: "total", by: 3.14)
    /// ```
    @discardableResult
    public func incrementValue(forKey key: Key, by amount: Value) -> Value {
        mutate(forKey: key) {
            let currentValue = $0[key, default: 0]
            let newValue = currentValue + amount
            $0[key] = newValue
            return newValue
        }
    }
}

extension ConcurrentDictionary: ExpressibleByDictionaryLiteral {

    /// Creates a concurrent dictionary from a dictionary literal.
    ///
    /// This initializer allows you to create a `ConcurrentDictionary` using
    /// standard dictionary literal syntax.
    ///
    /// - Parameter elements: A variadic list of key-value pairs to initialize the dictionary.
    ///
    /// - Complexity: O(*n*), where *n* is the number of elements in the literal.
    ///
    /// ## Example
    ///
    /// ```swift
    /// let dict: ConcurrentDictionary<8, String, Int> = [
    ///     "one": 1,
    ///     "two": 2,
    ///     "three": 3
    /// ]
    /// ```
    public convenience init(dictionaryLiteral elements: (Key, Value)...) {
        self.init()
        for (key, value) in elements {
            self[key] = value
        }
    }
}
