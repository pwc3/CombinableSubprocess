import Combine
import Foundation

public enum SubprocessError: Error, Equatable {
    case bufferOverrun
    case uncaughtSignal
    case terminationStatus(Int32)
}

public class Subprocess {

    public struct Termination {
        public var status: Int32
        public var reason: Process.TerminationReason
    }

    private let process: Process

    private let group = DispatchGroup()

    private let notifyQueue: DispatchQueue

    private let terminationPromise: Future<Termination, Never>.Promise

    public let termination: Future<Termination, Never>

    // MARK: - Initializer

    public init(
        executableURL: URL,
        arguments: [String],
        currentDirectoryURL: URL? = nil,
        environment: [String : String]? = nil,
        qualityOfService: DispatchQoS = .default
    ) {
        process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        notifyQueue = DispatchQueue(
            label: "SubprocessQueue",
            qos: qualityOfService,
            attributes: [],
            autoreleaseFrequency: .workItem,
            target: nil
        )

        (termination, terminationPromise) = Future.promise()

        currentDirectoryURL.map { process.currentDirectoryURL = $0 }
        environment.map { process.environment = $0 }
    }

    public convenience init(
        executablePath: String,
        arguments: [String],
        currentDirectoryPath: String? = nil,
        environment: [String : String]? = nil,
        qualityOfService: DispatchQoS = .default
    ) {
        self.init(
            executableURL: URL(fileURLWithPath: executablePath),
            arguments: arguments,
            currentDirectoryURL: currentDirectoryPath.map { URL(fileURLWithPath: $0) },
            environment: environment,
            qualityOfService: qualityOfService
        )
    }

    // MARK: - Configuration

    public var processIdentifier: Int32 {
        process.processIdentifier
    }

    public var isRunning: Bool {
        process.isRunning
    }

    public var terminationStatus: Int32 {
        process.terminationStatus
    }

    public var terminationReason: Process.TerminationReason {
        process.terminationReason
    }

    // MARK: - Control

    public func interrupt() {
        process.interrupt()
    }

    public func resume() -> Bool {
        process.resume()
    }

    public func suspend() -> Bool {
        process.suspend()
    }

    public func terminate() {
        process.terminate()
    }

    public func run() throws {
        group.enter()

        process.terminationHandler = { [group] proc in
            group.leave()
            proc.terminationHandler = nil
        }

        group.notify(queue: notifyQueue) { [process, terminationPromise] in
            terminationPromise(
                .success(
                    Termination(
                        status: process.terminationStatus,
                        reason: process.terminationReason
                    )
                )
            )
        }

        try process.run()
    }

    // MARK: - Output Streams

    public lazy var stdout: AnyPublisher<String, SubprocessError> = {
        let stdout = Pipe()
        let publisher = outputPublisher(for: stdout)
        process.standardOutput = stdout
        return publisher.eraseToAnyPublisher()
    }()

    public lazy var stderr: AnyPublisher<String, SubprocessError> = {
        let stderr = Pipe()
        let publisher = outputPublisher(for: stderr)
        process.standardError = stderr
        return publisher.eraseToAnyPublisher()
    }()

    private func outputPublisher(for pipe: Pipe) -> AnyPublisher<String, SubprocessError> {
        let subject = PassthroughSubject<String, SubprocessError>()
        group.enter()

        Task {
            for try await line in pipe.fileHandleForReading.bytes.lines {
                subject.send(line)
            }

            group.leave()
        }

        group.notify(queue: notifyQueue) { [process] in
            precondition(!process.isRunning)

            if process.terminationReason == .uncaughtSignal {
                subject.send(completion: .failure(.uncaughtSignal))
            }
            else if process.terminationStatus != 0 {
                subject.send(completion: .failure(.terminationStatus(process.terminationStatus)))
            }
            else {
                subject.send(completion: .finished)
            }
        }

        return subject
            .buffer(
                size: .max,
                prefetch: .byRequest,
                whenFull: .customError {
                    SubprocessError.bufferOverrun
                }
            )
            .eraseToAnyPublisher()
    }

    public func pipeStdout(toStdin other: Subprocess) {
        let pipe = Pipe()
        process.standardOutput = pipe
        other.process.standardInput = pipe
    }
}

extension Subprocess: CustomDebugStringConvertible {
    public var debugDescription: String {
        let executable = process.executableURL?.lastPathComponent ?? "(nil)"
        let arguments = (process.arguments ?? []).joined(separator: " ")
        return "Subprocess(\(executable) \(arguments))"
    }
}
