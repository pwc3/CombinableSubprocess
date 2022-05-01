# CombinableSubprocess

This package provides a `Subprocess` class that enables observation of child processes using Combine.

## Basic usage

At minimum, you need to create a `Subprocess` and call `run()` on it. For example, to run `seq 3`:

```swift
import CombinableSubprocess

let subprocess = Subprocess(
    executablePath: "/usr/bin/seq",
    arguments: ["3"]
)

try subprocess.run()
```

The subprocess will inherit the caller's standard output and standard error output streams. Running in Xcode, any standard output or standard error will write to the console. Thus, in this example, the following is printed to the console:

```
1
2
3
```

## Observing when a subprocess terminates

You can use the `termination` property to observe when a subprocess terminates. This is a Combine `Future` that has an output type of `Void` and a failure type of `SubprocessError`.

Continuing with the example above, we can observe the termination of `seq 3` as follows:

```swift
import Combine
import CombinableSubprocess

var cancellables: Set<AnyCancellable> = []

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
}, receiveValue: {})
.store(in: &cancellables)
```

If the subprocess completes with a non-zero termination status, the completion value will be a `failure` with a `SubprocessError.nonZeroTerminationStatus` indicating the status code.

## Observing output

You can use `standardOutput` and `standardError` to redirect the output streams of a subprocess into string publishers. Note that this must be done before running the process or a runtime exception will be thrown.

Both `standardOutput` and `standardError` are of type `AnyPublisher<String, SubprocessError>`. They each publish a sequence of strings representing to the lines of text printed to the corresponding output stream. Each publisher will complete after the process terminates and all output has been published. If the process terminated with an error, the publisher will complete with that error. As such, it is not necessary to observe both `termination` and an output stream -- both complete with the same value.

For example:

```swift
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
```

This will output:

```
Received Int: 1
Received Int: 2
Received Int: 3
```

## Subprocess pipelines

It is possible to pipe the standard output from one subprocess into the standard input of another process. For example, this is the equivalent to running `seq 100 | wc -l`:

```swift
let cat = Subprocess(
    executablePath: "/usr/bin/seq",
    arguments: ["100"]
)

let wc = Subprocess(
    executablePath: "/usr/bin/wc",
    arguments: ["-l"]
)

cat.pipeStandardOutput(toStandardInput: wc)

wc.standardOutput
    .sink(receiveCompletion: { completion in
        // ...
    }, receiveValue: { text in
        print("Received value:", text.trimmingCharacters(in: .whitespaces))
    })
    .store(in: &cancellables)

try cat.run()
try wc.run()
``` 

This will output:

```
Received value: 100
```
