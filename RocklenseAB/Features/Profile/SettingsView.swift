import FirebaseFirestore
import MessageUI
import PhotosUI
import SwiftUI

// MARK: - Settings (SettingsFragment port)

struct SettingsView: View {
    @EnvironmentObject var auth: AuthService
    @State private var confirmDelete = false
    @State private var deleteError: String?

    var body: some View {
        List {
            NavigationLink("Edit Profile") { EditProfileView() }
            NavigationLink("Contact the Team") { ContactTeamView() }
            Button("Sign out") {
                try? auth.signOut()
                // RootView reacts to isSignedIn flipping and returns to sign-in.
            }
            Button("Delete profile", role: .destructive) { confirmDelete = true }
            if let deleteError {
                Text(deleteError).font(.system(size: 13)).foregroundStyle(RLColor.rust)
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Delete your profile?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { deleteProfile() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes your account and everything tied to it \u{2014} your profile, friends, and posted reviews. This can't be undone.")
        }
    }

    /// Same two-phase deletion as Android: social data cascade first (while
    /// still authenticated so security rules permit the deletes), then the
    /// Auth account itself. Firebase requires a RECENT sign-in for account
    /// deletion -- surfaced the same way as Android's needsReauth message.
    /// Full account deletion in-app is also an App Store requirement
    /// (Guideline 5.1.1(v)) for apps with account creation, so this flow is
    /// load-bearing for review approval, not just parity.
    private func deleteProfile() {
        FriendsRepository.shared.deleteCurrentUserSocialData { _ in
            Task { @MainActor in
                do {
                    try await auth.deleteAccount()
                    LocalProfileStore.hasCompletedProfileSetup = false
                } catch {
                    let nsError = error as NSError
                    if nsError.code == 17014 { // FIRAuthErrorCodeRequiresRecentLogin
                        deleteError = "For security, please sign out and back in, then try deleting again"
                    } else {
                        deleteError = "Couldn't delete \u{2014} check your connection and try again"
                    }
                }
            }
        }
    }
}

// MARK: - Edit Profile (EditProfileFragment port)

/// The ONLY place name/location/bio and the avatar can be changed (the main
/// Profile tab is read-only). Fields start locked; tapping Edit reveals the
/// form + Save; Save writes and locks back down. Also where the climber
/// manages their own data: clearing recents, removing favorites, and
/// editing/deleting their own posted reviews.
struct EditProfileView: View {
    @EnvironmentObject var cragRepo: CragRepository
    @Environment(\.dismiss) private var dismiss

    @State private var editing = false
    @State private var name = ""
    @State private var location = ""
    @State private var bio = ""
    @State private var avatarItem: PhotosPickerItem?
    @State private var avatarToCrop: UIImage?
    @State private var avatarVersion = 0

    @State private var confirmClearRecents = false
    @State private var confirmTopSave = false
    @State private var favoritesVersion = 0
    @State private var myReviews: [Review] = []
    @State private var reviewToEdit: Review?
    @State private var reviewPendingDelete: Review?
    @State private var savedToast = false

    private let db = Firestore.firestore()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // Avatar
                HStack {
                    Spacer()
                    PhotosPicker(selection: $avatarItem, matching: .images) {
                        AvatarCircleView(size: 96).id(avatarVersion)
                            .overlay(alignment: .bottomTrailing) {
                                Image(systemName: "pencil.circle.fill")
                                    .font(.system(size: 26))
                                    .foregroundStyle(RLColor.rust)
                                    .background(RLColor.limestone, in: Circle())
                            }
                    }
                    Spacer()
                }

                // Name / location / bio -- locked until Edit is tapped.
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Profile").font(.system(size: 16, weight: .bold)).foregroundStyle(RLColor.ink)
                        Spacer()
                        Button(editing ? "Cancel" : "Edit") {
                            if editing { editing = false } else { beginEditing() }
                        }
                        .font(.system(size: 13, weight: .semibold))
                    }
                    if editing {
                        TextField("Name", text: $name).textFieldStyle(.roundedBorder)
                        TextField("Location", text: $location).textFieldStyle(.roundedBorder)
                        TextField("Bio", text: $bio, axis: .vertical).lineLimit(2...4).textFieldStyle(.roundedBorder)
                        Button("Save") { saveFields() }.buttonStyle(RLPrimaryButtonStyle()).frame(width: 120)
                    } else {
                        labeledValue("Name", LocalProfileStore.name.isEmpty ? "Add your name" : LocalProfileStore.name)
                        labeledValue("Location", LocalProfileStore.location)
                        labeledValue("Bio", LocalProfileStore.bio)
                    }
                    if savedToast {
                        Text("Saved").font(.system(size: 12)).foregroundStyle(RLColor.pine)
                    }
                }
                .padding(14)
                .background(RLColor.chalk, in: RoundedRectangle(cornerRadius: 16))

