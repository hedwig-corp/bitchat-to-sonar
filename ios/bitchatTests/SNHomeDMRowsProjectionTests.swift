import Testing
@testable import Sonar

struct SNHomeDMRowsProjectionTests {
    @Test
    func batchedFoldMapPersistsOnlyWhenSomethingChanged() {
        let existing = ["peer-a": "group-1"]
        let noop = snBatchedMarmotFoldMap(
            existing: existing,
            mappings: [("peer-a", "group-1"), ("", "group-2"), ("peer-b", "")]
        )
        #expect(!noop.changed)
        #expect(noop.map == existing)

        let updated = snBatchedMarmotFoldMap(
            existing: existing,
            mappings: [
                ("peer-a", "group-1"),
                ("peer-a-alias", "group-1"),
                ("peer-b", "group-2"),
            ]
        )
        #expect(updated.changed)
        #expect(updated.map["peer-a"] == "group-1")
        #expect(updated.map["peer-a-alias"] == "group-1")
        #expect(updated.map["peer-b"] == "group-2")
    }

    @Test
    func batchedFoldMapCollapsesDuplicateAliasesToOneChange() {
        let updated = snBatchedMarmotFoldMap(
            existing: [:],
            mappings: [
                ("peer-a", "group-1"),
                ("peer-a", "group-1"),
                ("peer-a", "group-1"),
            ]
        )
        #expect(updated.changed)
        #expect(updated.map.count == 1)
        #expect(updated.map["peer-a"] == "group-1")
    }
}
