import Combine
import CombinableSubprocess
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
            executablePath: "/usr/bin/seq",
            arguments: ["10"]
        )

        try subprocess.run()

        subprocess.termination.sink { completion in
            XCTAssertEqual(completion, .finished)
            exp.fulfill()
        }
        .store(in: &cancellables)

        wait(for: [exp], timeout: 10)
    }

    func testStdoutCapture() throws {
        let exp1 = expectation(description: "termination future resolved")
        let exp2 = expectation(description: "publisher completion received")

        let count = 1_000

        let subprocess = Subprocess(
            executablePath: "/usr/bin/seq",
            arguments: ["-f", "%.0f", count.description]
        )

        subprocess.termination.sink { completion in
            XCTAssertEqual(completion, .finished)
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
                XCTAssertEqual(total, count)
            })
            .store(in: &cancellables)

        try subprocess.run()
        wait(for: [exp1, exp2], timeout: 60)
    }

    func testBuffering() throws {
        let exp1 = expectation(description: "termination future resolved")
        let exp2 = expectation(description: "publisher completion received")

        let count = 100

        let subprocess = Subprocess(
            executablePath: "/usr/bin/seq",
            arguments: ["-f", "%.0f", count.description]
        )

        subprocess.termination.sink { completion in
            XCTAssertEqual(completion, .finished)
            exp1.fulfill()
        }
        .store(in: &cancellables)

        subprocess
            .stdout
            .flatMap(maxPublishers: .max(1)) {
                // Add a 100 ms delay in processing. Without a buffer, we would fail to capture all values.
                Just($0).delay(for: .milliseconds(10), scheduler: DispatchQueue.main)
            }
            .count()
            .sink(receiveCompletion: { completion in
                XCTAssertEqual(completion, .finished)
                exp2.fulfill()
            }, receiveValue: { total in
                XCTAssertEqual(total, count)
            })
            .store(in: &cancellables)

        try subprocess.run()
        wait(for: [exp1, exp2], timeout: 60)
    }

    func testPipe() throws {
        let count = 1_000

        let exp1 = expectation(description: "/usr/bin/seq completed")
        let cat = Subprocess(
            executablePath: "/usr/bin/seq",
            arguments: ["-f", "%.0f", count.description]
        )

        cat.termination.sink { completion in
            XCTAssertEqual(completion, .finished)
            exp1.fulfill()
        }
        .store(in: &cancellables)

        let exp2 = expectation(description: "/usr/bin/wc completed")
        let wc = Subprocess(
            executablePath: "/usr/bin/wc",
            arguments: ["-l"]
        )

        wc.termination.sink { completion in
            XCTAssertEqual(completion, .finished)
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
                XCTAssertEqual(count.description, text.trimmingCharacters(in: .whitespaces))
            })
            .store(in: &cancellables)

        try cat.run()
        try wc.run()

        wait(for: [exp1, exp2, exp3], timeout: 60)
    }

    func testMultipleSubscribers() throws {
        let exp1 = expectation(description: "termination future resolved")
        let exp2 = expectation(description: "subscriber 1 completion received")
        let exp3 = expectation(description: "subscriber 2 completion received")

        let count = 1_000

        let subprocess = Subprocess(
            executablePath: "/usr/bin/seq",
            arguments: ["-f", "%.0f", count.description]
        )

        subprocess.termination.sink { completion in
            XCTAssertFalse(subprocess.isRunning)
            XCTAssertEqual(completion, .finished)
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
                XCTAssertEqual(total, count)
            })
            .store(in: &cancellables)

        subprocess
            .stdout
            .count()
            .sink(receiveCompletion: { completion in
                XCTAssertEqual(completion, .finished)
                exp3.fulfill()
            }, receiveValue: { total in
                XCTAssertEqual(total, count)
            })
            .store(in: &cancellables)

        try subprocess.run()

        wait(for: [exp1, exp2, exp3], timeout: 60)
    }
}
