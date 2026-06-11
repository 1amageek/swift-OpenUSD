import Testing
import OpenUSD

@Suite("CompositionSemantics")
struct CompositionSemanticsTests {

    // MARK: - List operation apply semantics

    @Test(.timeLimit(.minutes(1)))
    func explicitListOperationIgnoresOtherEditLists() {
        let operation = SdfListOperation(
            isExplicit: true,
            explicitItems: ["A", "B", "B"],
            addedItems: ["D"],
            prependedItems: ["C"],
            appendedItems: ["E"],
            deletedItems: ["A"],
            orderedItems: ["B", "A"]
        )

        #expect(operation.applying(to: ["X", "Y"]) == ["A", "B"])
        #expect(operation.effectiveItems == ["A", "B"])
    }

    @Test(.timeLimit(.minutes(1)))
    func addedItemsDoNotMoveExistingItems() {
        let added = SdfListOperation(addedItems: ["B", "D"])
        #expect(added.applying(to: ["A", "B", "C"]) == ["A", "B", "C", "D"])

        let prepended = SdfListOperation(prependedItems: ["C"])
        #expect(prepended.applying(to: ["A", "B", "C"]) == ["C", "A", "B"])

        let appended = SdfListOperation(appendedItems: ["A"])
        #expect(appended.applying(to: ["A", "B", "C"]) == ["B", "C", "A"])
    }

    @Test(.timeLimit(.minutes(1)))
    func editListsApplyInUpstreamOrder() {
        let operation = SdfListOperation(
            addedItems: ["D", "B"],
            prependedItems: ["E"],
            appendedItems: ["C"],
            deletedItems: ["A"]
        )

        #expect(operation.applying(to: ["A", "B", "C"]) == ["E", "B", "D", "C"])
    }

    @Test(.timeLimit(.minutes(1)))
    func orderedItemsMoveRunsBehindPreviouslyMovedRuns() {
        // Each ordered item moves together with the run of unordered items that
        // follow it; items before the first ordered item stay at the front.
        let operation = SdfListOperation(orderedItems: ["D", "B"])
        #expect(operation.applying(to: ["A", "B", "C", "D", "E"]) == ["A", "D", "E", "B", "C"])

        let swap = SdfListOperation(orderedItems: ["C", "B"])
        #expect(swap.applying(to: ["A", "B", "C"]) == ["A", "C", "B"])

        // A single ordered item carries its trailing run, so the list is unchanged.
        let single = SdfListOperation(orderedItems: ["B"])
        #expect(single.applying(to: ["A", "B", "C"]) == ["A", "B", "C"])
    }

    @Test(.timeLimit(.minutes(1)))
    func orderedItemsSkipAbsentItemsAndIgnoreDuplicates() {
        let operation = SdfListOperation(orderedItems: ["Z", "C", "C", "A"])

        #expect(operation.applying(to: ["A", "B", "C"]) == ["C", "A", "B"])
    }

    @Test(.timeLimit(.minutes(1)))
    func orderedItemsApplyAfterOtherEditLists() {
        let operation = SdfListOperation(
            appendedItems: ["D"],
            deletedItems: ["B"],
            orderedItems: ["D", "A"]
        )

        #expect(operation.applying(to: ["A", "B", "C"]) == ["D", "A", "C"])
    }

    // MARK: - Layer offsets