                // Data management
                VStack(alignment: .leading, spacing: 12) {
                    Text("Your data").font(.system(size: 16, weight: .bold)).foregroundStyle(RLColor.ink)

                    Button("Clear recent climbs") { confirmClearRecents = true }
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(RLColor.rust)

                    Text("Favorites").font(.system(size: 14, weight: .semibold)).foregroundStyle(RLColor.ink)
                    let favorites = favoriteItems
                    if favorites.isEmpty {
                        Text("No favorites yet").font(.system(size: 12)).foregroundStyle(RLColor.inactiveText)
                    }
                    ForEach(favorites) { item in
                        HStack {
                            Text("\(item.route.name) (\(item.route.grade))")
                                .font(.system(size: 13)).foregroundStyle(RLColor.ink)
                            Spacer()
                            Button {
                                LocalProfileStore.toggleFavorite(item.route.id)
                                favoritesVersion += 1
                            } label: {
                                Image(systemName: "heart.slash").foregroundStyle(RLColor.rust)
                            }
                        }
                    }
                    .id(favoritesVersion)

                    Text("Your reviews").font(.system(size: 14, weight: .semibold)).foregroundStyle(RLColor.ink)
                    if myReviews.isEmpty {
                        Text("No reviews posted from this device")
                            .font(.system(size: 12)).foregroundStyle(RLColor.inactiveText)
                    }
                    ForEach(myReviews) { review in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(String(repeating: "\u{2605}", count: review.stars))
                                    .font(.system(size: 11)).foregroundStyle(RLColor.rust)
                                Text(review.text).font(.system(size: 13)).foregroundStyle(RLColor.ink).lineLimit(2)
                            }
                            Spacer()
                            Button { reviewToEdit = review } label: { Image(systemName: "pencil") }
                            Button { reviewPendingDelete = review } label: {
                                Image(systemName: "trash").foregroundStyle(RLColor.rust)
                            }
                            .padding(.leading, 8)
                        }
                    }
                }
                .padding(14)
                .background(RLColor.chalk, in: RoundedRectangle(cornerRadius: 16))
            }
            .padding(RLMetrics.screenPadding)
        }
        .background(RLColor.limestone)
        .navigationTitle("Edit Profile")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // The persistent top-right Save -- separate from the inline
            // per-field Edit/Save toggle: confirms, saves whatever's
            // currently in the form (if mid-edit) or just the already-saved
            // values otherwise, and returns to the Profile tab. Same as
            // EditProfileFragment's edit_top_save_button.
            ToolbarItem(placement: .primaryAction) {
                Button("Save") { confirmTopSave = true }
            }
        }
        .alert("Save changes?", isPresented: $confirmTopSave) {
            Button("Save") {
                if editing { saveFields() }
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        }
        .onAppear(perform: loadReviews)
        .onChange(of: avatarItem) { item in
            Task {
                if let data = try? await item?.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    avatarToCrop = image.normalizedAndDownsampled(maxDimension: 1600)
                }
            }
        }
        .fullScreenCover(item: Binding(
            get: { avatarToCrop.map { CropPayload(image: $0) } },
            set: { if $0 == nil { avatarToCrop = nil } }
        )) { payload in
            CropAvatarView(photo: payload.image) { cropped in
                AvatarStore.saveLocal(cropped)
                avatarVersion += 1
                // Uploads so friends see the new photo too, not just this device.
                FriendsRepository.shared.uploadAvatar(cropped) { _ in }
            }
        }
        .alert("Clear recent climbs?", isPresented: $confirmClearRecents) {
            Button("Clear", role: .destructive) { LocalProfileStore.clearRecentClimbs() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes everything from your Recents tab. It doesn't affect anything on the crag itself.")
        }
        .sheet(item: $reviewToEdit) { review in
            EditReviewSheet(review: review) { loadReviews() }
        }
        .alert("Delete this review?",
               isPresented: Binding(get: { reviewPendingDelete != nil },
                                     set: { if !$0 { reviewPendingDelete = nil } })) {
            Button("Delete", role: .destructive) {
                if let review = reviewPendingDelete {
                    db.collection("reviews").document(review.id).delete { _ in loadReviews() }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private struct CropPayload: Identifiable {
        let id = UUID()
        let image: UIImage
    }

    private func labeledValue(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 11, weight: .semibold)).foregroundStyle(RLColor.inactiveText)
            Text(value.isEmpty ? "\u{2014}" : value).font(.system(size: 14)).foregroundStyle(RLColor.ink)
        }
    }

    private var favoriteItems: [ClimbListItem] {
        let ids = LocalProfileStore.favoriteRouteIds()
        return cragRepo.crags.flatMap { crag in
            crag.walls.flatMap { wall in
                wall.routes.filter { ids.contains($0.id) }
                    .map { ClimbListItem(route: $0, wall: wall, crag: crag, distanceKm: nil) }
            }
        }
    }

    private func beginEditing() {
        name = LocalProfileStore.name
        location = LocalProfileStore.location
        bio = LocalProfileStore.bio
        editing = true
    }

    private func saveFields() {
        LocalProfileStore.name = name.trimmingCharacters(in: .whitespaces)
        LocalProfileStore.location = location.trimmingCharacters(in: .whitespaces)
        LocalProfileStore.bio = bio.trimmingCharacters(in: .whitespaces)
        FriendsRepository.shared.syncCurrentUserProfile()
        editing = false
        savedToast = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { savedToast = false }
    }

    private func loadReviews() {
        let ids = Array(LocalProfileStore.postedReviewIds().prefix(30))
        guard !ids.isEmpty else { myReviews = []; return }
        db.collection("reviews").whereField(FieldPath.documentID(), in: ids).getDocuments { snapshot, _ in
            let loaded = snapshot?.documents.compactMap { doc -> Review? in
                var r = try? doc.data(as: Review.self)
                r?.id = doc.documentID
                return r
            } ?? []
            myReviews = loaded.sorted { $0.timestampMillis > $1.timestampMillis }
        }
    }
}

