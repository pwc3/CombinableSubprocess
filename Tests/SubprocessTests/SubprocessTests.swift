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

    func testNoStreamCapture() throws {
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

        try subprocess.run()
        wait(for: [exp], timeout: 10)
    }

    func testStdoutCapture() throws {
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
                XCTAssertEqual(completion, .finished)
                exp2.fulfill()
            }, receiveValue: { total in
                XCTAssertEqual(total, 235886, "If this fails, check result against `wc -l /usr/share/dict/words`")
            })
            .store(in: &cancellables)

        try subprocess.run()
        wait(for: [exp1, exp2], timeout: 10)
    }

    func testPipe() throws {
        let exp1 = expectation(description: "/bin/cat completed")
        let cat = Subprocess(
            executablePath: "/bin/cat",
            arguments: ["/usr/share/dict/words"],
            terminationHandler: { proc in
                exp1.fulfill()
            })

        let exp2 = expectation(description: "/usr/bin/wc completed")
        let wc = Subprocess(
            executablePath: "/usr/bin/wc",
            arguments: ["-l"],
            terminationHandler: { proc in
                exp2.fulfill()
            })

        cat.pipeStdout(toStdin: wc)

        let exp3 = expectation(description: "publisher completion received")
        wc.stdout
            .sink(receiveCompletion: { completion in
                XCTAssertEqual(completion, .finished)
                exp3.fulfill()
            }, receiveValue: { text in
                XCTAssertEqual("  235886", text, "If this fails, check result against `cat /usr/share/dict/words | wc -l`")
            })
            .store(in: &cancellables)

        try cat.run()
        try wc.run()

        wait(for: [exp1, exp2, exp3], timeout: 20)
    }
}
