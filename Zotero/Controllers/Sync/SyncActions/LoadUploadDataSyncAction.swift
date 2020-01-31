//
//  LoadUploadDataSyncAction.swift
//  Zotero
//
//  Created by Michal Rentka on 30/01/2020.
//  Copyright © 2020 Corporation for Digital Scholarship. All rights reserved.
//

import Foundation

import RxSwift

struct LoadUploadDataSyncAction: SyncAction {
    typealias Result = [SyncController.AttachmentUpload]

    let libraryId: LibraryIdentifier

    unowned let backgroundUploader: BackgroundUploader
    unowned let dbStorage: DbStorage

    var result: Single<[SyncController.AttachmentUpload]> {
        return self.loadUploads(libraryId: self.libraryId)
                   .flatMap { uploads in
                       let backgroundUploads = self.backgroundUploader.ongoingUploads()
                       return Single.just(uploads.filter({ !backgroundUploads.contains($0.md5) }))
                   }
    }

    private func loadUploads(libraryId: LibraryIdentifier) -> Single<[SyncController.AttachmentUpload]> {
        return Single.create { subscriber -> Disposable in
            do {
                let request = ReadAttachmentUploadsDbRequest(libraryId: libraryId)
                let uploads = try self.dbStorage.createCoordinator().perform(request: request)
                subscriber(.success(uploads))
            } catch let error {
                subscriber(.error(error))
            }
            return Disposables.create()
        }
    }
}
