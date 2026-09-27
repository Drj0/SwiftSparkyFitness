//
//  ExercisePhotos.swift
//  SwiftSparkyFitness
//
//  Free Exercise DB's two photos for an exercise — start and end position —
//  side by side, which reads as a two-frame demonstration. Downloaded once
//  and kept in Caches; renders nothing at all when there's no photo, so an
//  exercise without one doesn't carry an empty frame.
//

import SwiftUI

struct ExercisePhotos: View {
    let exerciseName: String

    @State private var images: [UIImage] = []

    var body: some View {
        // A stack, not a Group: an empty Group isn't a view at all, so the
        // `.task` below never ran and the photos never loaded. An empty
        // VStack still exists, at zero height.
        VStack(spacing: 0) {
            if !images.isEmpty {
                HStack(spacing: 8) {
                    ForEach(images.indices, id: \.self) { index in
                        // The frame is sized first and the photo laid over
                        // it: a fill-scaled image reports its full natural
                        // width, which widened the whole sheet past the
                        // screen and pushed every row to the edges.
                        Color.clear
                            .frame(maxWidth: .infinity)
                            .frame(height: 132)
                            .overlay {
                                Image(uiImage: images[index])
                                    .resizable()
                                    .scaledToFill()
                            }
                            .clipShape(RoundedRectangle(cornerRadius: AppRadius.sm, style: .continuous))
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Photos showing \(exerciseName)")
                .transition(.opacity)
            }
        }
        .task(id: exerciseName) {
            guard let imageId = await FreeExerciseDB.shared.imageId(forName: exerciseName) else { return }
            var loaded: [UIImage] = []
            for index in 0..<2 {
                if let image = await ExercisePhotoCache.image(imageId: imageId, index: index) {
                    loaded.append(image)
                }
            }
            withAnimation(.easeOut(duration: 0.2)) { images = loaded }
        }
    }
}

enum ExercisePhotoCache {
    static func image(imageId: String, index: Int) async -> UIImage? {
        let file = URL.cachesDirectory
            .appending(path: "exercise-photos", directoryHint: .isDirectory)
            .appending(path: "\(imageId)-\(index).jpg")
        if let data = try? Data(contentsOf: file), let image = UIImage(data: data) { return image }
        let url = FreeExerciseDB.imageURL(imageId: imageId, index: index)
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let image = UIImage(data: data) else { return nil }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
        return image
    }
}
