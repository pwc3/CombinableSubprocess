import Combine

extension Future {
    static func promise() -> (Future, Promise) {
        var promise: Promise!
        let future = Future { promise = $0 }

        guard let promise = promise else {
            fatalError("promise was not set")
        }

        return (future, promise)
    }
}
