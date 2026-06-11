public struct SdfListOperation<Item: Sendable & Equatable & Hashable>: Sendable, Equatable, Hashable {
    public var isExplicit: Bool
    public var explicitItems: [Item]
    public var addedItems: [Item]
    public var prependedItems: [Item]
    public var appendedItems: [Item]
    public var deletedItems: [Item]
    public var orderedItems: [Item]

    public init(
        isExplicit: Bool = false,
        explicitItems: [Item] = [],
        addedItems: [Item] = [],
        prependedItems: [Item] = [],
        appendedItems: [Item] = [],
        deletedItems: [Item] = [],
        orderedItems: [Item] = []
    ) {
        self.isExplicit = isExplicit
        self.explicitItems = explicitItems
        self.addedItems = addedItems
        self.prependedItems = prependedItems
        self.appendedItems = appendedItems
        self.deletedItems = deletedItems
        self.orderedItems = orderedItems
    }

    public var isEmpty: Bool {
        !isExplicit
            && explicitItems.isEmpty
            && addedItems.isEmpty
            && prependedItems.isEmpty
            && appendedItems.isEmpty
            && deletedItems.isEmpty
            && orderedItems.isEmpty
    }

    public var effectiveItems: [Item] {
        applying(to: [])
    }

    /// Returns an operation with every item transformed by `transform`,
    /// preserving the explicit flag and each edit list.
    public func mapItems<Transformed: Sendable & Equatable & Hashable>(
        _ transform: (Item) throws -> Transformed
    ) rethrows -> SdfListOperation<Transformed> {
        SdfListOperation<Transformed>(
            isExplicit: isExplicit,
            explicitItems: try explicitItems.map(transform),
            addedItems: try addedItems.map(transform),
            prependedItems: try prependedItems.map(transform),
            appendedItems: try appendedItems.map(transform),
            deletedItems: try deletedItems.map(transform),
            orderedItems: try orderedItems.map(transform)
        )
    }

    /// Applies the operation to `baseItems` following upstream `SdfListOp` semantics.
    ///
    /// When the operation is explicit, the result is exactly the explicit item list and
    /// every other edit list is ignored. Otherwise edits apply in order: deleted, added,
    /// prepended, appended, ordered. Added items never move an item that is already
    /// present, while prepended and appended items reposition existing items to the
    /// front or back of the list respectively.
    public func applying(to baseItems: [Item]) -> [Item] {
        if isExplicit {
            return Self.uniqueItems(explicitItems)
        }
        var items: [Item] = []
        var presentItems: Set<Item> = []
        for item in baseItems where presentItems.insert(item).inserted {
            items.append(item)
        }
        if !deletedItems.isEmpty {
            let deleted = Set(deletedItems)
            items.removeAll { deleted.contains($0) }
            presentItems.subtract(deleted)
        }
        for item in addedItems where presentItems.insert(item).inserted {
            items.append(item)
        }
        if !prependedItems.isEmpty {
            let prepended = Self.uniqueItems(prependedItems)
            let prependedSet = Set(prepended)
            items.removeAll { prependedSet.contains($0) }
            items = prepended + items
            presentItems.formUnion(prependedSet)
        }
        if !appendedItems.isEmpty {
            let appended = Self.uniqueItems(appendedItems)
            let appendedSet = Set(appended)
            items.removeAll { appendedSet.contains($0) }
            items.append(contentsOf: appended)
            presentItems.formUnion(appendedSet)
        }
        guard !orderedItems.isEmpty else {
            return items
        }
        return Self.reordered(items, by: orderedItems)
    }

    /// Reorders `items` following upstream `SdfListOp` ordered-item semantics.
    ///
    /// Each ordered item that is present in the list moves, together with the run of
    /// unordered items that immediately follow it, behind the previously moved runs.
    /// Items that precede the first ordered item keep their relative order at the front.
    static func reordered(_ items: [Item], by orderedItems: [Item]) -> [Item] {
        let uniqueOrder = uniqueItems(orderedItems)
        let orderedSet = Set(uniqueOrder)
        var scratch = items
        var reorderedRuns: [Item] = []
        for orderedItem in uniqueOrder {
            guard let startIndex = scratch.firstIndex(of: orderedItem) else {
                continue
            }
            var endIndex = scratch.count
            for index in (startIndex + 1)..<scratch.count where orderedSet.contains(scratch[index]) {
                endIndex = index
                break
            }
            reorderedRuns.append(contentsOf: scratch[startIndex..<endIndex])
            scratch.removeSubrange(startIndex..<endIndex)
        }
        return scratch + reorderedRuns
    }

    /// Removes duplicate items while preserving the position of each first occurrence.
    static func uniqueItems(_ items: [Item]) -> [Item] {
        var seenItems: Set<Item> = []
        var result: [Item] = []
        for item in items where seenItems.insert(item).inserted {
            result.append(item)
        }
        return result
    }
}
