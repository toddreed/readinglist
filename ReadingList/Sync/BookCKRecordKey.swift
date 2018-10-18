import Foundation
import CoreData
import CloudKit

/**
 Encapsulates the mapping between Book objects and CKRecord values, and additionally
 holds a Bitmask struct which is able to form Int32 bitmask values based on a collection
 of these BookCKRecordKey values, for use in storing keys which are pending remote updates.
 */
// TODO: Relocate to an inner enum withint an extension of Book?
enum BookCKRecordKey: String, CaseIterable { //swiftlint:disable redundant_string_enum_value

    // ----------------------------------------------------------------------- //
    //   Note: the ordering of these cases matters!                            //
    //   The position determines the value used when forming a bitmask, which  //
    //   is persisted in the database. Don't reorder without a lot of thought. //
    // ----------------------------------------------------------------------- //
    case title = "title"
    case authors = "authors"
    case googleBooksId = "googleBooksId"
    case isbn13 = "isbn13"
    case pageCount = "pageCount"
    case publicationDate = "publicationDate"
    case bookDescription = "bookDescription"
    case coverImage = "coverImage"
    case notes = "notes"
    case currentPage = "currentPage"
    case languageCode = "languageCode"
    case rating = "rating"
    case sort = "sort"
    case readDates = "readDates" //swiftlint:enable redundant_string_enum_value

    struct Bitmask: OptionSet {
        let rawValue: Int32

        func keys() -> [BookCKRecordKey] {
            return BookCKRecordKey.allCases.filter { self.contains($0.bitmask) }
        }
    }

    var bitmask: Bitmask {
        return Bitmask(rawValue: 1 << BookCKRecordKey.allCases.index(of: self)!)
    }

    static func from(ckRecordKey key: String) -> BookCKRecordKey? {
        return BookCKRecordKey.allCases.first { $0.rawValue == key }
    }

    static func from(coreDataKey: String) -> BookCKRecordKey? { //swiftlint:disable:this cyclomatic_complexity
        switch coreDataKey {
        case #keyPath(Book.title): return .title
        case #keyPath(Book.authors): return .authors
        case #keyPath(Book.coverImage): return .coverImage
        case #keyPath(Book.googleBooksId): return .googleBooksId
        case #keyPath(Book.isbn13): return .isbn13
        case #keyPath(Book.pageCount): return .pageCount
        case #keyPath(Book.publicationDate): return .publicationDate
        case #keyPath(Book.bookDescription): return .bookDescription
        case #keyPath(Book.notes): return .notes
        case #keyPath(Book.currentPage): return .currentPage
        case #keyPath(Book.languageCode): return .languageCode
        case #keyPath(Book.rating): return .rating
        case #keyPath(Book.sort): return .sort
        case #keyPath(Book.startedReading): return .readDates
        case #keyPath(Book.finishedReading): return .readDates
        default: return nil
        }
    }

    // TODO: Relocate the following two methods to a Book extension?
    func value(from book: Book) -> CKRecordValue? { //swiftlint:disable:this cyclomatic_complexity
        switch self {
        case .title: return book.title as NSString
        case .googleBooksId: return book.googleBooksId as NSString?
        case .isbn13: return book.isbn13 as NSNumber?
        case .pageCount: return book.pageCount
        case .publicationDate: return book.publicationDate as NSDate?
        case .bookDescription: return book.bookDescription as NSString?
        case .notes: return book.notes as NSString?
        case .currentPage: return book.currentPage
        case .languageCode: return book.languageCode as NSString?
        case .rating: return book.rating
        case .sort: return book.sort
        case .readDates:
            switch book.readState {
            case .toRead: return nil
            case .reading: return [book.startedReading! as NSDate] as NSArray
            case .finished: return [book.startedReading! as NSDate, book.finishedReading! as NSDate] as NSArray
            }
        case .authors: return NSKeyedArchiver.archivedData(withRootObject: book.authors) as NSData
        case .coverImage:
            guard let coverImage = book.coverImage else { return nil }
            let imageFilePath = URL.temporary()
            FileManager.default.createFile(atPath: imageFilePath.path, contents: coverImage, attributes: nil)
            return CKAsset(fileURL: imageFilePath)
        }
    }

    func setValue(_ value: CKRecordValue?, for book: Book) { //swiftlint:disable:this cyclomatic_complexity
        switch self {
        case .title: book.title = value as! String
        case .googleBooksId: book.googleBooksId = value as? String
        case .isbn13: book.isbn13 = value as? NSNumber
        case .pageCount: book.pageCount = value as? NSNumber
        case .publicationDate: book.publicationDate = value as? Date
        case .bookDescription: book.bookDescription = value as? String
        case .notes: book.notes = value as? String
        case .currentPage: book.currentPage = value as? NSNumber
        case .languageCode: book.languageCode = value as? String
        case .rating: book.rating = value as? NSNumber
        case .sort: book.sort = value as? NSNumber
        case .readDates:
            let datesArray = value as? [Date]
            book.startedReading = datesArray?[safe: 0]
            book.finishedReading = datesArray?[safe: 1]
            book.updateReadState()
        case .authors:
            book.setAuthors(NSKeyedUnarchiver.unarchiveObject(with: value as! Data) as! [Author])
        case .coverImage:
            guard let imageAsset = value as? CKAsset, FileManager.default.fileExists(atPath: imageAsset.fileURL.path) else {
                book.coverImage = nil
                return
            }
            book.coverImage = FileManager.default.contents(atPath: imageAsset.fileURL.path)
        }
    }
}

extension CKRecord {
    subscript (_ key: BookCKRecordKey) -> CKRecordValue? {
        get { return self.object(forKey: key.rawValue) }
        set { self.setObject(newValue, forKey: key.rawValue) }
    }

    func changedBookKeys() -> [BookCKRecordKey] {
        return changedKeys().compactMap { BookCKRecordKey(rawValue: $0) }
    }

    func presentBookKeys() -> [BookCKRecordKey] {
        return allKeys().compactMap { BookCKRecordKey(rawValue: $0) }
    }
}