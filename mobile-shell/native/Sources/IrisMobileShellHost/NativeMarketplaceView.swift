#if os(iOS)
import IrisMobileShellCore
import SwiftUI
import UIKit

/// Visual tokens measured from Publik's public mobile marketplace. Appearance
/// metadata is never an installation descriptor, a rating, or a capability grant.
enum NativeMarketplaceStyle {
    static let paper = Color(red: 247 / 255, green: 248 / 255, blue: 252 / 255)
    static let ink = Color(red: 21 / 255, green: 24 / 255, blue: 36 / 255)
    static let line = Color(red: 223 / 255, green: 227 / 255, blue: 236 / 255)
    static let fog = Color(red: 80 / 255, green: 86 / 255, blue: 106 / 255)
    static let electric = Color(red: 49 / 255, green: 92 / 255, blue: 245 / 255)
    static let cardRadius: CGFloat = 12
}

enum NativeMarketplaceTab: String, CaseIterable, Identifiable {
    case browse = "Browse"
    case myApps = "My apps"
    var id: String { rawValue }
}

enum NativeMarketplaceDestination: Hashable {
    case app(NativeShellAppIdentity)
    /// The Features page (mobile-versions MV4), pushed from My apps.
    case features(NativeShellAppIdentity)
    case catalog(String)
    case privacy
}

enum NativeMarketplaceSelection {
    /// Bounded local matching, never a network/model search or an app-ID guess.
    static func matches(query: String, name: String, slug: String) -> Bool {
        let query = String(query.prefix(128)).trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || name.localizedCaseInsensitiveContains(query)
            || slug.localizedCaseInsensitiveContains(query)
    }

    static func catalogApp(for entry: NativeShellLibraryEntry,
                           in apps: [PublikMobileCatalogApp]) -> PublikMobileCatalogApp? {
        apps.first { $0.mobileShell?.identity == entry.identity }
    }

    static func appearanceKey(appId: String) -> String {
        // These exact identities belong to reviewed packages. Unknown identities
        // use their own name/initial, not a similar-looking known app's artwork.
        switch appId {
        case "publik.kneecap": return "kneecap"
        case "publik.nut-ai": return "nut-ai"
        case "publik.freeharmony": return "freeharmony"
        case "publik.lunara": return "lunara"
        default: return appId
        }
    }
}

struct NativePublikWordmark: View {
    var body: some View {
        HStack(spacing: 7) {
            Canvas { context, size in
                let transform = CGAffineTransform(scaleX: size.width / 122, y: size.height / 140)
                var letter = Path()
                letter.move(to: CGPoint(x: 18, y: 4))
                letter.addLine(to: CGPoint(x: 66, y: 4))
                letter.addCurve(to: CGPoint(x: 119, y: 56), control1: CGPoint(x: 98, y: 4), control2: CGPoint(x: 119, y: 26))
                letter.addCurve(to: CGPoint(x: 66, y: 108), control1: CGPoint(x: 119, y: 86), control2: CGPoint(x: 98, y: 108))
                letter.addLine(to: CGPoint(x: 50, y: 108))
                letter.addLine(to: CGPoint(x: 50, y: 136))
                letter.addLine(to: CGPoint(x: 18, y: 136))
                letter.closeSubpath()
                context.fill(letter.applying(transform), with: .color(NativeMarketplaceStyle.ink))
                context.fill(Path(ellipseIn: CGRect(x: 45, y: 33, width: 54, height: 38)).applying(transform), with: .color(.white))
                context.fill(Path(ellipseIn: CGRect(x: 50, y: 45, width: 22, height: 22)).applying(transform), with: .color(NativeMarketplaceStyle.ink))
                context.fill(Path(ellipseIn: CGRect(x: 50.5, y: 43.5, width: 9, height: 9)).applying(transform), with: .color(.white))
            }
            .frame(width: 22, height: 25)
            .accessibilityHidden(true)
            (Text("publik").foregroundColor(NativeMarketplaceStyle.ink)
                + Text(".").foregroundColor(NativeMarketplaceStyle.electric))
                .font(.title2.weight(.heavy)).fontDesign(.rounded)
                .tracking(-1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Publik")
    }
}

struct NativeMarketplaceArtwork: View {
    let key: String
    let name: String

    private var previewName: String? {
        switch key {
        case "nut-ai": return "publik-nut-ai-preview"
        case "freeharmony": return "publik-freeharmony-preview"
        case "cue", "simplicity", "astro", "ghost", "plantgpt", "lidless", "openascii", "nutcracker":
            return "publik-" + key + "-preview"
        default: return nil
        }
    }

    var body: some View {
        GeometryReader { geometry in
            if let previewName,
               let path = Bundle.module.url(forResource: previewName, withExtension: "png", subdirectory: "Marketplace"),
               let image = UIImage(contentsOfFile: path.path) {
                Image(uiImage: image).resizable().scaledToFill()
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
                    .clipped()
            } else if key == "lunara" {
                calendarArtwork
            } else {
                initialArtwork
            }
        }
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .accessibilityHidden(true)
    }

    private var calendarArtwork: some View {
        ZStack {
            Color(red: 1, green: 0.90, blue: 0.94)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("TODAY").font(.system(size: 8, weight: .bold))
                    Spacer()
                    Image(systemName: "moon.fill").font(.caption2)
                }
                HStack(spacing: 6) {
                    ForEach(Array("MTWTFSS").indices, id: \.self) { index in
                        VStack(spacing: 5) {
                            Text(String(Array("MTWTFSS")[index])).font(.system(size: 7))
                            Circle().fill(index > 3 ? Color.pink.opacity(0.7) : Color.pink.opacity(0.1))
                                .frame(width: 9, height: 9)
                        }
                    }
                }
                RoundedRectangle(cornerRadius: 2).fill(Color.pink.opacity(0.12)).frame(height: 5)
            }
            .padding(10).background(.white, in: RoundedRectangle(cornerRadius: 10)).padding(12)
        }
    }

