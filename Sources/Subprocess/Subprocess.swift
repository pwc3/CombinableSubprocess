import Combine
import Foundation

public enum SubprocessError: Error {
    case bufferOverrun
    case uncaughtSignal
    case terminationStatus(Int32)
    case generalError(Error)
}

public class Subprocess {
    let reference: Process

    private let group = DispatchGroup()

    private let terminationHandler: ((Subprocess) -> Void)?

    private let notifyQueue: DispatchQueue

    // MARK: - Initializer

    public init(
        executableURL: URL,
        arguments: [String],
        currentDirectoryURL: URL? = nil,
        environment: [String : String]? = nil,
        terminationHandler: ((Subprocess) -> Void)?,
        qualityOfService: DispatchQoS = .default
    ) {
        reference = Process()
        reference.executableURL = executableURL
        reference.arguments = arguments
        notifyQueue = DispatchQueue(
            label: "SubprocessQueue",
            qos: qualityOfService,
            attributes: [],
            autoreleaseFrequency: .workItem,
            target: nil
        )
        self.terminationHandler = terminationHandler

        currentDirectoryURL.map { reference.currentDirectoryURL = $0 }
        environment.map { reference.environment = $0 }
    }

    public convenience init(
        executablePath: String,
        arguments: [String],
        currentDirectoryPath: String? = nil,
        environment: [String : String]? = nil,
        terminationHandler: ((Subprocess) -> Void)?,
        qualityOfService: DispatchQoS = .default
    ) {
        self.init(
            executableURL: URL(fileURLWithPath: executablePath),
            arguments: arguments,
            currentDirectoryURL: currentDirectoryPath.map { URL(fileURLWithPath: $0) },
            environment: environment,
            terminationHandler: terminationHandler,
            qualityOfService: qualityOfService
        )
    }

    // MARK: - Configuration

    public var processIdentifier: Int32 {
        reference.processIdentifier
    }

    public var isRunning: Bool {
        reference.isRunning
    }

    public var terminationStatus: Int32 {
        reference.terminationStatus
    }

    public var terminationReason: Process.TerminationReason {
        reference.terminationReason
    }

    // MARK: - Control

    public func interrupt() {
        reference.interrupt()
    }

    public func resume() -> Bool {
        reference.resume()
    }

    public func suspend() -> Bool {
        reference.suspend()
    }

    public func terminate() {
        reference.terminate()
    }

    public func run() throws {
        group.enter()

        reference.terminationHandler = { [group] proc in
            group.leave()
            proc.terminationHandler = nil
        }

        group.notify(queue: .global()) { [weak self] in
            self.map {
                $0.terminationHandler?($0)
            }
        }

        try reference.run()
    }

    // MARK: - Output Streams

    public lazy var stdout: AnyPublisher<String, SubprocessError> = {
        let stdout = Pipe()
        let publisher = outputPublisher(for: stdout)
        reference.standardOutput = stdout
        return publisher.eraseToAnyPublisher()
    }()

    public lazy var stderr: AnyPublisher<String, SubprocessError> = {
        let stderr = Pipe()
        let publisher = outputPublisher(for: stderr)
        reference.standardError = stderr
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

        group.notify(queue: .global()) { [reference] in
            if reference.terminationReason == .uncaughtSignal {
                subject.send(completion: .failure(.uncaughtSignal))
            }
            else if reference.terminationStatus != 0 {
                subject.send(completion: .failure(.terminationStatus(reference.terminationStatus)))
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
}

