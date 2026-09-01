//
//  OverlayEyeInputBarPanelManager.swift
//  leanring-buddy
//
//  The bar-side half of "I CANNOT PASTE IMAGES INTO THE CHAT BOX." — the strip
//  the bar's panel draws above its field once an image has been caught.
//
//  The other half, the catching, is in `SelectionTextField.swift`, and its
//  header carries the recreation and the reasoning. This file is only what the
//  reader SEES, and it exists because the alternative is worse than the bug it
//  fixes: an image that vanishes into a field which shows no sign of it is a
//  reader who cannot tell whether their paste worked, cannot tell what Iris is
//  about to look at, and has no way to change their mind. So the strip says
//  what is attached, shows it, says that it is going INSTEAD of the screen, and
//  offers one control to take it back off again.
//
//  It renders nothing at all — not an empty row, not a spacer — when there is
//  no attachment, so the bar it sits in is byte for byte the bar it has always
//  been until the moment the reader pastes something.
//

import AppKit
import SwiftUI

/// The thumbnail of the image the reader pasted, with the control that removes
/// it. Sits directly above the field row in the bar's glass shell.
struct OverlayEyePastedImageThumbnailRow: View {

    @ObservedObject private var attachment: OverlayEyePastedImageAttachment

    init(attachment: OverlayEyePastedImageAttachment = .shared) {
        self.attachment = attachment
    }

    /// Big enough to recognise the picture by, small enough that a 320pt bar
    /// still reads as a bar rather than a gallery.
    private static let thumbnailSide: CGFloat = 34

    var body: some View {
        // Deliberately a bare `if let` with no modifier wrapped around it: the
        // absent case has to be `EmptyView`, or the enclosing VStack's 8pt
        // spacing would open a gap above the field on every bar that has never
        // had anything pasted into it.
        if let pastedImage = attachment.theImageTheReaderPasted,
           let thumbnail = NSImage(data: pastedImage.imageData) {
            HStack(spacing: 8) {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: Self.thumbnailSide, height: Self.thumbnailSide)
                    .clipShape(RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                            .stroke(DS.Colors.shellBorder, lineWidth: 1)
                    )

                VStack(alignment: .leading, spacing: 1) {
                    Text("image attached")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.ink)
                    // Says the part the reader cannot otherwise know: this
                    // question is about the picture, and Iris is not also
                    // taking a photograph of their desktop to go with it.
                    Text("\(pastedImage.pixelWidth)×\(pastedImage.pixelHeight) — iris reads this instead of your screen")
                        .font(.system(size: 9))
                        .foregroundColor(DS.Colors.muted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer(minLength: 0)

                Button {
                    attachment.removeTheAttachment()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(DS.Colors.muted)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .help("remove this image")
                .accessibilityLabel("remove the attached image")
            }
            .accessibilityElement(children: .contain)
        }
    }
}
