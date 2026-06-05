public struct USDCListOp<Item: Sendable & Equatable>: Sendable, Equatable {
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
}
