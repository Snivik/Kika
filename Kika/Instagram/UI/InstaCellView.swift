//
//  InstaCellView.swift
//  Kika
//
//  A photo placed in its cell by `InstaFraming` (aspect-fill × scale, offset, rotation), drawn in a frame of the cell's
//  size. Clipped on the board; the Adjust Photos editor also draws it unclipped (the faded overflow around the frame).
//  Reports the image's pixel size, which placement needs (its aspect includes the Develop crop).
//

import SwiftUI

struct InstaPhotoView: View {
    let photo: Photo
    let transform: InstaTransform
    let cellSize: CGSize
    var level: PreviewLevel? = nil
    @Binding var imageSize: CGSize?

    var body: some View {
        let p = imageSize.map { InstaFraming.placement(imageSize: $0, cellSize: cellSize, transform: transform) }
        ThumbnailView(photo: photo, level: level ?? autoLevel(p), contentMode: p == nil ? .fill : .fit,
                      onImageSize: { s in if imageSize != s { imageSize = s } })
            .frame(width: p?.size.width ?? cellSize.width, height: p?.size.height ?? cellSize.height)
            .rotationEffect(.radians(Double(p?.radians ?? 0)))
            .position(p?.center ?? CGPoint(x: cellSize.width / 2, y: cellSize.height / 2))
            .frame(width: cellSize.width, height: cellSize.height)
    }

    /// The thumbnail, or the 2048 px preview once the drawn photo needs more pixels (zoomed, splits).
    private func autoLevel(_ p: InstaFraming.Placement?) -> PreviewLevel {
        let need = max(p?.size.width ?? cellSize.width, p?.size.height ?? cellSize.height) * 2   // Retina
        return need > CGFloat(PreviewLevel.thumbnail.maxPixelSize) ? .standard : .thumbnail
    }
}

/// A slide cell on the board: its photo, clipped, or an empty drop target.
struct InstaCellView: View {
    let cell: InstaCell?
    let size: CGSize

    @State private var imageSize: CGSize?

    var body: some View {
        if let cell, let photo = InstaStore.shared.photos[cell.photoID] {
            InstaPhotoView(photo: photo, transform: cell.transform, cellSize: size, imageSize: $imageSize)
                .clipped()
        } else {
            ZStack {
                Rectangle().fill(Color.secondary.opacity(0.12))
                Image(systemName: "plus").font(.caption).foregroundStyle(.tertiary)
            }
            .frame(width: size.width, height: size.height)
        }
    }
}
