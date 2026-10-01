//
//  ExercisePhotos.swift
//  SwiftSparkyFitness
//
//  Free Exercise DB's two photos for an exercise — start and end position —
//  side by side, which reads as a two-frame demonstration. Renders nothing
//  at all when there's no photo, so an exercise without one doesn't carry an
//  empty frame.
//
//  Photos are fetched ahead of the page that shows them: Log Exercise
//  prefetches what's on screen and waits (briefly) for the tapped one, so
//  the editor's first frame already has them. Fetching only once the editor
//  appeared made the photos pop in and shove the form down.
//

import SwiftUI
import ImageIO

struct ExercisePhotos: View {
    let exerciseName: String

    @State private var images: [UIImage]
    /// Holds the photos' space while they load, for exercises known to have
    /// them — so the form below doesn't jump when they land.
    @State private var reservesSpace: Bool

    private let height: CGFloat

    init(exerciseName: String, height: CGFloat = 132) {
        self.exerciseName = exerciseName
        self.height = height
        let cached = ExercisePhotoStore.cached(for: exerciseName)
        _images = State(initialValue: cached ?? [])
        _reservesSpace = State(initialValue: cached == nil && ExercisePhotoStore.expectsPhotos(for: exerciseName))
    }

    var body: some View {
        // A stack, not a Group: an empty Group isn't a view at all, so the
        // `.task` below never ran and the photos never loaded. An empty
        // VStack still exists, at zero height.
        VStack(spacing: 0) {
            if !images.isEmpty {
                frames(count: images.count) { index in
                    Image(uiImage: images[index])
                        .resizable()
                        .scaledToFill()
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Photos showing \(exerciseName)")
                .transition(.opacity)
            } else if reservesSpace {
                frames(count: 2) { _ in AppColor.inputBackground }
                    .accessibilityHidden(true)
            }
        }
        .task(id: exerciseName) {
            guard images.isEmpty else { return }
            let loaded = await ExercisePhotoStore.load(exerciseName)
            withAnimation(.easeOut(duration: 0.2)) {
                images = loaded
                reservesSpace = false
            }
        }
    }

    private func frames(count: Int, @ViewBuilder _ content: @escaping (Int) -> some View) -> some View {
        HStack(spacing: 8) {
            ForEach(0..<count, id: \.self) { index in
                // The frame is sized first and the photo laid over it: a
                // fill-scaled image reports its full natural width, which
                // widened the whole sheet past the screen and pushed every
                // row to the edges.
                Color.clear
                    .frame(maxWidth: .infinity)
                    .frame(height: height)
                    .overlay { content(index) }
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.sm, style: .continuous))
            }
        }
    }
}

/// Decoded photos by exercise name, readable synchronously so a view can
/// start with them instead of fetching after it appears.
enum ExercisePhotoStore {
    private final class Photos {
        let images: [UIImage]
        init(_ images: [UIImage]) { self.images = images }
    }

    private static let memory: NSCache<NSString, Photos> = {
        let cache = NSCache<NSString, Photos>()
        cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()
    /// Names looked up and found to have no photo — not refetched.
    private static var withoutPhotos: Set<String> = []
    private static var inFlight: [String: Task<[UIImage]?, Never>] = [:]

    private static func key(_ name: String) -> String { ExerciseCatalog.normalized(name) }

    static func cached(for name: String) -> [UIImage]? {
        let key = key(name)
        if withoutPhotos.contains(key) { return [] }
        return memory.object(forKey: key as NSString)?.images
    }

    /// Only the built-in catalog can say without a lookup.
    static func expectsPhotos(for name: String) -> Bool {
        ExerciseCatalog.entry(named: name)?.imageId != nil
    }

    /// Empty when the exercise has no photos or they couldn't be fetched.
    static func load(_ name: String) async -> [UIImage] {
        if let cached = cached(for: name) { return cached }
        return await task(for: name).value ?? []
    }

    /// Starts fetching in the background; nothing waits on it.
    static func prefetch<Names: Sequence<String>>(_ names: Names) {
        for name in names where cached(for: name) == nil {
            _ = task(for: name)
        }
    }

    /// Waits for `name`'s photos, but no longer than `timeout` — a slow
    /// network shouldn't hold the page back. The fetch carries on either
    /// way, and the page fades the photos in if they arrive late.
    static func waitForPhotos(of name: String, upTo timeout: Duration) async {
        guard cached(for: name) == nil else { return }
        let fetch = task(for: name)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let once = ResumeOnce(continuation)
            Task { _ = await fetch.value; once.resume() }
            Task { try? await Task.sleep(for: timeout); once.resume() }
        }
    }

    private static func task(for name: String) -> Task<[UIImage]?, Never> {
        let key = key(name)
        if let running = inFlight[key] { return running }
        let task = Task<[UIImage]?, Never> {
            let result = await ExercisePhotoLoader.shared.photos(forName: name)
            inFlight[key] = nil
            switch result {
            case .photos(let images):
                let cost = images.reduce(0) { $0 + Int($1.size.width * $1.size.height * $1.scale * $1.scale * 4) }
                memory.setObject(Photos(images), forKey: key as NSString, cost: cost)
                return images
            case .none:
                withoutPhotos.insert(key)
                return []
            case .failed:
                // Not remembered: the next open retries.
                return nil
            }
        }
        inFlight[key] = task
        return task
    }

    private final class ResumeOnce {
        private var continuation: CheckedContinuation<Void, Never>?
        init(_ continuation: CheckedContinuation<Void, Never>) { self.continuation = continuation }
        func resume() {
            continuation?.resume()
            continuation = nil
        }
    }
}

/// Disk, network and JPEG decoding, off the main actor. Photos are kept on
/// disk as downloaded and decoded here at display size — a full-size decode
/// on the main thread was the other half of the lag.
actor ExercisePhotoLoader {
    static let shared = ExercisePhotoLoader()

    nonisolated enum Result: Sendable {
        case photos([UIImage])
        case none
        case failed
    }

    /// Two frames at 132 pt tall, about half the screen wide each, on a 3×
    /// display.
    nonisolated private static let maxPixelSize = 600

    func photos(forName name: String) async -> Result {
        guard let imageId = await FreeExerciseDB.shared.imageId(forName: name) else { return .none }
        async let first = image(imageId: imageId, index: 0)
        async let second = image(imageId: imageId, index: 1)
        let images = await [first, second].compactMap { $0 }
        return images.isEmpty ? .failed : .photos(images)
    }

    private func image(imageId: String, index: Int) async -> UIImage? {
        let file = URL.cachesDirectory
            .appending(path: "exercise-photos", directoryHint: .isDirectory)
            .appending(path: "\(imageId)-\(index).jpg")
        if let data = try? Data(contentsOf: file), let image = Self.decoded(data) { return image }
        let url = FreeExerciseDB.imageURL(imageId: imageId, index: index)
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let image = Self.decoded(data) else { return nil }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
        return image
    }

    /// Decoded now, not lazily at first draw (which would land on the main
    /// thread), and scaled down to what's actually shown.
    nonisolated private static func decoded(_ data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }
}
