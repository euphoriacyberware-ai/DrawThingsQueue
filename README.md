# DrawThingsQueue

A Swift framework that provides a queue-based API for image generation using [Draw Things](https://drawthings.ai). Enqueue generation requests, observe progress with live preview images, and retrieve results using standard Swift concurrency or SwiftUI bindings.

## Requirements

- macOS 14+ / iOS 17+
- Swift 5.9+
- A running [Draw Things](https://drawthings.ai) gRPC server

## Installation

### Swift Package Manager

Add DrawThingsQueue to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/euphoriacyberware-ai/DrawThingsQueue.git", branch: "main"),
]
```

Then add it to your target's dependencies:

```swift
.target(
    name: "YourApp",
    dependencies: [
        .product(name: "DrawThingsQueue", package: "DrawThingsQueue"),
    ]
)
```

Or in Xcode: **File → Add Package Dependencies** and enter the repository URL.

## Setup

```swift
import DrawThingsQueue

let queue = try DrawThingsQueue(address: "localhost:7859")
```

The `address` parameter is the host and port of the Draw Things gRPC server. TLS is enabled by default; pass `useTLS: false` for plaintext connections.

### With persistence

Pass a `QueueStorage` instance to persist pending requests across app restarts:

```swift
let storage = QueueStorage()  // Uses default Application Support location
let queue = try DrawThingsQueue(address: "localhost:7859", storage: storage)

// Restore any requests saved from a previous session
queue.loadPersistedRequests()
```

You can also specify a custom file location:

```swift
let storage = QueueStorage(fileURL: myCustomURL)
```

## Enqueuing Requests

### Basic text-to-image

```swift
queue.enqueue(prompt: "a cat sitting on a windowsill, oil painting")
```

### With a custom name

Requests auto-generate a display name from the prompt. You can override this:

```swift
queue.enqueue(prompt: "a cat sitting on a windowsill", name: "Cat Portrait")
```

### With configuration

```swift
var config = DrawThingsConfiguration()
config.width = 1024
config.height = 1024
config.steps = 30
config.sampler = .eulera
config.guidanceScale = 7.5
config.model = "sd_xl_base_1.0.safetensors"

let request = queue.enqueue(
    prompt: "a mountain landscape at sunset",
    negativePrompt: "blurry, low quality",
    configuration: config
)
```

### Image-to-image

```swift
let inputImage: NSImage = ...  // or UIImage on iOS

queue.enqueue(
    prompt: "transform into watercolor style",
    configuration: DrawThingsConfiguration(strength: 0.75),
    image: inputImage
)
```

### With LoRAs and ControlNet

```swift
var config = DrawThingsConfiguration(
    loras: [LoRAConfig(file: "detail_enhancer.safetensors", weight: 0.8)],
    controls: [ControlConfig(file: "depth_model.safetensors", weight: 1.0)]
)

queue.enqueue(prompt: "detailed portrait", configuration: config)
```

### With control hints (HintBuilder)

Use the `HintBuilder` for a convenient chainable API to construct ControlNet hints:

```swift
let depthMapData: Data = ...
let poseData: Data = ...

let hints = HintBuilder()
    .addDepthMap(depthMapData, weight: 1.0)
    .addPose(poseData, weight: 0.8)
    .build()

queue.enqueue(
    prompt: "a person standing in a room",
    configuration: config,
    hints: hints
)
```

Available hint methods: `addDepthMap`, `addPose`, `addCannyEdges`, `addScribble`, `addColorReference`, `addLineArt`, `addMoodboardImage`, `addMoodboardImages`. For custom types, use `addHint(type:imageData:weight:)`.

You can also construct `HintProto` values directly:

```swift
let tensorData = try ImageHelpers.imageToDTTensor(inputImage, forceRGB: true)
var tensor = TensorAndWeight()
tensor.tensor = tensorData
tensor.weight = 1.0

var hint = HintProto()
hint.hintType = "shuffle"
hint.tensors = [tensor]

queue.enqueue(
    prompt: "reimagine this scene",
    configuration: config,
    hints: [hint]
)
```

### Batch enqueue

```swift
let requests = [
    GenerationRequest(prompt: "a red rose"),
    GenerationRequest(prompt: "a blue sky"),
    GenerationRequest(prompt: "a green forest"),
]
queue.enqueue(requests)
```

Requests are processed sequentially in FIFO order. The queue auto-starts processing as soon as the first request is enqueued.

## Retrieving Results

### By request ID

```swift
let request = queue.enqueue(prompt: "a cat")

// Later...
if let result = queue.result(for: request.id) {
    let images = result.images  // [NSImage] on macOS, [UIImage] on iOS
}
```

### Check status

```swift
switch queue.status(for: request.id) {
case .pending(let position):
    print("Waiting in queue at position \(position)")
case .generating:
    print("Currently generating...")
case .completed(let result):
    print("Done! Got \(result.images.count) image(s)")
case .failed(let error):
    print("Failed: \(error.underlyingError)")
case .cancelled:
    print("Was cancelled")
case nil:
    print("Unknown request")
}
```

### AsyncStream (for async/await consumers)

```swift
Task {
    for await result in queue.results {
        print("Completed: \(result.request.prompt)")
        let images = result.images
        // Process images...
    }
}
```

## Observing Progress

During generation, `currentProgress` provides the generation stage, a live preview image, and step-based progress tracking.

```swift
if let progress = queue.currentProgress {
    // Stage description
    print(progress.stage.description)  // e.g. "Generating image (step 12)..."

    // Step-based progress
    print("Step \(progress.currentStep) of \(progress.totalSteps)")
    print("\(progress.progressPercentage)% complete")

    // Progress fraction (0.0 to 1.0) for progress bars
    ProgressView(value: progress.progressFraction)

    // Live preview image
    if let preview = progress.previewImage {
        // Display the in-progress preview image
    }
}
```

`GenerationStage` cases include: `.textEncoding`, `.imageEncoding`, `.sampling(step:)`, `.imageDecoding`, `.secondPassImageEncoding`, `.secondPassSampling(step:)`, `.secondPassImageDecoding`, `.faceRestoration`, `.imageUpscaling`.

## Pause and Resume

```swift
// Pause processing (current generation finishes, but no new jobs start)
queue.pause()

// Resume processing
queue.resume()

// Check state
if queue.isPaused {
    print("Queue is paused")
}
```

The queue also auto-pauses on connectivity errors and stores the reason in `lastError`:

```swift
if let error = queue.lastError {
    print("Paused due to: \(error)")
}

// Resume after reconnecting
queue.resume()  // Also clears lastError
```

## Retry Failed Requests

```swift
// Check if a failed request can be retried (default max: 3 retries)
if queue.canRetry(for: request.id) {
    queue.retry(request.id)
}

// Check how many times a request has been retried
let count = queue.retryCount(for: request.id)

// Configure max retry attempts
queue.maxRetries = 5
```

## Reordering

Reorder pending requests in the queue (useful for drag-and-drop in SwiftUI lists):

```swift
queue.moveRequests(from: IndexSet(integer: 0), to: 3)
```

## Event Publisher

Subscribe to lifecycle events using Combine:

```swift
import Combine

var cancellables = Set<AnyCancellable>()

queue.events
    .sink { event in
        switch event {
        case .requestAdded(let request):
            print("Added: \(request.name)")
        case .requestStarted(let request):
            print("Started: \(request.name)")
        case .requestProgress(let request, let progress):
            print("\(request.name): \(progress.progressPercentage)%")
        case .requestCompleted(let result):
            print("Completed: \(result.request.name)")
        case .requestFailed(let error):
            print("Failed: \(error.underlyingError)")
        case .requestCancelled(let id):
            print("Cancelled: \(id)")
        case .requestRemoved(let id):
            print("Removed: \(id)")
        }
    }
    .store(in: &cancellables)
```

## SwiftUI Integration

`DrawThingsQueue` and `GenerationProgress` are both `ObservableObject` with `@Published` properties, so they work directly with SwiftUI:

```swift
struct GenerationView: View {
    @StateObject var queue: DrawThingsQueue

    var body: some View {
        VStack {
            // Show preview during generation
            if let preview = queue.currentProgress?.previewImage {
                Image(nsImage: preview)  // Use Image(uiImage:) on iOS
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            }

            // Show progress bar and text
            if let progress = queue.currentProgress {
                ProgressView(value: progress.progressFraction)
                Text(progress.stage.description)
            }

            // Queue status
            Text("\(queue.pendingRequests.count) pending")
            Text("\(queue.completedResults.count) completed")

            if queue.isPaused {
                Label("Paused", systemImage: "pause.circle")
                if let error = queue.lastError {
                    Text(error).foregroundStyle(.secondary)
                }
                Button("Resume") { queue.resume() }
            }

            // Show completed images
            ForEach(queue.completedResults) { result in
                Image(nsImage: result.images.first!)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            }
        }
    }
}
```

## Cancellation

```swift
// Cancel a specific request (pending or in-progress)
queue.cancel(id: request.id)

// Cancel everything
queue.cancelAll()

// Remove a specific request from any state (pending, completed, or failed)
queue.remove(request.id)
```

Cancelling a pending request removes it from the queue. Cancelling the in-progress request signals cooperative cancellation to the underlying gRPC call.

## Housekeeping

```swift
// Limit how many completed results are kept in memory (default: 50)
queue.maxCompletedResults = 20

// Clear stored results and errors
queue.clearCompleted()
queue.clearErrors()

// Clear everything (cancels pending, clears completed and errors)
queue.clearAll()

// Clear persisted queue data from disk
storage.clearStorage()
```

## Published Properties

| Property | Type | Description |
|---|---|---|
| `pendingRequests` | `[GenerationRequest]` | Queued requests not yet started |
| `currentRequest` | `GenerationRequest?` | The request currently being generated |
| `currentProgress` | `GenerationProgress?` | Stage, preview image, and step progress for current generation |
| `isProcessing` | `Bool` | Whether the queue is actively generating |
| `completedResults` | `[GenerationResult]` | Finished results (capped at `maxCompletedResults`) |
| `errors` | `[GenerationError]` | Failed generation attempts |
| `isPaused` | `Bool` | Whether the queue is paused |
| `lastError` | `String?` | Reason for the most recent auto-pause (e.g. connectivity loss) |

## Types Reference

### GenerationRequest

| Property | Type | Description |
|---|---|---|
| `id` | `UUID` | Unique identifier |
| `prompt` | `String` | The text prompt |
| `negativePrompt` | `String` | Negative prompt (default: `""`) |
| `configuration` | `DrawThingsConfiguration` | Generation parameters |
| `image` | `PlatformImage?` | Input image for img2img |
| `mask` | `PlatformImage?` | Mask for inpainting |
| `hints` | `[HintProto]` | ControlNet hint tensors (e.g. shuffle, depth) |
| `name` | `String` | Display name (auto-generated from prompt if not provided) |
| `createdAt` | `Date` | When the request was created |

### GenerationResult

| Property | Type | Description |
|---|---|---|
| `id` | `UUID` | Matches the request ID |
| `images` | `[PlatformImage]` | Generated images |
| `request` | `GenerationRequest` | The original request |
| `completedAt` | `Date` | When generation finished |

### GenerationError

| Property | Type | Description |
|---|---|---|
| `id` | `UUID` | Matches the request ID |
| `request` | `GenerationRequest` | The original request |
| `underlyingError` | `Error` | The error that occurred |
| `occurredAt` | `Date` | When the error happened |

### GenerationProgress

| Property | Type | Description |
|---|---|---|
| `stage` | `GenerationStage` | Current generation stage |
| `previewImage` | `PlatformImage?` | Live preview image |
| `currentStep` | `Int` | Current sampling step |
| `totalSteps` | `Int` | Total sampling steps |
| `progressFraction` | `Double` | Progress from 0.0 to 1.0 |
| `progressPercentage` | `Int` | Progress from 0 to 100 |

### HintBuilder

A chainable builder for constructing `[HintProto]` arrays:

| Method | Description |
|---|---|
| `addDepthMap(_:weight:)` | Add a depth map hint |
| `addPose(_:weight:)` | Add a pose estimation hint |
| `addCannyEdges(_:weight:)` | Add a Canny edge detection hint |
| `addScribble(_:weight:)` | Add a scribble hint |
| `addColorReference(_:weight:)` | Add a color reference hint |
| `addLineArt(_:weight:)` | Add a line art hint |
| `addMoodboardImage(_:weight:)` | Add a single moodboard/shuffle image |
| `addMoodboardImages(_:weight:)` | Add multiple moodboard/shuffle images |
| `addHint(type:imageData:weight:)` | Add a hint with a custom type string |
| `build()` | Build and return the `[HintProto]` array |

### JobEvent

| Case | Associated Value | Description |
|---|---|---|
| `.requestAdded` | `GenerationRequest` | A request was enqueued |
| `.requestStarted` | `GenerationRequest` | A request began generating |
| `.requestProgress` | `(GenerationRequest, GenerationProgress)` | Progress update during generation |
| `.requestCompleted` | `GenerationResult` | A request finished successfully |
| `.requestFailed` | `GenerationError` | A request failed |
| `.requestCancelled` | `UUID` | A request was cancelled |
| `.requestRemoved` | `UUID` | A request was removed from any state |

## Dependencies

- [DrawThingsClient](https://github.com/euphoriacyberware-ai/DT-gRPC-Swift-Client) (DT-gRPC-Swift-Client)

## License

See [LICENSE](LICENSE) for details.
