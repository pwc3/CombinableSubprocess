import Combine

extension Publisher where Output == Void {

    /// Since Output is Void, this overload of `sink` requires only a `receiveCompletion` block.
    func sink(receiveCompletion: @escaping (Subscribers.Completion<Failure>) -> Void) -> AnyCancellable {
        self.sink(receiveCompletion: receiveCompletion, receiveValue: { })
    }
}
