//
//  Subprocess.swift
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

/// Represents an error that can be thrown by a subprocess.
public enum SubprocessError: Error, Equatable {

    /// The subprocess exited due to an uncaught signal.
    case uncaughtSignal

    /// The subprocess exited with a non-zero termination status.
    case nonZeroTerminationStatus(Int32)

    /// The output publisher failed due to a buffer overrun.
    case bufferOverrun
}

/**
 An object that represents a subprocess of the current process. Provides a wrapper over `Foundation.Process` that exposes Combine publishers that allow callers to observe standard output, standard error, and process termination.

 At minimum, you need to call `run()` on a subprocess object in order to begin execution.

 To wait for the subprocess to terminate, use the `termination` property which is a `Future`. If the subprocess completed successfully, the `Future` will complete without an error. If the subprocess fails, the `Future` will fail.

 To observe the subprocess output, use the `standardOutput` and `standardError` publishers. The first time an output publisher is referenced, the corresponding output stream is redirected to the resulting publisher. This must be done before the subprocess is launched (i.e., before `run()` is called). If you do not reference an output publisher, that output stream will be inherited from the creating process.

 It is possible to pipe standard output from one subprocess into the standard input of another process using the `pipeStandardOutput(toStandardInput:)` function.
 */
public final class Subprocess {
    private let receiver: Process

    private let group = DispatchGroup()

    private let notifyQueue = DispatchQueue(
        label: "Subprocess2Queue",
        qos: .default,
        attributes: [],
        autoreleaseFrequency: .workItem,
        target: nil
    )

    /// Signals when the process has terminated.
    public let termination: Future<Void, Error>

    // The promise used to resolve the termination future.
    private let terminationPromise: Future<Void, Error>.Promise

    private var cancellables: Set<AnyCancellable> = []

    // MARK: - Initializers

    /// Creates a new subprocess.
    ///
    /// - Parameters:
    ///   - executableURL: The receiver's executable.
    ///   - arguments: The command arguments that the system uses to launch the executable.
    ///   - currentDirectoryURL: The current directory for the receiver.
    ///   - environment: The environment for the receiver.
    public init(
        executableURL: URL,
        arguments: [String],
        currentDirectoryURL: URL? = nil,
        environment: [String : String]? = nil
    ) {
        receiver = Process()
        receiver.executableURL = executableURL
        receiver.arguments = arguments

        (termination, terminationPromise) = Future.promise()

        receiver.currentDirectoryURL = currentDirectoryURL
        receiver.environment = environment
    }

    /// Creates a new subprocess using String paths instead of URLs.
    public convenience init(
        executablePath: String,
        arguments: [String],
        currentDirectoryPath: String? = nil,
        environment: [String : String]? = nil
    ) {
        self.init(
            executableURL: URL(fileURLWithPath: executablePath),
            arguments: arguments,
            currentDirectoryURL: currentDirectoryPath.map { URL(fileURLWithPath: $0) },
            environment: environment
        )
    }

    // MARK: - Output Streams

    /// Routes the process's standard output to a publisher.
    public lazy var standardOutput: AnyPublisher<String, Error> = {
        let (pipe, publisher) = createOutputPipe()
        receiver.standardOutput = pipe
        return publisher
    }()

    /// Routes the process's standard error to a publisher.
    public lazy var standardError: AnyPublisher<String, Error> = {
        let (pipe, publisher) = createOutputPipe()
        receiver.standardError = pipe
        return publisher
    }()

    /// Connects standard output of this process to standard input of the specified process.
    /// Allows for the construction of process pipelines.
    public func pipeStandardOutput(toStandardInput other: Subprocess) {
        let pipe = Pipe()
        receiver.standardOutput = pipe
        other.receiver.standardInput = pipe
    }

    private func createOutputPipe() -> (Pipe, AnyPublisher<String, Error>) {
        let pipe = Pipe()
        let subject = PassthroughSubject<String, Error>()

        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if let string = String(data: data, encoding: .utf8) {
                subject.send(string)
            }
            else {
                // If this happens, we'll need to reconsider the buffering strateggy.
                preconditionFailure("ERROR: Could not create string from input data. Dropping \(data.count) byte(s).")
            }
        }

        termination
            .sink(receiveCompletion: {
                subject.send(completion: $0)
            }, receiveValue: { _ in })
            .store(in: &cancellables)

        let publisher = subject
            .flatMap { string in
                // Since multiple lines may be read, split by line and republish.
                string.components(separatedBy: .newlines).publisher
            }
            .buffer(
                size: .max,
                prefetch: .byRequest,
                whenFull: .customError {
                    SubprocessError.bufferOverrun
                }
            )
            .eraseToAnyPublisher()

        return (pipe, publisher)
    }

    /// Runs the subprocess.
    public func run() {
        receiver.terminationHandler = { [terminationPromise] proc in
            let error = Self.error(for: proc)
            terminationPromise(error.map { .failure($0) } ?? .success(()))
        }

        do {
            try receiver.run()
        }
        catch {
            terminationPromise(.failure(error))
        }
    }

    private static func error(for process: Process) -> Error? {
        precondition(!process.isRunning)

        if process.terminationReason == .uncaughtSignal {
            return SubprocessError.uncaughtSignal
        }
        else if process.terminationStatus != 0 {
            return SubprocessError.nonZeroTerminationStatus(process.terminationStatus)
        }
        else {
            return nil
        }
    }
}

// MARK: - Foundation.Process passthrough functions

public extension Subprocess {

    /// The receiver's process identifier.
    ///
    /// - SeeAlso: Process.processIdentifier
    var processIdentifier: Int32 {
        receiver.processIdentifier
    }

    /// A status that indicates whether the receiver is still running.
    ///
    /// - SeeAlso: Process.isRunning
    var isRunning: Bool {
        receiver.isRunning
    }

    /// The exit status the receiver's executable returns.
    ///
    /// - SeeAlso: Process.terminationStatus
    var terminationStatus: Int32 {
        receiver.terminationStatus
    }

    /// The reason the system terminated the task.
    ///
    /// - SeeAlso: Process.terminationReason
    var terminationReason: Process.TerminationReason {
        receiver.terminationReason
    }

    /// Sends an interrupt signal to its receiver and all of its subprocesses.
    ///
    /// - SeeAlso: Process.interrupt()
    func interrupt() {
        receiver.interrupt()
    }

    /// Resumes execution of a suspended subprocess.
    ///
    /// - Returns: `true` if the receiver was able to resume execution, `false` otherwise.
    /// - SeeAlso: Process.resume()
    func resume() -> Bool {
        receiver.resume()
    }

    /// Suspends execution of the receiver.
    ///
    /// - Returns: `true` if the receiver was successfully suspended, `false` otherwise.
    /// - SeeAlso: Process.suspend()
    func suspend() -> Bool {
        receiver.suspend()
    }

    /// Sends a terminate signal to the receiver and all of its subprocesses.
    ///
    /// - SeeAlso: Process.terminate()
    func terminate() {
        receiver.terminate()
    }
}

extension Subprocess: CustomDebugStringConvertible {
    public var debugDescription: String {
        let executable = receiver.executableURL?.description ?? "(nil)"
        let arguments = (receiver.arguments ?? []).joined(separator: " ")

        return "Subprocess(\(executable) \(arguments))"
    }
}