    private var initialArtwork: some View {
        let isKneecap = key == "kneecap"
        return ZStack {
            LinearGradient(colors: isKneecap
                ? [Color(red: 35 / 255, green: 77 / 255, blue: 40 / 255), Color(red: 21 / 255, green: 51 / 255, blue: 47 / 255)]
                : [Color(red: 0.89, green: 0.91, blue: 1), Color(red: 0.95, green: 0.95, blue: 1)],
                startPoint: .topLeading, endPoint: .bottomTrailing)
            HStack(spacing: 8) {
                Text(String(name.prefix(1)).uppercased())
                    .font(.system(size: 24, weight: .heavy))
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(isKneecap ? Color(red: 0.12, green: 0.72, blue: 0.40) : NativeMarketplaceStyle.electric,
                                in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 5) {
                    Text(name).font(.system(size: 10, weight: .heavy)).lineLimit(1)
                    RoundedRectangle(cornerRadius: 2).fill(NativeMarketplaceStyle.line).frame(height: 4)
                    RoundedRectangle(cornerRadius: 2).fill(NativeMarketplaceStyle.line.opacity(0.6)).frame(width: 28, height: 4)
                }
            }
            .padding(10).background(.white, in: RoundedRectangle(cornerRadius: 12)).padding(10)
        }
    }
}

struct NativeMarketplaceCard<Actions: View>: View {
    let key: String
    let name: String
    let subtitle: String
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            NativeMarketplaceArtwork(key: key, name: name).frame(height: 106)
            Text(name).font(.system(size: 15, weight: .bold)).lineLimit(1)
                .foregroundStyle(NativeMarketplaceStyle.ink)
            Text(subtitle).font(.system(size: 11)).foregroundStyle(NativeMarketplaceStyle.fog)
                .lineLimit(2).frame(minHeight: 28, alignment: .topLeading)
            actions()
        }
        .padding(8)
        .background(NativeMarketplaceStyle.paper)
        .overlay(RoundedRectangle(cornerRadius: NativeMarketplaceStyle.cardRadius)
            .stroke(NativeMarketplaceStyle.line, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: NativeMarketplaceStyle.cardRadius))
    }
}

struct NativeMarketplaceActionStyle: ButtonStyle {
    var prominent = true
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13, weight: .semibold))
            .frame(maxWidth: .infinity, minHeight: 44)
            .foregroundStyle(prominent ? .white : NativeMarketplaceStyle.ink)
            .background(prominent ? NativeMarketplaceStyle.electric : NativeMarketplaceStyle.line.opacity(0.55),
                        in: Capsule())
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Capsule())
    }
}
#endif
