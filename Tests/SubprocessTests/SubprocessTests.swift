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
        let exp = expectation(description: "termination future resolved")

        let subprocess = Subprocess(
            executablePath: "/bin/cat",
            arguments: ["/usr/share/dict/words"]
        )

        subprocess.termination.sink { termination in
            XCTAssertEqual(termination.status, 0)
            XCTAssertEqual(termination.reason, .exit)
            XCTAssertFalse(subprocess.isRunning)

            exp.fulfill()
        }.store(in: &cancellables)

        try subprocess.run()
        wait(for: [exp], timeout: 10)
    }

    func testStdoutCapture() throws {
        let exp1 = expectation(description: "termination future resolved")
        let exp2 = expectation(description: "publisher completion received")

        let subprocess = Subprocess(
            executablePath: "/bin/cat",
            arguments: ["/usr/share/dict/words"]
        )

        subprocess.termination.sink { termination in
            XCTAssertEqual(termination.status, 0)
            XCTAssertEqual(termination.reason, .exit)
            XCTAssertFalse(subprocess.isRunning)

            exp1.fulfill()
        }
        .store(in: &cancellables)

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
            arguments: ["/usr/share/dict/words"]
        )

        cat.termination.sink { termination in
            XCTAssertEqual(termination.status, 0)
            XCTAssertEqual(termination.reason, .exit)
            XCTAssertFalse(cat.isRunning)
            exp1.fulfill()
        }
        .store(in: &cancellables)

        let exp2 = expectation(description: "/usr/bin/wc completed")
        let wc = Subprocess(
            executablePath: "/usr/bin/wc",
            arguments: ["-l"]
        )

        wc.termination.sink { termination in
            XCTAssertEqual(termination.status, 0)
            XCTAssertEqual(termination.reason, .exit)
            XCTAssertFalse(wc.isRunning)
            exp2.fulfill()
        }
        .store(in: &cancellables)

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
