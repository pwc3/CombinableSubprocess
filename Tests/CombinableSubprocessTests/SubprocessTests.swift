//
//  SubprocessTests.swift
//  CombinableSubprocessTests
//
//  Copyright (c) 2022 Anodized Software, Inc.
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in all
//  copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
//  SOFTWARE.
//

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

    func testZeroExit() throws {
        let exp = expectation(description: "termination future resolved")

        let subprocess = Subprocess(
            executablePath: "/bin/bash",
            arguments: ["-c", "exit 0"]
        )

        subprocess.termination.sink { completion in
            XCTAssertEqual(completion, .finished)
            exp.fulfill()
        }
        .store(in: &cancellables)

        try subprocess.run()

        wait(for: [exp], timeout: 10)
    }

    func testNonZeroExit() throws {
        let exp = expectation(description: "termination future resolved")
        let exitCode = Int32(42)

        let subprocess = Subprocess(
            executablePath: "/bin/bash",
            arguments: ["-c", "exit \(exitCode)"]
        )

        subprocess.termination.sink { completion in
            XCTAssertEqual(completion, .failure(SubprocessError.nonZeroTerminationStatus(exitCode)))
            exp.fulfill()
        }
        .store(in: &cancellables)

        try subprocess.run()

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
            .standardOutput
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
            .standardOutput
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

        cat.pipeStandardOutput(toStandardInput: wc)

        let exp3 = expectation(description: "publisher completion received")
        wc.standardOutput
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
            .standardOutput
            .count()
            .sink(receiveCompletion: { completion in
                XCTAssertEqual(completion, .finished)
                exp2.fulfill()
            }, receiveValue: { total in
                XCTAssertEqual(total, count)
            })
            .store(in: &cancellables)

        subprocess
            .standardOutput
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

    func testReadmeBasicUsageExample() throws {
        let exp = expectation(description: "termination future resolved")

        let subprocess = Subprocess(
            executablePath: "/usr/bin/seq",
            arguments: ["3"]
        )

        try subprocess.run()

        subprocess.termination.sink(receiveCompletion: { completion in
            switch completion {
            case .finished:
                print("The process completed successfully")

            case .failure(let error):
                print("The process completed with an error:", error)
            }
            exp.fulfill()
        }, receiveValue: {})
        .store(in: &cancellables)

        wait(for: [exp], timeout: 10)
    }

    func testReadmeOutputObservationUsageExample() throws {
        let exp = expectation(description: "termination future resolved")

        let subprocess = Subprocess(
            executablePath: "/usr/bin/seq",
            arguments: ["3"]
        )

        subprocess.standardOutput
            .compactMap { Int($0) }
            .sink(receiveCompletion: { _ in
                exp.fulfill()
            }, receiveValue: {
                print("Received Int:", $0)
            })
            .store(in: &cancellables)

        try subprocess.run()

        wait(for: [exp], timeout: 10)
    }

    func testReadmePipeUsageExample() throws {
        let cat = Subprocess(
            executablePath: "/usr/bin/seq",
            arguments: ["100"]
        )

        let wc = Subprocess(
            executablePath: "/usr/bin/wc",
            arguments: ["-l"]
        )

        cat.pipeStandardOutput(toStandardInput: wc)

        let exp = expectation(description: "publisher completion received")
        wc.standardOutput
            .sink(receiveCompletion: { completion in
                XCTAssertEqual(completion, .finished)
                exp.fulfill()
            }, receiveValue: { text in
                XCTAssertEqual("100", text.trimmingCharacters(in: .whitespaces))
            })
            .store(in: &cancellables)

        try cat.run()
        try wc.run()

        wait(for: [exp], timeout: 60)
    }
}