    @Test(.timeLimit(.minutes(1)))
    func sublayerOffsetRemapsTimeSamplesAndTimeCodeMetadata() throws {
        let animLayer = USDALayer(specs: [
            USDLayerSpec(
                path: "/",
                specType: .pseudoRoot,
                fieldNames: ["startTimeCode", "endTimeCode"],
                fields: [
                    "startTimeCode": .authored("1"),
                    "endTimeCode": .authored("2"),
                ]
            ),
            USDLayerSpec(path: "/Rig", specType: .prim, specifier: .def, typeName: "Xform"),
            USDLayerSpec(
                path: "/Rig.points",
                specType: .attribute,
                fieldNames: ["timeSamples"],
                fields: [
                    "timeSamples": .authored("{\n    1: (0, 0, 0),\n    2: (1, 0, 0)\n}"),
                ]
            ),
        ])
        let rootLayer = USDALayer(
            composition: USDLayerComposition(sublayers: [
                USDSublayer(assetPath: "anim.usda", layerOffset: SdfLayerOffset(offset: 10, scale: 2)),
            ]),
            specs: [USDLayerSpec(path: "/", specType: .pseudoRoot)]
        )
        let provider = try makeInMemoryProvider(["anim.usda": animLayer])

        let flattened = try USDStage(rootLayer: rootLayer).flattenedLayer(
            resolvingWith: provider,
            rootIdentifier: "root.usda"
        )

        #expect(flattened.spec(at: "/Rig.points")?.fields["timeSamples"] == .authored(
            "{\n    12: (0, 0, 0),\n    14: (1, 0, 0)\n}"
        ))
        #expect(flattened.spec(at: "/")?.fields["startTimeCode"] == .authored("12"))
        #expect(flattened.spec(at: "/")?.fields["endTimeCode"] == .authored("14"))
    }

    @Test(.timeLimit(.minutes(1)))
    func referenceOffsetRemapsTimeSamplesAcrossTheArc() throws {
        let clipLayer = USDALayer(defaultPrim: "Clip", specs: [
            USDLayerSpec(path: "/", specType: .pseudoRoot),
            USDLayerSpec(path: "/Clip", specType: .prim, specifier: .def, typeName: "Xform"),
            USDLayerSpec(
                path: "/Clip.weight",
                specType: .attribute,
                fieldNames: ["timeSamples"],
                fields: ["timeSamples": .authored("{ 0: 1, 10: 2 }")]
            ),
        ])
        let rootLayer = USDALayer(specs: [
            USDLayerSpec(path: "/", specType: .pseudoRoot),
            USDLayerSpec(
                path: "/Anim",
                specType: .prim,
                specifier: .over,
                fields: [
                    "references": .referenceListOperation(SdfListOperation(prependedItems: [
                        SdfReference(
                            assetPath: "clip.usda",
                            layerOffset: SdfLayerOffset(offset: 5, scale: 2)
                        ),
                    ])),
                ]
            ),
        ])
        let provider = try makeInMemoryProvider(["clip.usda": clipLayer])

        let flattened = try USDStage(rootLayer: rootLayer).flattenedLayer(
            resolvingWith: provider,
            rootIdentifier: "root.usda"
        )

        #expect(flattened.spec(at: "/Anim.weight")?.fields["timeSamples"] == .authored(
            "{\n    5: 1,\n    25: 2\n}"
        ))
    }

    @Test(.timeLimit(.minutes(1)))
    func unparseableTimeSamplesUnderLayerOffsetThrowUnsupportedFeature() throws {
        let animLayer = USDALayer(specs: [
            USDLayerSpec(path: "/", specType: .pseudoRoot),
            USDLayerSpec(path: "/Rig", specType: .prim, specifier: .def, typeName: "Xform"),
            USDLayerSpec(
                path: "/Rig.points",
                specType: .attribute,
                fieldNames: ["timeSamples"],
                fields: ["timeSamples": .authored("not a dictionary")]
            ),
        ])
        let rootLayer = USDALayer(
            composition: USDLayerComposition(sublayers: [
                USDSublayer(assetPath: "anim.usda", layerOffset: SdfLayerOffset(offset: 1, scale: 1)),
            ]),
            specs: [USDLayerSpec(path: "/", specType: .pseudoRoot)]
        )
        let provider = try makeInMemoryProvider(["anim.usda": animLayer])

        do {
            _ = try USDStage(rootLayer: rootLayer).flattenedLayer(
                resolvingWith: provider,
                rootIdentifier: "root.usda"
            )
            Issue.record("Expected an unsupportedFeature error for unparseable timeSamples.")
        } catch let error as USDError {
            guard case .unsupportedFeature = error else {
                Issue.record("Expected unsupportedFeature, got \(error).")
                return
            }
        }
    }

    // MARK: - Arc strength ordering

    @Test(.timeLimit(.minutes(1)))
    func directReferenceIsStrongerThanAncestralReference() throws {
        let parentLayer = USDALayer(defaultPrim: "Model", specs: [
            USDLayerSpec(path: "/", specType: .pseudoRoot),
            USDLayerSpec(path: "/Model", specType: .prim, specifier: .def, typeName: "Xform"),
            USDLayerSpec(
                path: "/Model/Child",
                specType: .prim,
                specifier: .def,
                typeName: "Sphere",
                fields: ["displayName": .authored("\"ancestral\"")]
            ),
        ])
        let childLayer = USDALayer(defaultPrim: "Child", specs: [
            USDLayerSpec(path: "/", specType: .pseudoRoot),
            USDLayerSpec(
                path: "/Child",
                specType: .prim,
                specifier: .over,
                fields: ["displayName": .authored("\"direct\"")]
            ),
        ])
        let rootLayer = USDALayer(specs: [
            USDLayerSpec(path: "/", specType: .pseudoRoot),
            USDLayerSpec(
                path: "/Parent",
                specType: .prim,
                specifier: .over,
                fields: [
                    "references": .referenceListOperation(SdfListOperation(prependedItems: [
                        SdfReference(assetPath: "parent.usda"),
                    ])),
                ]
            ),
            USDLayerSpec(
                path: "/Parent/Child",
                specType: .prim,
                specifier: .over,
                fields: [
                    "references": .referenceListOperation(SdfListOperation(prependedItems: [
                        SdfReference(assetPath: "child.usda"),
                    ])),
                ]
            ),
        ])
        let provider = try makeInMemoryProvider([
            "parent.usda": parentLayer,
            "child.usda": childLayer,
        ])

        let flattened = try USDStage(rootLayer: rootLayer).flattenedLayer(
            resolvingWith: provider,
            rootIdentifier: "root.usda"
        )

        #expect(flattened.spec(at: "/Parent/Child")?.fields["displayName"] == .authored("\"direct\""))
        #expect(flattened.spec(at: "/Parent/Child")?.typeName == "Sphere")
    }

    // MARK: - Layer metadata across arcs and sublayers

    @Test(.timeLimit(.minutes(1)))
    func referencedLayerMetadataDoesNotLeakIntoFlattenedRoot() throws {
        let modelLayer = USDALayer(
            defaultPrim: "Model",
            metersPerUnit: 0.01,
            upAxis: .z,
            specs: [
                USDLayerSpec(
                    path: "/",
                    specType: .pseudoRoot,
                    fieldNames: ["defaultPrim", "metersPerUnit", "upAxis"],
                    fields: [
                        "defaultPrim": .authored("\"Model\""),
                        "metersPerUnit": .authored("0.01"),
                        "upAxis": .authored("\"Z\""),
                    ]
                ),
                USDLayerSpec(path: "/Model", specType: .prim, specifier: .def, typeName: "Xform"),
            ]
        )
        let rootLayer = USDALayer(specs: [
            USDLayerSpec(path: "/", specType: .pseudoRoot),
            USDLayerSpec(
                path: "/Thing",
                specType: .prim,
                specifier: .over,
                fields: [
                    "references": .referenceListOperation(SdfListOperation(prependedItems: [
                        SdfReference(assetPath: "model.usda"),
                    ])),
                ]
            ),
        ])
        let provider = try makeInMemoryProvider(["model.usda": modelLayer])

        let flattened = try USDStage(rootLayer: rootLayer).flattenedLayer(
            resolvingWith: provider,
            rootIdentifier: "root.usda"
        )

        #expect(flattened.spec(at: "/Thing")?.typeName == "Xform")
        #expect(flattened.defaultPrim == nil)
        #expect(flattened.metersPerUnit == nil)
        #expect(flattened.upAxis == nil)
        #expect(flattened.spec(at: "/")?.fields["defaultPrim"] == nil)
        #expect(flattened.spec(at: "/")?.fields["metersPerUnit"] == nil)
        #expect(flattened.spec(at: "/")?.fields["upAxis"] == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func sublayerDefaultPrimDoesNotLeakIntoFlattenedRoot() throws {
        let sublayer = USDALayer(defaultPrim: "Sub", specs: [
            USDLayerSpec(
                path: "/",
                specType: .pseudoRoot,
                fieldNames: ["defaultPrim"],
                fields: ["defaultPrim": .authored("\"Sub\"")]
            ),
            USDLayerSpec(path: "/Sub", specType: .prim, specifier: .def, typeName: "Xform"),
        ])
        let rootLayer = USDALayer(
            defaultPrim: "Root",
            composition: USDLayerComposition(sublayers: [USDSublayer(assetPath: "sub.usda")]),
            specs: [
                USDLayerSpec(path: "/", specType: .pseudoRoot),
                USDLayerSpec(path: "/Root", specType: .prim, specifier: .def, typeName: "Xform"),
            ]
        )
        let provider = try makeInMemoryProvider(["sub.usda": sublayer])

        let flattened = try USDStage(rootLayer: rootLayer).flattenedLayer(
            resolvingWith: provider,
            rootIdentifier: "root.usda"
        )

        #expect(flattened.defaultPrim == "Root")
        #expect(flattened.spec(at: "/")?.fields["defaultPrim"] == nil)
        #expect(flattened.spec(at: "/Sub")?.typeName == "Xform")
    }

    @Test(.timeLimit(.minutes(1)))
    func referenceToLayerWithDefaultPrimOnlyInSublayerThrows() throws {
        let baseLayer = USDALayer(defaultPrim: "Model", specs: [
            USDLayerSpec(path: "/", specType: .pseudoRoot),
            USDLayerSpec(path: "/Model", specType: .prim, specifier: .def, typeName: "Xform"),
        ])
        let modelLayer = USDALayer(
            composition: USDLayerComposition(sublayers: [USDSublayer(assetPath: "base.usda")]),
            specs: [USDLayerSpec(path: "/", specType: .pseudoRoot)]
        )
        let rootLayer = USDALayer(specs: [
            USDLayerSpec(path: "/", specType: .pseudoRoot),
            USDLayerSpec(
                path: "/Thing",
                specType: .prim,
                specifier: .over,
                fields: [
                    "references": .referenceListOperation(SdfListOperation(prependedItems: [
                        SdfReference(assetPath: "model.usda"),
                    ])),
                ]
            ),
        ])
        let provider = try makeInMemoryProvider([
            "model.usda": modelLayer,
            "base.usda": baseLayer,
        ])

        #expect(throws: USDError.self) {
            _ = try USDStage(rootLayer: rootLayer).flattenedLayer(
                resolvingWith: provider,
                rootIdentifier: "root.usda"
            )
        }
    }

    // MARK: - Path mapping across arcs

    @Test(.timeLimit(.minutes(1)))
    func unmappableRelationshipTargetIsDropped() throws {
        let modelLayer = USDALayer(defaultPrim: "Model", specs: [
            USDLayerSpec(path: "/", specType: .pseudoRoot),
            USDLayerSpec(path: "/Model", specType: .prim, specifier: .def, typeName: "Xform"),
            USDLayerSpec(path: "/Model/Geom", specType: .prim, specifier: .def, typeName: "Mesh"),
            USDLayerSpec(
                path: "/Model.proxy",
                specType: .relationship,
                fieldNames: ["targetPaths"],
                fields: [
                    "targetPaths": .pathListOperation(SdfListOperation(prependedItems: [
                        "/Model/Geom",
                        "/Outside",
                    ])),
                ]
            ),
        ])
        let rootLayer = USDALayer(specs: [
            USDLayerSpec(path: "/", specType: .pseudoRoot),
            USDLayerSpec(
                path: "/Thing",
                specType: .prim,
                specifier: .over,
                fields: [
                    "references": .referenceListOperation(SdfListOperation(prependedItems: [
                        SdfReference(assetPath: "model.usda"),
                    ])),
                ]
            ),
        ])
        let provider = try makeInMemoryProvider(["model.usda": modelLayer])

        let flattened = try USDStage(rootLayer: rootLayer).flattenedLayer(
            resolvingWith: provider,
            rootIdentifier: "root.usda"
        )

        #expect(flattened.spec(at: "/Thing.proxy")?.fields["targetPaths"] == .pathListOperation(
            SdfListOperation(prependedItems: ["/Thing/Geom"])
        ))
    }

    // MARK: - Field merging across the layer stack

    @Test(.timeLimit(.minutes(1)))
    func dictionaryFieldsMergeRecursivelyAcrossLayerStack() throws {
        let weakLayer = USDALayer(specs: [
            USDLayerSpec(path: "/", specType: .pseudoRoot),
            USDLayerSpec(
                path: "/Prim",
                specType: .prim,
                specifier: .def,
                fields: [
                    "customData": .dictionary([
                        "a": .string("weak"),
                        "nested": .dictionary([
                            "x": .string("weak"),
                            "y": .string("weakOnly"),
                        ]),
                    ]),
                ]
            ),
        ])
        let strongLayer = USDALayer(specs: [
            USDLayerSpec(path: "/", specType: .pseudoRoot),
            USDLayerSpec(
                path: "/Prim",
                specType: .prim,
                specifier: .over,
                fields: [
                    "customData": .dictionary([
                        "a": .string("strong"),
                        "b": .string("strongOnly"),
                        "nested": .dictionary(["x": .string("strong")]),
                    ]),
                ]
            ),
        ])
        let rootLayer = USDALayer(
            composition: USDLayerComposition(sublayers: [
                USDSublayer(assetPath: "strong.usda"),
                USDSublayer(assetPath: "weak.usda"),
            ]),
            specs: [USDLayerSpec(path: "/", specType: .pseudoRoot)]
        )
        let provider = try makeInMemoryProvider([
            "strong.usda": strongLayer,
            "weak.usda": weakLayer,
        ])

        let flattened = try USDStage(rootLayer: rootLayer).flattenedLayer(
            resolvingWith: provider,
            rootIdentifier: "root.usda"
        )

        #expect(flattened.spec(at: "/Prim")?.fields["customData"] == .dictionary([
            "a": .string("strong"),
            "b": .string("strongOnly"),
            "nested": .dictionary([
                "x": .string("strong"),
                "y": .string("weakOnly"),
            ]),
        ]))
    }

    @Test(.timeLimit(.minutes(1)))
    func tokenListOperationFieldsComposeAcrossLayerStack() throws {
        let weakLayer = USDALayer(specs: [
            USDLayerSpec(path: "/", specType: .pseudoRoot),
            USDLayerSpec(
                path: "/Prim",
                specType: .prim,
                specifier: .def,
                fields: [
                    "apiSchemas": .tokenListOperation(SdfListOperation(prependedItems: ["WeakAPI"])),
                ]
            ),
        ])
        let strongLayer = USDALayer(specs: [
            USDLayerSpec(path: "/", specType: .pseudoRoot),
            USDLayerSpec(
                path: "/Prim",
                specType: .prim,
                specifier: .over,
                fields: [
                    "apiSchemas": .tokenListOperation(SdfListOperation(prependedItems: ["StrongAPI"])),
                ]
            ),
        ])
        let rootLayer = USDALayer(
            composition: USDLayerComposition(sublayers: [
                USDSublayer(assetPath: "strong.usda"),
                USDSublayer(assetPath: "weak.usda"),
            ]),
            specs: [USDLayerSpec(path: "/", specType: .pseudoRoot)]
        )
        let provider = try makeInMemoryProvider([
            "strong.usda": strongLayer,
            "weak.usda": weakLayer,
        ])

        let flattened = try USDStage(rootLayer: rootLayer).flattenedLayer(
            resolvingWith: provider,
            rootIdentifier: "root.usda"
        )

        #expect(flattened.spec(at: "/Prim")?.fields["apiSchemas"] == .tokenListOperation(
            SdfListOperation(prependedItems: ["StrongAPI", "WeakAPI"])
        ))
    }

    @Test(.timeLimit(.minutes(1)))
    func listOperationCompositionWithAddedItemsThrowsUnsupportedFeature() throws {
        let weakLayer = USDALayer(specs: [
            USDLayerSpec(path: "/", specType: .pseudoRoot),
            USDLayerSpec(
                path: "/Prim",
                specType: .prim,
                specifier: .def,
                fields: [
                    "apiSchemas": .tokenListOperation(SdfListOperation(addedItems: ["WeakAPI"])),
                ]
            ),
        ])
        let strongLayer = USDALayer(specs: [
            USDLayerSpec(path: "/", specType: .pseudoRoot),
            USDLayerSpec(
                path: "/Prim",
                specType: .prim,
                specifier: .over,
                fields: [
                    "apiSchemas": .tokenListOperation(SdfListOperation(deletedItems: ["Other"])),
                ]
            ),
        ])
        let rootLayer = USDALayer(
            composition: USDLayerComposition(sublayers: [
                USDSublayer(assetPath: "strong.usda"),
                USDSublayer(assetPath: "weak.usda"),
            ]),
            specs: [USDLayerSpec(path: "/", specType: .pseudoRoot)]
        )
        let provider = try makeInMemoryProvider([
            "strong.usda": strongLayer,
            "weak.usda": weakLayer,
        ])

        do {
            _ = try USDStage(rootLayer: rootLayer).flattenedLayer(
                resolvingWith: provider,
                rootIdentifier: "root.usda"
            )
            Issue.record("Expected an unsupportedFeature error for list-op composition with added items.")
        } catch let error as USDError {
            guard case .unsupportedFeature = error else {
                Issue.record("Expected unsupportedFeature, got \(error).")
                return
            }
        }
    }

    // MARK: - Cycle detection

    @Test(.timeLimit(.minutes(1)))
    func referenceCycleDetectionStillThrows() throws {
        let layerA = USDALayer(defaultPrim: "A", specs: [
            USDLayerSpec(path: "/", specType: .pseudoRoot),
            USDLayerSpec(
                path: "/A",
                specType: .prim,
                specifier: .def,
                fields: [
                    "references": .referenceListOperation(SdfListOperation(prependedItems: [
                        SdfReference(assetPath: "b.usda"),
                    ])),
                ]
            ),
        ])
        let layerB = USDALayer(defaultPrim: "B", specs: [
            USDLayerSpec(path: "/", specType: .pseudoRoot),
            USDLayerSpec(
                path: "/B",
                specType: .prim,
                specifier: .def,
                fields: [
                    "references": .referenceListOperation(SdfListOperation(prependedItems: [
                        SdfReference(assetPath: "a.usda"),
                    ])),
                ]
            ),
        ])
        let rootLayer = USDALayer(specs: [
            USDLayerSpec(path: "/", specType: .pseudoRoot),
            USDLayerSpec(
                path: "/Thing",
                specType: .prim,
                specifier: .over,
                fields: [
                    "references": .referenceListOperation(SdfListOperation(prependedItems: [
                        SdfReference(assetPath: "a.usda"),
                    ])),
                ]
            ),
        ])
        let provider = try makeInMemoryProvider([
            "a.usda": layerA,
            "b.usda": layerB,
        ])

        #expect(throws: USDError.self) {
            _ = try USDStage(rootLayer: rootLayer).flattenedLayer(
                resolvingWith: provider,
                rootIdentifier: "root.usda"
            )
        }
    }
}
