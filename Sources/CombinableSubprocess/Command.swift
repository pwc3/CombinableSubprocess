//
//  Command.swift
//  CombinableSubprocess
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
import Foundation

/// A `Command` wraps a `Subprocess`, enabling the caller to simply run the subprocess and observe its standard output publisher in one shot.
public struct Command {

    public var subprocess: Subprocess

    public init(_ executablePath: String, _ arguments: String...) {
        self.init(subprocess: Subprocess(executablePath: executablePath, arguments: arguments))
    }

    public init(executablePath: String, arguments: [String]) {
        self.init(subprocess: Subprocess(executablePath: executablePath, arguments: arguments))
    }

    public init(subprocess: Subprocess) {
        self.subprocess = subprocess
    }

    /// Runs the subprocess and returns its standard output publisher.
    public func run() -> AnyPublisher<String, Error> {
        let publisher = subprocess.standardOutput
        subprocess.run()
        return publisher
    }
}
