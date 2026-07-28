import SwiftUI

/// A short swipeable intro shown when someone skips sign-in entirely --
/// three slides covering the three tabs, then straight into the app.
/// Anonymous auth still happens silently in the background before this
/// shows (see SignInView's Skip button), since almost everything downstream
/// -- Firestore reads/writes, the profile system -- needs a signed-in uid to
/// function, even an anonymous one. This view is purely about not making
/// someone sit through the full name/age/location wizard if they don't want to.
struct TutorialView: View {
    let onFinished: () -> Void

    private struct Slide {
        let icon: String
        let title: String
        let body: String
    }

    private let slides: [Slide] = [
        Slide(icon: "camera.viewfinder", title: "Clip Finder",
              body: "Point your camera at a mapped wall and see every bolt on your route, right where it is in real life."),
        Slide(icon: "map", title: "Crag Map",
              body: "Browse crags near you, check grades and reviews, and see what's already been mapped."),
        Slide(icon: "person.crop.circle", title: "Your Profile",
              body: "Track your recent climbs, save favorites, and connect with friends -- you can always fill this in later.")
    ]

    @State private var page = 0

    var body: some View {
        ZStack {
            RLColor.dusk.ignoresSafeArea()
            VStack(spacing: 0) {
                Spacer()

                TabView(selection: $page) {
                    ForEach(Array(slides.enumerated()), id: \.offset) { index, slide in
                        VStack(spacing: 20) {
                            Image(systemName: slide.icon)
                                .font(.system(size: 56))
                                .foregroundStyle(RLColor.rust)
                            Text(slide.title)
                                .font(.system(size: 24, weight: .bold))
                                .foregroundStyle(RLColor.chalk)
                            Text(slide.body)
                                .font(.system(size: 15))
                                .foregroundStyle(RLColor.cream70)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 40)
                        }
                        .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
                .frame(height: 340)

                Spacer()

                Button(page == slides.count - 1 ? "Get started" : "Next") {
                    if page == slides.count - 1 {
                        onFinished()
                    } else {
                        withAnimation { page += 1 }
                    }
                }
                .buttonStyle(RLPrimaryButtonStyle())
                .padding(.horizontal, 40)

                Button("Skip") { onFinished() }
                    .font(.system(size: 14))
                    .foregroundStyle(RLColor.cream70)
                    .padding(.top, 14)
                    .padding(.bottom, 30)
            }
        }
    }
}
