// Minimal binary min-heap, hand-rolled on purpose (docs/PORT.md): the
// Python engine uses heapq, and planner determinism leans on min-heap
// semantics with fully ordered elements. Any correct min-heap pops the
// unique global minimum, so matching Python only requires that element
// comparison match Python's tuple ordering — each element type defines
// that via Comparable.
struct BinaryHeap<Element: Comparable> {
    private var storage: [Element] = []

    var isEmpty: Bool { storage.isEmpty }
    var count: Int { storage.count }
    var min: Element? { storage.first }

    init() {}

    init(_ elements: [Element]) {
        storage = elements
        guard storage.count > 1 else { return }
        for i in stride(from: storage.count / 2 - 1, through: 0, by: -1) {
            siftDown(i)
        }
    }

    mutating func push(_ e: Element) {
        storage.append(e)
        var i = storage.count - 1
        while i > 0 {
            let parent = (i - 1) / 2
            if storage[i] < storage[parent] {
                storage.swapAt(i, parent)
                i = parent
            } else {
                break
            }
        }
    }

    mutating func pop() -> Element? {
        guard let first = storage.first else { return nil }
        storage[0] = storage[storage.count - 1]
        storage.removeLast()
        if !storage.isEmpty {
            siftDown(0)
        }
        return first
    }

    private mutating func siftDown(_ start: Int) {
        var i = start
        while true {
            let l = 2 * i + 1
            let r = l + 1
            var smallest = i
            if l < storage.count, storage[l] < storage[smallest] { smallest = l }
            if r < storage.count, storage[r] < storage[smallest] { smallest = r }
            if smallest == i { return }
            storage.swapAt(i, smallest)
            i = smallest
        }
    }
}
