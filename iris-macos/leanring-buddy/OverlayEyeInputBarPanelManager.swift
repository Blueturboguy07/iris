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
//  what is attached, shows it, says that it goes WITH the screen, and offers
//  one control per picture to take it back off again.
//
//  It renders nothing at all — not an empty row, not a spacer — when there is
//  no attachment, so the bar it sits in is byte for byte the bar it has always
//  been until the moment the reader pastes, drops, or picks something.
//

import AppKit
import SwiftUI

/// The thumbnails of the images the reader attached, each with the control
/// that removes it. Sits directly above the field row in the bar's glass shell.
struct OverlayEyePastedImageThumbnailRow: View {

    @ObservedObject private var attachment: OverlayEyePastedImageAttachment

    init(attachment: OverlayEyePastedImageAttachment = .shared) {
        self.attachment = attachment
    }

    /// Big enough to recognise the picture by, small enough that four of them
    /// still fit a 320pt bar with the caption beside them.
    private static let thumbnailSide: CGFloat = 34

    var body: some View {
        // Deliberately a bare `if` with no modifier wrapped around it: the
        // absent case has to be `EmptyView`, or the enclosing VStack's 8pt
        // spacing would open a gap above the field on every bar that has never
        // had anything attached.
        if attachment.thereIsSomethingAttached {
            HStack(spacing: 8) {
                ForEach(Array(attachment.theImagesTheReaderAttached.enumerated()), id: \.offset) { _, attachedImage in
                    thumbnail(for: attachedImage)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(Self.caption(forAttachmentCount: attachment.theImagesTheReaderAttached.count))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.ink)
                    // Says the part the reader cannot otherwise know: Iris
                    // reads the picture AND takes its usual look at the screen.
                    Text(Self.whatIrisWillLookAt)
                        .font(.system(size: 9))
                        .foregroundColor(DS.Colors.muted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .contain)
        }
    }

    /// "image attached" / "3 images attached".
    static func caption(forAttachmentCount count: Int) -> String {
        count == 1 ? "image attached" : "\(count) images attached"
    }

    static let whatIrisWillLookAt = "sent with your screen — iris reads both"

    /// One picture with its own ×, so removing one never removes the rest.
    private func thumbnail(for attachedImage: OverlayEyePastedImage) -> some View {
        ZStack(alignment: .topTrailing) {
            if let nsImage = NSImage(data: attachedImage.imageData) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: Self.thumbnailSide, height: Self.thumbnailSide)
                    .clipShape(RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                            .stroke(DS.Colors.shellBorder, lineWidth: 1)
                    )
            }

            Button {
                attachment.remove(attachedImage)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundColor(DS.Colors.ink)
                    .frame(width: 14, height: 14)
                    .background(Circle().fill(Color.black.opacity(0.75)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .offset(x: 4, y: -4)
            .help("remove this image")
            .accessibilityLabel("remove the attached image \(attachedImage.pixelWidth) by \(attachedImage.pixelHeight)")
        }
        .frame(width: Self.thumbnailSide + 4, height: Self.thumbnailSide + 4, alignment: .bottomLeading)
    }
}