/// Inline edit-review sheet (stars + text), matching the Android dialog.
struct EditReviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    let review: Review
    let onSaved: () -> Void

    @State private var stars: Int = 0
    @State private var text: String = ""

    var body: some View {
        NavigationStack {
            Form {
                HStack(spacing: 6) {
                    ForEach(1...5, id: \.self) { star in
                        Button { stars = star } label: {
                            Image(systemName: star <= stars ? "star.fill" : "star")
                                .foregroundStyle(RLColor.rust)
                        }
                        .buttonStyle(.plain)
                    }
                }
                TextField("Review text", text: $text, axis: .vertical).lineLimit(3...6)
            }
            .navigationTitle("Edit review")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Firestore.firestore().collection("reviews").document(review.id)
                            .updateData(["text": text.trimmingCharacters(in: .whitespaces), "stars": stars]) { _ in
                                onSaved()
                            }
                        dismiss()
                    }
                }
            }
            .onAppear { stars = review.stars; text = review.text }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - Contact the Team (ContactTeamFragment port)

/// A message + optional photo, sent to rocklense.ab@gmail.com. iOS's
/// MFMailComposeViewController presents an in-app compose sheet with
/// everything (recipient, subject, body, attachment) pre-filled -- the
/// climber still taps Send themselves, the platform-standard equivalent of
/// Android's email intent (and the same deliberate OS restriction: apps
/// can't send email silently on the user's behalf).
struct ContactTeamView: View {
    @State private var message = ""
    @State private var photoItem: PhotosPickerItem?
    @State private var attachedPhoto: UIImage?
    @State private var showComposer = false
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Found a bug, mapped a great crag, or have an idea? Send it over \u{2014} a photo helps if something looks wrong.")
                .font(.system(size: 13)).foregroundStyle(RLColor.ink.opacity(0.75))

            TextField("Your message", text: $message, axis: .vertical)
                .lineLimit(5...10)
                .textFieldStyle(.roundedBorder)

            PhotosPicker(selection: $photoItem, matching: .images) {
                Label(attachedPhoto == nil ? "Attach a photo (optional)" : "Photo attached \u{2713}",
                      systemImage: "photo")
            }
            if let attachedPhoto {
                Image(uiImage: attachedPhoto)
                    .resizable().scaledToFit().frame(height: 120)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }

            if let errorText {
                Text(errorText).font(.system(size: 13)).foregroundStyle(RLColor.rust)
            }

            Button("Send") {
                guard !message.trimmingCharacters(in: .whitespaces).isEmpty else {
                    errorText = "Write a message first"; return
                }
                guard MFMailComposeViewController.canSendMail() else {
                    errorText = "No email account is set up on this device"; return
                }
                showComposer = true
            }
            .buttonStyle(RLPrimaryButtonStyle())

            Spacer()
        }
        .padding(RLMetrics.screenPadding)
        .background(RLColor.limestone)
        .navigationTitle("Contact the Team")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: photoItem) { item in
            Task {
                if let data = try? await item?.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    attachedPhoto = image.normalizedAndDownsampled(maxDimension: 1600)
                }
            }
        }
        .sheet(isPresented: $showComposer) {
            MailComposeView(message: message, attachment: attachedPhoto)
        }
    }
}

