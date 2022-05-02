//
//  Command.swift
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

class CommandTests: XCTestCase {
    private var cancellables: Set<AnyCancellable> = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        cancellables = []
        print("*** set up")
    }

    override func tearDownWithError() throws {
        cancellables = []
        try super.tearDownWithError()
        print("*** torn down")
    }

    func testSimpleCommand() throws {
        let exp = expectation(description: "sink invoked")

        let seq = Command("/usr/bin/seq", "10")
        seq.run()
            .filter { !$0.isEmpty }
            .count()
            .sink { completion in
                defer {
                    exp.fulfill()
                }

                guard case .finished = completion else {
                    XCTFail("Unexpected error")
                    return
                }
            } receiveValue: { count in
                XCTAssertEqual(count, 10)
            }
            .store(in: &cancellables)

        wait(for: [exp], timeout: 10)
    }

    func testFailingCommand() throws {
        let exp = expectation(description: "sink invoked")
        let exitCode = Int32(42)

        let bash = Command("/bin/bash", "-c", "exit \(exitCode)")
        bash.run()
            .sink { completion in
                defer {
                    exp.fulfill()
                }

                guard case .failure(let error) = completion else {
                    XCTFail("Unexpected success")
                    return
                }

                XCTAssertEqual(SubprocessError.nonZeroTerminationStatus(42), error as? SubprocessError)
            } receiveValue: { _ in }
            .store(in: &cancellables)

        wait(for: [exp], timeout: 10)
    }

    func testNonExistentExecutable() throws {
        let exp = expectation(description: "sink invoked")

        let command = Command(UUID().uuidString)
        command.run()
            .sink { completion in
                defer {
                    exp.fulfill()
                }

                guard case .failure(let error) = completion else {
                    XCTFail("Unexpected success")
                    return
                }

                print("error", error)
            } receiveValue: { string in
                XCTFail("Unexpected output")
            }
            .store(in: &cancellables)

        wait(for: [exp], timeout: 10)

    }
}
