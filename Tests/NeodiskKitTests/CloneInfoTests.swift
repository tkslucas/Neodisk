// Clone-family identity and the per-directory clone tallies summarized folders keep instead of per-file records.

import Testing
@testable import NeodiskKit

@Suite struct CloneInfoTests {
    @Test func equalityComparesEveryFieldButHashingOnlyTheFamily() {
        let info = CloneInfo(device: 1, cloneID: 7, refCount: 2, privateSize: 10)
        #expect(info == CloneInfo(device: 1, cloneID: 7, refCount: 2, privateSize: 10))
        #expect(info != CloneInfo(device: 1, cloneID: 7, refCount: 3, privateSize: 10))
        #expect(info != CloneInfo(device: 1, cloneID: 7, refCount: 2, privateSize: nil))
        #expect(info != CloneInfo(device: 2, cloneID: 7, refCount: 2, privateSize: 10))
        #expect(info != CloneInfo(device: 1, cloneID: 8, refCount: 2, privateSize: 10))

        // Same family, different private size: unequal, but hashed alike so a set keeps both.
        let unread = CloneInfo(device: 1, cloneID: 7, refCount: 2)
        #expect(info.hashValue == unread.hashValue)
        #expect(Set([info, unread]).count == 2)
    }

    @Test func withPrivateSizeKeepsTheFamilyAndReplacesOnlyTheSize() {
        let unread = CloneInfo(device: 3, cloneID: 9, refCount: 4)
        #expect(unread.privateSize == nil)
        let read = unread.withPrivateSize(512)
        #expect(read.privateSize == 512)
        #expect(read.device == 3 && read.cloneID == 9 && read.refCount == 4)
        #expect(read.familyKey == unread.familyKey)
        #expect(read.withPrivateSize(nil) == unread)
    }

    @Test func familyKeysScopeCloneIDsToTheirDevice() {
        let key = CloneInfo(device: 1, cloneID: 7, refCount: 2).familyKey
        #expect(key == CloneFamilyKey(device: 1, cloneID: 7))
        #expect(key != CloneInfo(device: 2, cloneID: 7, refCount: 2).familyKey)
    }

    @Test func familyKeysOrderByDeviceThenCloneID() {
        let keys = [
            CloneFamilyKey(device: 2, cloneID: 1),
            CloneFamilyKey(device: 1, cloneID: 9),
            CloneFamilyKey(device: 1, cloneID: 3),
        ]
        #expect(keys.sorted() == [
            CloneFamilyKey(device: 1, cloneID: 3),
            CloneFamilyKey(device: 1, cloneID: 9),
            CloneFamilyKey(device: 2, cloneID: 1),
        ])
        #expect(!(keys[1] < keys[1]))
    }

    @Test func summarizedClonesFoldMembersIntoSortedFamilyTallies() throws {
        let a = CloneFamilyKey(device: 1, cloneID: 5)
        let b = CloneFamilyKey(device: 1, cloneID: 2)
        let clones = try #require(SummarizedClones.make(members: [
            SummarizedCloneMember(familyKey: a, allocatedSize: 100),
            SummarizedCloneMember(familyKey: b, allocatedSize: 40),
            SummarizedCloneMember(familyKey: a, allocatedSize: 300),
            SummarizedCloneMember(familyKey: a, allocatedSize: 200),
        ]))
        #expect(clones.families == [
            SummarizedCloneFamily(familyKey: b, memberCount: 1, totalSize: 40, largestSize: 40),
            SummarizedCloneFamily(familyKey: a, memberCount: 3, totalSize: 600, largestSize: 300),
        ])
        #expect(clones.families.allSatisfy { $0.charge == 0 })
    }

    @Test func summarizedClonesAreNilWithoutMembers() {
        #expect(SummarizedClones.make(members: []) == nil)
    }

    @Test func summarizedTotalsSaturateInsteadOfOverflowing() throws {
        let key = CloneFamilyKey(device: 1, cloneID: 1)
        let clones = try #require(SummarizedClones.make(members: [
            SummarizedCloneMember(familyKey: key, allocatedSize: .max),
            SummarizedCloneMember(familyKey: key, allocatedSize: .max),
        ]))
        #expect(clones.families.first?.totalSize == .max)
        #expect(clones.families.first?.memberCount == 2)
    }

    @Test func chargeKeepsOneCopyOnlyForTheFirstMembersHolder() {
        let family = SummarizedCloneFamily(
            familyKey: CloneFamilyKey(device: 1, cloneID: 1),
            memberCount: 3, totalSize: 600, largestSize: 300
        )
        #expect(family.charge(holdsFirstMember: true) == 300)
        #expect(family.charge(holdsFirstMember: false) == 600)

        let charged = family.withCharge(300)
        #expect(charged.charge == 300)
        #expect(charged.familyKey == family.familyKey && charged.totalSize == 600 && charged.largestSize == 300)
        #expect(charged != family)
    }

    @Test func summarizedClonesCompareByFamilies() {
        let family = SummarizedCloneFamily(
            familyKey: CloneFamilyKey(device: 1, cloneID: 1),
            memberCount: 2, totalSize: 20, largestSize: 10
        )
        #expect(SummarizedClones(families: [family]) == SummarizedClones(families: [family]))
        #expect(SummarizedClones(families: [family]) != SummarizedClones(families: [family.withCharge(10)]))
        #expect(SummarizedClones(families: []) != SummarizedClones(families: [family]))
    }
}