struct MailComposeView: UIViewControllerRepresentable {
    @Environment(\.dismiss) private var dismiss
    let message: String
    let attachment: UIImage?

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let vc = MFMailComposeViewController()
        vc.mailComposeDelegate = context.coordinator
        vc.setToRecipients(["rocklense.ab@gmail.com"])
        vc.setSubject("Rocklense AB feedback")
        vc.setMessageBody(message, isHTML: false)
        if let attachment, let data = attachment.jpegData(compressionQuality: 0.9) {
            vc.addAttachmentData(data, mimeType: "image/jpeg", fileName: "attachment.jpg")
        }
        return vc
    }

    func updateUIViewController(_ uiViewController: MFMailComposeViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(dismiss: { dismiss() }) }

    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        let dismiss: () -> Void
        init(dismiss: @escaping () -> Void) { self.dismiss = dismiss }
        func mailComposeController(_ controller: MFMailComposeViewController,
                                    didFinishWith result: MFMailComposeResult, error: Error?) {
            dismiss()
        }
    }
}

// MARK: - Avatar crop (CropAvatarFragment + CropOverlayView port)

/// Pinch-zoom and drag a picked photo to choose which part becomes the
/// circular avatar. What the climber sees inside the circle is exactly what
/// gets saved -- the on-screen guide circle is mapped back into the original
/// image's own pixel space by inverting the current pan/zoom, then cropped.
struct CropAvatarView: View {
    @Environment(\.dismiss) private var dismiss

    let photo: UIImage
    let onCropped: (UIImage) -> Void

    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            let guideDiameter = min(geo.size.width, geo.size.height) - 60
            // Initial fit: scale the photo to fully COVER the guide circle
            // (center-crop starting point), then pinch/drag from there.
            let baseScale = guideDiameter / min(photo.size.width, photo.size.height)

            ZStack {
                Color.black.ignoresSafeArea()

                Image(uiImage: photo)
                    .resizable()
                    .frame(width: photo.size.width * baseScale, height: photo.size.height * baseScale)
                    .scaleEffect(scale)
                    .offset(offset)

                // Dark mask with a circular hole (CropOverlayView port).
                Rectangle()
                    .fill(Color.black.opacity(0.6))
                    .mask {
                        Rectangle()
                            .overlay(Circle().frame(width: guideDiameter, height: guideDiameter).blendMode(.destinationOut))
                            .compositingGroup()
                    }
                    .allowsHitTesting(false)
                Circle()
                    .stroke(RLColor.chalk, lineWidth: 2)
                    .frame(width: guideDiameter, height: guideDiameter)
                    .allowsHitTesting(false)

                VStack {
                    Spacer()
                    HStack(spacing: 16) {
                        Button("Cancel") { dismiss() }
                            .buttonStyle(RLPrimaryButtonStyle(background: RLColor.dusk2))
                        Button("Save") {
                            performCrop(guideDiameter: guideDiameter, baseScale: baseScale, viewSize: geo.size)
                        }
                        .buttonStyle(RLPrimaryButtonStyle())
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 30)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                SimultaneousGesture(
                    MagnificationGesture()
                        .onChanged { value in scale = max(0.5, lastScale * value) }
                        .onEnded { _ in lastScale = scale },
                    DragGesture()
                        .onChanged { value in
                            offset = CGSize(width: lastOffset.width + value.translation.width,
                                             height: lastOffset.height + value.translation.height)
                        }
                        .onEnded { _ in lastOffset = offset }
                )
            )
        }
    }

    private func performCrop(guideDiameter: CGFloat, baseScale: CGFloat, viewSize: CGSize) {
        // The image is drawn centered at view center + offset, at
        // (baseScale * scale) points per image pixel. Map the guide circle's
        // bounds (centered in the view) back into image pixel space.
        let totalScale = baseScale * scale
        let imageCenterX = viewSize.width / 2 + offset.width
        let imageCenterY = viewSize.height / 2 + offset.height
        let guideMinX = viewSize.width / 2 - guideDiameter / 2
        let guideMinY = viewSize.height / 2 - guideDiameter / 2

        let cropOriginX = (guideMinX - (imageCenterX - photo.size.width * totalScale / 2)) / totalScale
        let cropOriginY = (guideMinY - (imageCenterY - photo.size.height * totalScale / 2)) / totalScale
        let cropSide = guideDiameter / totalScale

        let clampedX = max(0, min(photo.size.width - 1, cropOriginX))
        let clampedY = max(0, min(photo.size.height - 1, cropOriginY))
        let side = max(1, min(cropSide, min(photo.size.width - clampedX, photo.size.height - clampedY)))

        guard let cg = photo.cgImage else { dismiss(); return }
        let pixelScale = CGFloat(cg.width) / photo.size.width
        let cropRect = CGRect(x: clampedX * pixelScale, y: clampedY * pixelScale,
                               width: side * pixelScale, height: side * pixelScale)
        guard let croppedCG = cg.cropping(to: cropRect) else { dismiss(); return }
        onCropped(UIImage(cgImage: croppedCG, scale: 1, orientation: .up))
        dismiss()
    }
}
