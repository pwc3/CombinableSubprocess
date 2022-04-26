import Combine
import Subprocess
import XCTest

final class SubprocessTests: XCTestCase {
    private var cancellables: Set<AnyCancellable> = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        cancellables = []
    }

    override func tearDownWithError() throws {
        cancellables = []
        try super.tearDownWithError()
    }

    func testNoStreamCapture() {
        let exp = expectation(description: "termination handler called")

        let subprocess = Subprocess(
            executablePath: "/bin/cat",
            arguments: ["/usr/share/dict/words"],
            terminationHandler: { proc in
                XCTAssertEqual(proc.terminationStatus, 0)
                XCTAssertEqual(proc.terminationReason, .exit)
                XCTAssertFalse(proc.isRunning)

                exp.fulfill()
            })

        try? subprocess.run()
        wait(for: [exp], timeout: 60)
    }

    func testStdoutCapture() {
        let exp1 = expectation(description: "termination handler called")
        let exp2 = expectation(description: "publisher completion received")

        let subprocess = Subprocess(
            executablePath: "/bin/cat",
            arguments: ["/usr/share/dict/words"],
            terminationHandler: { proc in
                XCTAssertEqual(proc.terminationStatus, 0)
                XCTAssertEqual(proc.terminationReason, .exit)
                XCTAssertFalse(proc.isRunning)

                exp1.fulfill()
            })

        subprocess
            .stdout
            .count()
            .sink(receiveCompletion: { completion in
                if case .finished = completion { }
                else {
                    XCTFail("Completion indicates failure: \(completion)")
                }
                exp2.fulfill()
            }, receiveValue: { total in
                XCTAssertEqual(total, 235886, "If this fails, check result against `wc -l /usr/share/dict/words`")
            })
            .store(in: &cancellables)

        try? subprocess.run()
        wait(for: [exp1, exp2], timeout: 60)
    }
}
