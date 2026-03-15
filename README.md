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

## Enqueuing Requests

### Basic text-to-image

```swift
queue.enqueue(prompt: "a cat sitting on a windowsill, oil painting")
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

### With control hints

Hints provide ControlNet input tensors (e.g. shuffle, depth, pose) directly to the generation request. Each `HintProto` specifies a `hintType` string and an array of `TensorAndWeight` entries containing the tensor data and its weight.

```swift
// Build a shuffle hint from an input image
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
let prompts = ["a red rose", "a blue sky", "a green forest"]
for prompt in prompts {
    queue.enqueue(prompt: prompt)
}
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

During generation, `currentProgress` provides both the generation stage and a live preview image.

```swift
// Check the current stage
if let progress = queue.currentProgress {
    print(progress.stage.description)  // e.g. "Generating image (step 12)..."

    if let preview = progress.previewImage {
        // Display the in-progress preview image
    }
}
```

`GenerationStage` cases include: `.textEncoding`, `.imageEncoding`, `.sampling(step:)`, `.imageDecoding`, `.secondPassImageEncoding`, `.secondPassSampling(step:)`, `.secondPassImageDecoding`, `.faceRestoration`, `.imageUpscaling`.

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

            // Show progress text
            if let stage = queue.currentProgress?.stage {
                Text(stage.description)
            }

            // Queue status
            Text("\(queue.pendingRequests.count) pending")
            Text("\(queue.completedResults.count) completed")

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

### Published properties

| Property | Type | Description |
|---|---|---|
| `pendingRequests` | `[GenerationRequest]` | Queued requests not yet started |
| `currentRequest` | `GenerationRequest?` | The request currently being generated |
| `currentProgress` | `GenerationProgress?` | Stage and preview image for current generation |
| `isProcessing` | `Bool` | Whether the queue is actively generating |
| `completedResults` | `[GenerationResult]` | Finished results (capped at `maxCompletedResults`) |
| `errors` | `[GenerationError]` | Failed generation attempts |

## Cancellation

```swift
// Cancel a specific request (pending or in-progress)
queue.cancel(id: request.id)

// Cancel everything
queue.cancelAll()
```

Cancelling a pending request removes it from the queue. Cancelling the in-progress request signals cooperative cancellation to the underlying gRPC call.

## Housekeeping

```swift
// Limit how many completed results are kept in memory (default: 50)
queue.maxCompletedResults = 20

// Clear stored results and errors
queue.clearCompleted()
queue.clearErrors()
```

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

## Dependencies

- [DrawThingsClient](https://github.com/euphoriacyberware-ai/DT-gRPC-Swift-Client) (DT-gRPC-Swift-Client)

## License

See [LICENSE](LICENSE) for details.
