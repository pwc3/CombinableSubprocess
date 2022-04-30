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

 To wait for the subprocess to terminate, use the `termination` property which is a `Future`. If the subprocess completed successfully, the `Future` will complete without an error. If the subprocess fails, the `Future` will fail with a corresponding `SubprocessError` value.

 To observe the subprocess output, use the `stdout` and `stderr` publishers. The first time an output publisher is referenced, the corresponding output stream is redirected to the resulting publisher. This must be done before the subprocess is launched (i.e., before `run()` is called). If you do not reference an output publisher, that output stream will be inherited from the creating process.

 It is possible to pipe standard output from one subprocess into the standard input of another process using the `pipeStandardOutput(toStandardInput:)` function.
 */
public final class Subprocess {

    private let receiver: Process

    // Used to track when the process has terminated and stdout/stderr have been fully
    // read (only if a publisher has been attached).
    private let group = DispatchGroup()

    // The queue used in calls to group.notify(queue:work:).
    private let notifyQueue: DispatchQueue

    // The promise used to resolve the termination future.
    private let terminationPromise: Future<Void, SubprocessError>.Promise

    /// Signals when the process has terminated.
    public let termination: Future<Void, SubprocessError>

    /// Maximum size of an output publisher's line buffer.
    public let lineBufferMaxSize: Int

    // MARK: - Initializer

    /// Creates a new subprocess.
    ///
    /// - Parameters:
    ///   - executableURL: The receiver's executable.
    ///   - arguments: The command arguments that the system uses to launch the executable.
    ///   - currentDirectoryURL: The current directory for the receiver.
    ///   - environment: The environment for the receiver.
    ///   - qualityOfService: The default quality of service level the system applies to operations the subprocess executes.
    ///   - lineBufferMaxSize: The maximum size of an output publisher's line buffer.
    public init(
        executableURL: URL,
        arguments: [String],
        currentDirectoryURL: URL? = nil,
        environment: [String : String]? = nil,
        qualityOfService: DispatchQoS = .default,
        lineBufferMaxSize: Int = .max
    ) {
        receiver = Process()
        receiver.executableURL = executableURL
        receiver.arguments = arguments

        // Apply the qualityOfService provided for the DispatchQueue to the process.
        switch qualityOfService.qosClass {
        case .userInitiated:
            receiver.qualityOfService = .userInitiated

        case .userInteractive:
            receiver.qualityOfService = .userInteractive

        case .utility:
            receiver.qualityOfService = .utility

        case .background:
            receiver.qualityOfService = .background

        case .unspecified, .default:
            receiver.qualityOfService = .default

        @unknown default:
            receiver.qualityOfService = .default
        }

        notifyQueue = DispatchQueue(
            label: "SubprocessQueue",
            qos: qualityOfService,
            attributes: [],
            autoreleaseFrequency: .workItem,
            target: nil
        )
        self.lineBufferMaxSize = lineBufferMaxSize

        (termination, terminationPromise) = Future.promise()

        currentDirectoryURL.map { receiver.currentDirectoryURL = $0 }
        environment.map { receiver.environment = $0 }
    }

    /// Creates a new subprocess using String paths instead of URLs.
    public convenience init(
        executablePath: String,
        arguments: [String],
        currentDirectoryPath: String? = nil,
        environment: [String : String]? = nil,
        qualityOfService: DispatchQoS = .default,
        lineBufferMaxSize: Int = .max
    ) {
        self.init(
            executableURL: URL(fileURLWithPath: executablePath),
            arguments: arguments,
            currentDirectoryURL: currentDirectoryPath.map { URL(fileURLWithPath: $0) },
            environment: environment,
            qualityOfService: qualityOfService,
            lineBufferMaxSize: lineBufferMaxSize
        )
    }

    /// Runs the subprocess.
    public func run() throws {
        // Enter the dispatch group.
        group.enter()

        // When the process terminates, leave the dispatch group.
        receiver.terminationHandler = { [group] proc in
            group.leave()
            proc.terminationHandler = nil
        }

        // When all of the work items in the dispatch group finish, the notify function is called.
        // Here, we fulfill the termination promise with a value encapsulating the termination
        // status and reason.
        group.notify(queue: notifyQueue) { [receiver, terminationPromise] in
            terminationPromise(Self.resultForCompletedProcess(receiver))
        }

        // Actually start the process.
        try receiver.run()
    }

    // MARK: - Output Streams

    /// Routes the process's standard output to a publisher.
    public lazy var standardOutput: AnyPublisher<String, SubprocessError> = {
        let stdout = Pipe()
        let publisher = outputPublisher(for: stdout)
        receiver.standardOutput = stdout
        return publisher.eraseToAnyPublisher()
    }()

    /// Routes the process's standard error to a publisher.
    public lazy var standardError: AnyPublisher<String, SubprocessError> = {
        let stderr = Pipe()
        let publisher = outputPublisher(for: stderr)
        receiver.standardError = stderr
        return publisher.eraseToAnyPublisher()
    }()

    private func outputPublisher(for pipe: Pipe) -> AnyPublisher<String, SubprocessError> {
        // We'll start with a pass through subject that will publish each of the lines read
        // from the pipe.
        let subject = PassthroughSubject<String, SubprocessError>()

        // Enter the dispatch group. This allows to continue processing buffered output
        // after the process has finished.
        group.enter()

        Task {
            // Loop over the lines emitted by the pipe's read handle's async sequence.
            // This will terminate when all of the pipe's data has been read and the
            // pipe is closed.
            for try await line in pipe.fileHandleForReading.bytes.lines {
                subject.send(line)
            }

            // When we reach this point, the process is complete and we can leave the
            // dispatch group.
            group.leave()
        }

        // When all of the work items in the dispatch group finish, the notify function is called.
        // Here, we send the completion out on the publisher.
        group.notify(queue: notifyQueue) { [receiver] in
            switch Self.resultForCompletedProcess(receiver) {
            case .success:
                subject.send(completion: .finished)

            case .failure(let error):
                subject.send(completion: .failure(error))
            }
        }

        // Buffer the subject so downstream subscribers can apply back pressure. If we don't
        // buffer the subject, lines could potentially be lost.
        //
        // If the buffer becomes full, the publisher fails with a .bufferOverrun error.
        return subject
            .buffer(
                size: lineBufferMaxSize,
                prefetch: .byRequest,
                whenFull: .customError {
                    SubprocessError.bufferOverrun
                }
            )
            .eraseToAnyPublisher()
    }

    /// Connects standard output of this process to standard input of the specified process.
    /// Allows for the construction of process pipelines.
    public func pipeStandardOutput(toStandardInput other: Subprocess) {
        let pipe = Pipe()
        receiver.standardOutput = pipe
        other.receiver.standardInput = pipe
    }

    /// Build a Result value for the specified completed process. It is a precondition that the
    /// process has finished running.
    private static func resultForCompletedProcess(_ process: Process) -> Result<Void, SubprocessError> {
        precondition(!process.isRunning)

        if process.terminationReason == .uncaughtSignal {
            return .failure(.uncaughtSignal)
        }
        else if process.terminationStatus != 0 {
            return .failure(.nonZeroTerminationStatus(process.terminationStatus))
        }
        else {
            return .success(())
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
        let executable = receiver.executableURL?.lastPathComponent ?? "(nil)"
        let arguments = (receiver.arguments ?? []).joined(separator: " ")

        return "Subprocess(\(executable) \(arguments))"
    }
}
