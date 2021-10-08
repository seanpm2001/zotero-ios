//
//  SyncActionsSpec.swift
//  ZoteroTests
//
//  Created by Michal Rentka on 09/07/2019.
//  Copyright © 2019 Corporation for Digital Scholarship. All rights reserved.
//

import Foundation

@testable import Zotero

import Alamofire
import CocoaLumberjackSwift
import Nimble
import OHHTTPStubs
import OHHTTPStubsSwift
import RealmSwift
import RxSwift
import Quick

final class SyncActionsSpec: QuickSpec {
    private let userId = 100
    // We need to retain realm with memory identifier so that data are not deleted
    private let realm: Realm
    private let dbStorage: DbStorage
    private let disposeBag: DisposeBag

    required init() {
        let config = Realm.Configuration(inMemoryIdentifier: "TestsRealmConfig")
        self.realm = try! Realm(configuration: config)
        self.dbStorage = RealmDbStorage(config: config)
        self.disposeBag = DisposeBag()
    }

    override func spec() {
        beforeEach {
            try? TestControllers.fileStorage.remove(Files.downloads)

            HTTPStubs.removeAllStubs()

            try! self.realm.write {
                self.realm.deleteAll()
            }
        }

        describe("conflict resolution") {
            it("reverts group changes") {
                // Load urls for bundled files
                guard let collectionUrl = Bundle(for: type(of: self)).url(forResource: "test_collection", withExtension: "json"),
                      let itemUrl = Bundle(for: type(of: self)).url(forResource: "test_item", withExtension: "json"),
                      let searchUrl = Bundle(for: type(of: self)).url(forResource: "test_search", withExtension: "json") else {
                    fail("Could not find json files")
                    return
                }

                // Load their data
                let collectionData = try! Data(contentsOf: collectionUrl)
                let collectionJson = (try! JSONSerialization.jsonObject(with: collectionData, options: .allowFragments)) as! [String: Any]
                let searchData = try! Data(contentsOf: searchUrl)
                let searchJson = (try! JSONSerialization.jsonObject(with: searchData, options: .allowFragments)) as! [String: Any]
                let itemData = try! Data(contentsOf: itemUrl)
                let itemJson = (try! JSONSerialization.jsonObject(with: itemData, options: .allowFragments)) as! [String: Any]

                // Write original json files to directory folder for SyncActionHandler to use when reverting
                let collectionFile = Files.jsonCacheFile(for: .collection, libraryId: .group(1234123), key: "BBBBBBBB")
                try! FileManager.default.createMissingDirectories(for: collectionFile.createUrl().deletingLastPathComponent())
                try! collectionData.write(to: collectionFile.createUrl())
                let searchFile = Files.jsonCacheFile(for: .search, libraryId: .custom(.myLibrary), key: "CCCCCCCC")
                try! searchData.write(to: searchFile.createUrl())
                let itemFile = Files.jsonCacheFile(for: .item, libraryId: .custom(.myLibrary), key: "AAAAAAAA")
                try! itemData.write(to: itemFile.createUrl())

                // Create response models
                let collectionResponse = try! CollectionResponse(response: collectionJson)
                let searchResponse = try! SearchResponse(response: searchJson)
                let itemResponse = try! ItemResponse(response: itemJson, schemaController: TestControllers.schemaController)

                let coordinator = try! self.dbStorage.createCoordinator()
                // Store original objects to db
                _ = try! coordinator.perform(request: StoreItemsDbRequest(responses: [itemResponse], schemaController: TestControllers.schemaController, dateParser: TestControllers.dateParser))
                try! coordinator.perform(request: StoreCollectionsDbRequest(response: [collectionResponse]))
                try! coordinator.perform(request: StoreSearchesDbRequest(response: [searchResponse]))

                // Change some objects so that they are updated locally
                try! coordinator.perform(request: EditCollectionDbRequest(libraryId: .group(1234123), key: "BBBBBBBB", name: "New name", parentKey: nil))
                let data = ItemDetailState.Data(title: "New title",
                                                type: "magazineArticle",
                                                isAttachment: false,
                                                localizedType: "Magazine Article",
                                                creators: [:],
                                                creatorIds: [],
                                                fields: [:],
                                                fieldIds: [],
                                                abstract: "New abstract",
                                                notes: [],
                                                attachments: [],
                                                tags: [],
                                                deletedAttachments: [],
                                                deletedNotes: [],
                                                deletedTags: [],
                                                dateModified: Date(),
                                                dateAdded: Date(),
                                                maxFieldTitleWidth: 0,
                                                maxNonemptyFieldTitleWidth: 0)
                let snapshot = ItemDetailState.Data(title: "Bachelor thesis",
                                                type: "thesis",
                                                isAttachment: false,
                                                localizedType: "Thesis",
                                                creators: [:],
                                                creatorIds: [],
                                                fields: [:],
                                                fieldIds: [],
                                                abstract: "Some note",
                                                notes: [],
                                                attachments: [],
                                                tags: [],
                                                deletedAttachments: [],
                                                deletedNotes: [],
                                                deletedTags: [],
                                                dateModified: Date(),
                                                dateAdded: Date(),
                                                maxFieldTitleWidth: 0,
                                                maxNonemptyFieldTitleWidth: 0)

                let changeRequest = EditItemDetailDbRequest(libraryId: .custom(.myLibrary), itemKey: "AAAAAAAA", data: data, snapshot: snapshot, schemaController: TestControllers.schemaController,
                                                            dateParser: TestControllers.dateParser)
                try! coordinator.perform(request: changeRequest)

                self.realm.refresh()

                let item = self.realm.objects(RItem.self).filter(.key("AAAAAAAA")).first
                expect(item?.rawType).to(equal("magazineArticle"))
                expect(item?.baseTitle).to(equal("New title"))
                expect(item?.fields.filter("key =  %@", FieldKeys.Item.abstract).first?.value).to(equal("New abstract"))
                expect(item?.isChanged).to(beTrue())

                let collection = self.realm.objects(RCollection.self).filter(.key("BBBBBBBB")).first
                expect(collection?.name).to(equal("New name"))
                expect(collection?.parentKey).to(beNil())

                waitUntil(timeout: .seconds(10), action: { doneAction in
                    RevertLibraryUpdatesSyncAction(libraryId: .custom(.myLibrary), dbStorage: self.dbStorage, fileStorage: TestControllers.fileStorage,
                                                   schemaController: TestControllers.schemaController, dateParser: TestControllers.dateParser).result
                                         .subscribe(onSuccess: { failures in
                                             expect(failures[.item]).to(beEmpty())
                                             expect(failures[.collection]).to(beEmpty())
                                             expect(failures[.search]).to(beEmpty())

                                             self.realm.refresh()

                                             let item = self.realm.objects(RItem.self).filter(.key("AAAAAAAA")).first
                                             expect(item?.rawType).to(equal("thesis"))
                                             expect(item?.baseTitle).to(equal("Bachelor thesis"))
                                             expect(item?.fields.filter("key =  %@", FieldKeys.Item.abstract).first?.value).to(equal("Some note"))
                                             expect(item?.rawChangedFields).to(equal(0))

                                             doneAction()
                                         }, onFailure: { error in
                                             fail("Could not revert user library: \(error)")
                                             doneAction()
                                         })
                                         .disposed(by: self.disposeBag)
                })

                waitUntil(timeout: .seconds(10), action: { doneAction in
                    RevertLibraryUpdatesSyncAction(libraryId: .group(1234123),
                                                   dbStorage: self.dbStorage,
                                                   fileStorage: TestControllers.fileStorage,
                                                   schemaController: TestControllers.schemaController,
                                                   dateParser: TestControllers.dateParser).result
                                         .subscribe(onSuccess: { failures in
                                             expect(failures[.item]).to(beEmpty())
                                             expect(failures[.collection]).to(beEmpty())
                                             expect(failures[.search]).to(beEmpty())

                                             self.realm.refresh()

                                             let collection = self.realm.objects(RCollection.self).filter(.key("BBBBBBBB")).first
                                             expect(collection?.name).to(equal("Bachelor sources"))
                                             expect(collection?.parentKey).to(beNil())

                                             doneAction()
                                         }, onFailure: { error in
                                             fail("Could not revert group library: \(error)")
                                             doneAction()
                                         })
                                         .disposed(by: self.disposeBag)
                })
            }

            it("marks local changes as synced") {
                // Load urls for bundled files
                guard let collectionUrl = Bundle(for: type(of: self)).url(forResource: "test_collection", withExtension: "json"),
                      let itemUrl = Bundle(for: type(of: self)).url(forResource: "test_item", withExtension: "json") else {
                    fail("Could not find json files")
                    return
                }

                // Load their data
                let collectionData = try! Data(contentsOf: collectionUrl)
                let collectionJson = (try! JSONSerialization.jsonObject(with: collectionData, options: .allowFragments)) as! [String: Any]
                let itemData = try! Data(contentsOf: itemUrl)
                let itemJson = (try! JSONSerialization.jsonObject(with: itemData, options: .allowFragments)) as! [String: Any]

                // Create response models
                let collectionResponse = try! CollectionResponse(response: collectionJson)
                let itemResponse = try! ItemResponse(response: itemJson, schemaController: TestControllers.schemaController)

                let coordinator = try! self.dbStorage.createCoordinator()
                // Store original objects to db
                _ = try! coordinator.perform(request: StoreItemsDbRequest(responses: [itemResponse], schemaController: TestControllers.schemaController, dateParser: TestControllers.dateParser))
                try! coordinator.perform(request: StoreCollectionsDbRequest(response: [collectionResponse]))

                // Change some objects so that they are updated locally
                try! coordinator.perform(request: EditCollectionDbRequest(libraryId: .group(1234123), key: "BBBBBBBB", name: "New name", parentKey: nil))
                let data = ItemDetailState.Data(title: "New title",
                                                type: "magazineArticle",
                                                isAttachment: false,
                                                localizedType: "Magazine Article",
                                                creators: [:],
                                                creatorIds: [],
                                                fields: [:],
                                                fieldIds: [],
                                                abstract: "New abstract",
                                                notes: [],
                                                attachments: [],
                                                tags: [],
                                                deletedAttachments: [],
                                                deletedNotes: [],
                                                deletedTags: [],
                                                dateModified: Date(),
                                                dateAdded: Date(),
                                                maxFieldTitleWidth: 0,
                                                maxNonemptyFieldTitleWidth: 0)
                let snapshot = ItemDetailState.Data(title: "Bachelor thesis",
                                                type: "thesis",
                                                isAttachment: false,
                                                localizedType: "Thesis",
                                                creators: [:],
                                                creatorIds: [],
                                                fields: [:],
                                                fieldIds: [],
                                                abstract: "Some note",
                                                notes: [],
                                                attachments: [],
                                                tags: [],
                                                deletedAttachments: [],
                                                deletedNotes: [],
                                                deletedTags: [],
                                                dateModified: Date(),
                                                dateAdded: Date(),
                                                maxFieldTitleWidth: 0,
                                                maxNonemptyFieldTitleWidth: 0)
                let changeRequest = EditItemDetailDbRequest(libraryId: .custom(.myLibrary), itemKey: "AAAAAAAA", data: data, snapshot: snapshot, schemaController: TestControllers.schemaController,
                                                            dateParser: TestControllers.dateParser)
                try! coordinator.perform(request: changeRequest)

                self.realm.refresh()

                let item = self.realm.objects(RItem.self).filter(.key("AAAAAAAA")).first
                expect(item?.rawType).to(equal("magazineArticle"))
                expect(item?.baseTitle).to(equal("New title"))
                expect(item?.fields.filter("key =  %@", FieldKeys.Item.abstract).first?.value).to(equal("New abstract"))
                expect(item?.rawChangedFields).toNot(equal(0))
                expect(item?.isChanged).to(beTrue())

                let collection = self.realm.objects(RCollection.self).filter(.key("BBBBBBBB")).first
                expect(collection?.name).to(equal("New name"))
                expect(collection?.parentKey).to(beNil())
                expect(collection?.rawChangedFields).toNot(equal(0))

                waitUntil(timeout: .seconds(10), action: { doneAction in
                    MarkChangesAsResolvedSyncAction(libraryId: .custom(.myLibrary), dbStorage: self.dbStorage).result
                                         .subscribe(onSuccess: { _ in
                                             self.realm.refresh()

                                             let item = self.realm.objects(RItem.self).filter(.key("AAAAAAAA")).first
                                             expect(item?.rawType).to(equal("magazineArticle"))
                                             expect(item?.baseTitle).to(equal("New title"))
                                             expect(item?.fields.filter("key =  %@", FieldKeys.Item.abstract).first?.value).to(equal("New abstract"))
                                             expect(item?.rawChangedFields).to(equal(0))

                                             doneAction()
                                        }, onFailure: { error in
                                            fail("Could not sync user library: \(error)")
                                            doneAction()
                                        })
                                        .disposed(by: self.disposeBag)
                })

                waitUntil(timeout: .seconds(10), action: { doneAction in
                    MarkChangesAsResolvedSyncAction(libraryId: .group(1234123), dbStorage: self.dbStorage).result
                                         .subscribe(onSuccess: { _ in
                                             self.realm.refresh()

                                             let collection = self.realm.objects(RCollection.self).filter(.key("BBBBBBBB")).first
                                             expect(collection?.name).to(equal("New name"))
                                             expect(collection?.parentKey).to(beNil())
                                             expect(collection?.rawChangedFields).to(equal(0))

                                             doneAction()
                                         }, onFailure: { error in
                                             fail("Could not sync group library: \(error)")
                                             doneAction()
                                         })
                                         .disposed(by: self.disposeBag)
                })
            }
        }

        describe("attachment upload") {
            let baseUrl = URL(string: ApiConstants.baseUrlString)!

            it("fails when item metadata not submitted") {
                let key = "AAAAAAAA"
                let libraryId = LibraryIdentifier.group(1)
                let file = Files.attachmentFile(in: libraryId, key: key, filename: "file", contentType: "application/pdf")

                try! self.realm.write {
                    let library = RGroup()
                    library.identifier = 1
                    self.realm.add(library)

                    let item = RItem()
                    item.key = key
                    item.rawType = "attachment"
                    item.groupKey = library.identifier
                    item.changedFields = .all
                    item.attachmentNeedsSync = true
                    self.realm.add(item)
                }

                waitUntil(timeout: .seconds(10), action: { doneAction in
                    UploadAttachmentSyncAction(key: key,
                                               file: file,
                                               filename: "doc.pdf",
                                               md5: "aaaaaaaa", mtime: 0,
                                               libraryId: libraryId,
                                               userId: self.userId,
                                               oldMd5: nil,
                                               apiClient: TestControllers.apiClient,
                                               dbStorage: self.dbStorage,
                                               fileStorage: TestControllers.fileStorage,
                                               queue: DispatchQueue.main,
                                               scheduler: MainScheduler.instance).result
                                         .subscribe(onSuccess: { response, _ in
                                             response.subscribe(onCompleted: {
                                                 fail("Upload didn't fail with unsubmitted item")
                                                 doneAction()
                                             }, onError: { error in
                                                 if let handlerError = error as? SyncActionError {
                                                     expect(handlerError).to(equal(.attachmentItemNotSubmitted))
                                                 } else {
                                                     fail("Unknown error: \(error.localizedDescription)")
                                                 }
                                                 doneAction()
                                             })
                                             .disposed(by: self.disposeBag)
                                         }, onFailure: { error in
                                             fail("Unknown error: \(error.localizedDescription)")
                                             doneAction()
                                         })
                                         .disposed(by: self.disposeBag)
                })
            }

            it("fails when file is not available") {
                let key = "AAAAAAAA"
                let filename = "doc.pdf"
                let libraryId = LibraryIdentifier.group(1)
                let file = Files.attachmentFile(in: libraryId, key: key, filename: filename, contentType: "application/pdf")

                try! self.realm.write {
                    let library = RGroup()
                    library.identifier = 1
                    self.realm.add(library)

                    let item = RItem()
                    item.key = key
                    item.rawType = "attachment"
                    item.groupKey = library.identifier
                    item.rawChangedFields = 0
                    item.attachmentNeedsSync = true
                    self.realm.add(item)
                }

                waitUntil(timeout: .seconds(10), action: { doneAction in
                    UploadAttachmentSyncAction(key: key,
                                               file: file,
                                               filename: filename,
                                               md5: "aaaaaaaa", mtime: 0,
                                               libraryId: libraryId,
                                               userId: self.userId,
                                               oldMd5: nil,
                                               apiClient: TestControllers.apiClient,
                                               dbStorage: self.dbStorage,
                                               fileStorage: TestControllers.fileStorage,
                                               queue: DispatchQueue.main,
                                               scheduler: MainScheduler.instance).result
                                         .flatMap({ response, _ -> Single<Never> in
                                             return response.asObservable().asSingle()
                                         })
                                         .subscribe(onSuccess: { _ in
                                             fail("Upload didn't fail with unsubmitted item")
                                             doneAction()
                                         }, onFailure: { error in
                                             if let handlerError = error as? SyncActionError {
                                                 expect(handlerError).to(equal(.attachmentMissing(key: key, title: "")))
                                             } else {
                                                 fail("Unknown error: \(error.localizedDescription)")
                                             }
                                             doneAction()
                                         })
                                         .disposed(by: self.disposeBag)
                })
            }

            it("it doesn't reupload when file is already uploaded") {
                let key = "AAAAAAAA"
                let filename = "doc.txt"
                let libraryId = LibraryIdentifier.group(1)
                let file = Files.attachmentFile(in: libraryId, key: key, filename: filename, contentType: "text/plain")

                let data = "test string".data(using: .utf8)!
                try! FileStorageController().write(data, to: file, options: .atomicWrite)
                let fileMd5 = md5(from: file.createUrl())!

                try! self.realm.write {
                    let library = RGroup()
                    library.identifier = 1
                    self.realm.add(library)

                    let item = RItem()
                    item.key = key
                    item.rawType = "attachment"
                    item.groupKey = library.identifier
                    item.rawChangedFields = 0
                    item.attachmentNeedsSync = true

                    let contentField = RItemField()
                    contentField.key = FieldKeys.Item.Attachment.contentType
                    contentField.value = "text/plain"
                    item.fields.append(contentField)

                    let filenameField = RItemField()
                    filenameField.key = FieldKeys.Item.Attachment.filename
                    filenameField.value = filename
                    item.fields.append(filenameField)

                    self.realm.add(item)
                }

                createStub(for: AuthorizeUploadRequest(libraryId: libraryId, userId: self.userId, key: key,
                                                       filename: filename, filesize: UInt64(data.count), md5: fileMd5, mtime: 123,
                                                       oldMd5: nil),
                           baseUrl: baseUrl, jsonResponse: ["exists": 1])

                waitUntil(timeout: .seconds(10000), action: { doneAction in
                    UploadAttachmentSyncAction(key: key,
                                               file: file,
                                               filename: filename,
                                               md5: fileMd5,
                                               mtime: 123,
                                               libraryId: libraryId,
                                               userId: self.userId,
                                               oldMd5: nil,
                                               apiClient: TestControllers.apiClient,
                                               dbStorage: self.dbStorage,
                                               fileStorage: TestControllers.fileStorage,
                                               queue: DispatchQueue.main,
                                               scheduler: MainScheduler.instance).result
                                         .flatMap({ response, _ -> Single<()> in
                                             return Single.create { subscriber -> Disposable in
                                                response.subscribe(onCompleted: {
                                                            subscriber(.success(()))
                                                        }, onError: { error in
                                                            subscriber(.failure(error))
                                                        })
                                                        .disposed(by: self.disposeBag)
                                                return Disposables.create()
                                             }
                                         })
                                         .subscribe(onSuccess: { _ in
                                             doneAction()
                                         }, onFailure: { error in
                                             fail("Unknown error: \(error.localizedDescription)")
                                             doneAction()
                                         })
                                         .disposed(by: self.disposeBag)
                })
            }

            it("uploads new file") {
                let key = "AAAAAAAA"
                let filename = "doc.txt"
                let libraryId = LibraryIdentifier.group(1)
                let file = Files.attachmentFile(in: libraryId, key: key, filename: filename, contentType: "text/plain")

                let data = "test string".data(using: .utf8)!
                try! FileStorageController().write(data, to: file, options: .atomicWrite)
                let fileMd5 = md5(from: file.createUrl())!

                try! self.realm.write {
                    let library = RGroup()
                    library.identifier = 1
                    self.realm.add(library)

                    let item = RItem()
                    item.key = key
                    item.rawType = "attachment"
                    item.groupKey = library.identifier
                    item.rawChangedFields = 0
                    item.attachmentNeedsSync = true

                    let contentField = RItemField()
                    contentField.key = FieldKeys.Item.Attachment.contentType
                    contentField.value = "text/plain"
                    item.fields.append(contentField)

                    let filenameField = RItemField()
                    filenameField.key = FieldKeys.Item.Attachment.filename
                    filenameField.value = filename
                    item.fields.append(filenameField)

                    self.realm.add(item)
                }

                createStub(for: AuthorizeUploadRequest(libraryId: libraryId, userId: self.userId, key: key, filename: filename, filesize: UInt64(data.count), md5: fileMd5, mtime: 123, oldMd5: nil),
                           baseUrl: baseUrl, jsonResponse: ["url": "https://www.zotero.org/", "uploadKey": "key", "params": ["key": "key"]])
                createStub(for: RegisterUploadRequest(libraryId: libraryId, userId: self.userId, key: key, uploadKey: "key", oldMd5: nil),
                           baseUrl: baseUrl, headers: nil, statusCode: 204, jsonResponse: [:])
                stub(condition: { request -> Bool in
                    return request.url?.absoluteString == "https://www.zotero.org/"
                }, response: { _ -> HTTPStubsResponse in
                    return HTTPStubsResponse(jsonObject: [:], statusCode: 201, headers: nil)
                })


                waitUntil(timeout: .seconds(10), action: { doneAction in
                    UploadAttachmentSyncAction(key: key,
                                               file: file,
                                               filename: filename,
                                               md5: fileMd5,
                                               mtime: 123,
                                               libraryId: libraryId,
                                               userId: self.userId,
                                               oldMd5: nil,
                                               apiClient: TestControllers.apiClient,
                                               dbStorage: self.dbStorage,
                                               fileStorage: TestControllers.fileStorage,
                                               queue: DispatchQueue.main,
                                               scheduler: MainScheduler.instance).result
                                         .flatMap({ response, _ -> Single<()> in
                                             return Single.create { subscriber -> Disposable in
                                                response.subscribe(onCompleted: {
                                                            subscriber(.success(()))
                                                        }, onError: { error in
                                                            subscriber(.failure(error))
                                                        })
                                                        .disposed(by: self.disposeBag)
                                                return Disposables.create()
                                             }
                                         })
                                         .subscribe(onSuccess: { _ in
                                             self.realm.refresh()

                                             let item = self.realm.objects(RItem.self).filter(.key(key)).first
                                             expect(item?.attachmentNeedsSync).to(beFalse())

                                             doneAction()
                                         }, onFailure: { error in
                                             fail("Unknown error: \(error.localizedDescription)")
                                             doneAction()
                                         })
                                         .disposed(by: self.disposeBag)
                })
            }
        }
    }
}

extension SyncActionError: Equatable {
    public static func == (lhs: SyncActionError, rhs: SyncActionError) -> Bool {
        switch (lhs, rhs) {
        case (.attachmentItemNotSubmitted, .attachmentItemNotSubmitted), (.attachmentAlreadyUploaded, .attachmentAlreadyUploaded), (.submitUpdateFailures, .submitUpdateFailures):
            return true
        case (.attachmentMissing(let lKey, let lTitle), .attachmentMissing(let rKey, let rTitle)):
            return lKey == rKey && lTitle == rTitle
        default:
            return false
        }
    }
}
