import FirebaseFirestore
import PhotosUI
import SwiftUI

/// The crag overview screen: hero photo header, name + grade range, editable
/// description, editable crag info, wall list (tap a wall to manage its
/// routes), and this crag's reviews with a post form. Port of
/// CragDetailFragment. Long-press a wall to delete it.
struct CragDetailView: View {
    @EnvironmentObject var cragRepo: CragRepository
    let cragId: String

    @State private var editingDescription = false
    @State private var descriptionDraft = ""
    @State private var showEditCragInfo = false
    @State private var showAddWall = false
    @State private var wallPendingDelete: Wall?
    @State private var wallToEdit: Wall?
    @State private var heroPhotoItem: PhotosPickerItem?

    @State private var reviews: [Review] = []
    @State private var reviewName = ""
    @State private var reviewText = ""
    @State private var reviewStars = 0
    @State private var errorText: String?

    private let db = Firestore.firestore()
    private var crag: Crag? { cragRepo.byId(cragId) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                description
                walls
                reviewsSection
            }
            .padding(.bottom, 40)
        }
        .background(RLColor.limestone)
        .navigationTitle(crag?.name ?? "Crag")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showEditCragInfo = true } label: { Image(systemName: "pencil") }
            }
        }
        .onAppear(perform: loadReviews)
        .sheet(isPresented: $showEditCragInfo) { EditCragInfoSheet(cragId: cragId) }
        .sheet(isPresented: $showAddWall) { AddWallSheet(cragId: cragId, onCreated: { _ in }) }
        .sheet(item: $wallToEdit) { wall in
            AddWallSheet(cragId: cragId, editing: wall, onCreated: { _ in })
        }
        .onChange(of: heroPhotoItem) { item in
            Task {
                if let data = try? await item?.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    cragRepo.addCragPhoto(cragId: cragId, image: image)
                }
            }
        }
        .alert("Delete \(wallPendingDelete?.name ?? "")?",
               isPresented: Binding(get: { wallPendingDelete != nil },
                                     set: { if !$0 { wallPendingDelete = nil } })) {
            Button("Delete", role: .destructive) {
                if let wall = wallPendingDelete { cragRepo.deleteWall(cragId: cragId, wallId: wall.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the wall and all its routes. This can't be undone.")
        }
    }

    private var header: some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if let url = crag?.photoUrls.first.flatMap(URL.init) {
                    AsyncImage(url: url) { image in image.resizable().scaledToFill() }
                        placeholder: { LinearGradient(colors: [RLColor.foliage, RLColor.foliageDark], startPoint: .top, endPoint: .bottom) }
                } else {
                    LinearGradient(colors: [RLColor.foliage, RLColor.foliageDark], startPoint: .top, endPoint: .bottom)
                }
            }
            .frame(height: 180)
            .clipped()

            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(crag?.name ?? "").font(.system(size: 24, weight: .bold)).foregroundStyle(RLColor.chalk)
                    Text(crag?.area ?? "").font(.system(size: 14)).foregroundStyle(RLColor.cream70)
                }
                Spacer()
                Text(gradeRangeLabel(crag)).rlChip()
            }
            .padding(14)
            .background(LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom))

            // Add-photo button (decorative crag photos, NOT AR reference images).
            VStack {
                HStack {
                    Spacer()
                    PhotosPicker(selection: $heroPhotoItem, matching: .images) {
                        Image(systemName: "photo.badge.plus")
                            .foregroundStyle(RLColor.chalk)
                            .padding(10)
                            .background(.black.opacity(0.4), in: Circle())
                    }
                    .padding(10)
                }
                Spacer()
            }
        }
        .frame(height: 180)
    }

    private var description: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("About").font(.system(size: 16, weight: .bold)).foregroundStyle(RLColor.ink)
                Spacer()
                Button(editingDescription ? "Cancel" : "Edit") {
                    if editingDescription { editingDescription = false }
                    else {
                        descriptionDraft = crag?.blurb ?? ""
                        editingDescription = true
                    }
                }
                .font(.system(size: 13, weight: .semibold))
            }
            if editingDescription {
                TextField("Description", text: $descriptionDraft, axis: .vertical)
                    .lineLimit(2...5)
                    .textFieldStyle(.roundedBorder)
                Button("Save") {
                    db.collection("crags").document(cragId)
                        .updateData(["blurb": descriptionDraft.trimmingCharacters(in: .whitespaces)]) { error in
                            if error == nil { editingDescription = false }
                            else { errorText = "Couldn't save \u{2014} try again" }
                        }
                }
                .buttonStyle(RLPrimaryButtonStyle())
                .frame(width: 120)
            } else {
                Text((crag?.blurb.isEmpty == false) ? crag!.blurb : "No description yet \u{2014} tap Edit to add one.")
                    .font(.system(size: 14))
                    .foregroundStyle(RLColor.ink.opacity(0.75))
            }
        }
        .padding(.horizontal, RLMetrics.screenPadding)
    }

    private var walls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Walls").font(.system(size: 16, weight: .bold)).foregroundStyle(RLColor.ink)
                Spacer()
                Button { showAddWall = true } label: {
                    Image(systemName: "plus.circle.fill").font(.system(size: 22)).foregroundStyle(RLColor.rust)
                }
            }
            ForEach(crag?.walls ?? []) { wall in
                NavigationLink {
                    WallDetailView(cragId: cragId, wallId: wall.id)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(wall.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(RLColor.ink)
                            Text("\(wall.routes.count) route\(wall.routes.count == 1 ? "" : "s")")
                                .font(.system(size: 12)).foregroundStyle(RLColor.pine)
                        }
                        Spacer()
                        if wall.isMapped {
                            Text("AR mapped \u{2713}")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(RLColor.pine)
                        }
                        // Inline rename, same as WallListAdapter's pencil.
                        Button { wallToEdit = wall } label: {
                            Image(systemName: "pencil").foregroundStyle(RLColor.inactiveText)
                        }
                        .buttonStyle(.plain)
                        Image(systemName: "chevron.right").foregroundStyle(RLColor.inactiveText)
                    }
                    .padding(14)
                    .background(RLColor.chalk, in: RoundedRectangle(cornerRadius: 14))
                }
                .simultaneousGesture(LongPressGesture().onEnded { _ in wallPendingDelete = wall })
            }
        }
        .padding(.horizontal, RLMetrics.screenPadding)
    }

    private var reviewsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Reviews").font(.system(size: 16, weight: .bold)).foregroundStyle(RLColor.ink)

            // Post form (name optional, stars + text required).
            VStack(spacing: 8) {
                TextField("Your name (optional)", text: $reviewName).textFieldStyle(.roundedBorder)
                HStack(spacing: 6) {
                    ForEach(1...5, id: \.self) { star in
                        Button {
                            reviewStars = star
                        } label: {
                            Image(systemName: star <= reviewStars ? "star.fill" : "star")
                                .foregroundStyle(RLColor.rust)
                        }
                    }
                    Spacer()
                }
                TextField("How was the rock, the approach, the bolting?", text: $reviewText, axis: .vertical)
                    .lineLimit(2...4)
                    .textFieldStyle(.roundedBorder)
                if let errorText {
                    Text(errorText).font(.system(size: 12)).foregroundStyle(RLColor.rust)
                }
                Button("Post review") { postReview() }
                    .buttonStyle(RLPrimaryButtonStyle())
            }
            .padding(12)
            .background(RLColor.chalk, in: RoundedRectangle(cornerRadius: 14))

            if reviews.isEmpty {
                Text("No reviews yet \u{2014} be the first!")
                    .font(.system(size: 13)).foregroundStyle(RLColor.inactiveText)
            }
            ForEach(reviews) { review in
                ReviewRow(review: review, onReported: loadReviews)
            }
        }
        .padding(.horizontal, RLMetrics.screenPadding)
    }

    private func postReview() {
        let text = reviewText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, reviewStars > 0 else {
            errorText = "Add a rating and some text first"; return
        }
        errorText = nil
        let author = reviewName.trimmingCharacters(in: .whitespaces)
        let review = Review(
            cragId: cragId,
            author: author.isEmpty ? "Anonymous climber" : author,
            authorUid: AuthService.shared.currentUser?.uid ?? "",
            stars: reviewStars,
            text: text
        )
        do {
            let doc = db.collection("reviews").document()
            var toSave = review
            toSave.id = doc.documentID
            try doc.setData(from: toSave) { error in
                if error == nil {
                    LocalProfileStore.recordPostedReview(doc.documentID)
                    reviewName = ""; reviewText = ""; reviewStars = 0
                    loadReviews()
                } else {
                    errorText = "Couldn't post \u{2014} check your connection and try again"
                }
            }
        } catch {
            errorText = "Couldn't post \u{2014} try again"
        }
    }

    private func loadReviews() {
        // Sorted client-side rather than orderBy() -- avoiding the composite
        // index requirement, same decision (and reason) as the Android app.
        db.collection("reviews").whereField("cragId", isEqualTo: cragId).getDocuments { snapshot, _ in
            let loaded = snapshot?.documents.compactMap { doc -> Review? in
                var r = try? doc.data(as: Review.self)
                r?.id = doc.documentID
                return r
            } ?? []
            reviews = loaded.sorted { $0.timestampMillis > $1.timestampMillis }
        }
    }
}

/// One review row with the star strip + a report action (item_review +
/// ModerationRepository.reportReview).
struct ReviewRow: View {
    let review: Review
    var onReported: () -> Void = {}
    @State private var confirmReport = false
    @State private var reportOutcome: String?

    private var dateLabel: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM yyyy"   // same as ReviewsAdapter's SimpleDateFormat
        return formatter.string(from: Date(timeIntervalSince1970: Double(review.timestampMillis) / 1000))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(review.author).font(.system(size: 14, weight: .semibold)).foregroundStyle(RLColor.ink)
                Spacer()
                // Filled + empty stars, e.g. "★★★☆☆" -- same glyph style.
                HStack(spacing: 2) {
                    ForEach(1...5, id: \.self) { star in
                        Image(systemName: star <= review.stars ? "star.fill" : "star")
                            .font(.system(size: 11))
                            .foregroundStyle(RLColor.rust)
                    }
                }
            }
            Text(review.text).font(.system(size: 13)).foregroundStyle(RLColor.ink.opacity(0.8))
            HStack {
                Text(dateLabel)
                    .font(.system(size: 11)).foregroundStyle(RLColor.inactiveText)
                Spacer()
                Button("Report") { confirmReport = true }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(RLColor.inactiveText)
                    .buttonStyle(.plain)
            }
            if let reportOutcome {
                Text(reportOutcome)
                    .font(.system(size: 11)).foregroundStyle(RLColor.pine)
            }
        }
        .padding(12)
        .background(RLColor.chalk, in: RoundedRectangle(cornerRadius: 14))
        .alert("Report this review?", isPresented: $confirmReport) {
            Button("Report") {
                ModerationRepository.shared.reportReview(review) { success in
                    reportOutcome = success
                        ? "Reported \u{2014} thanks for flagging it"
                        : "Couldn't send report \u{2014} try again"
                    if success { onReported() }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Our team will look into it.")
        }
    }
}

// MARK: - Wall detail (WallDetailFragment port)

/// Routes on one specific wall, with Map/+Angle actions per route, an
/// edit/delete per route, a favorite heart, and the "set up this wall first"
/// banner when it hasn't been AR-mapped yet.
struct WallDetailView: View {
    @EnvironmentObject var cragRepo: CragRepository
    let cragId: String
    let wallId: String

    @State private var showAddRoute = false
    @State private var routePendingDelete: Route?
    @State private var routeToEdit: Route?
    @State private var favoritesVersion = 0  // bump to re-render hearts

    private var crag: Crag? { cragRepo.byId(cragId) }
    private var wall: Wall? { cragRepo.wallById(cragId, wallId) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if wall?.isMapped != true {
                    setupBanner
                }

                ForEach(wall?.routes ?? []) { route in
                    routeRow(route)
                }
            }
            .padding(RLMetrics.screenPadding)
        }
        .background(RLColor.limestone)
        .navigationTitle(wall?.name ?? "Wall")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showAddRoute = true } label: { Image(systemName: "plus") }
            }
        }
        .sheet(isPresented: $showAddRoute) {
            AddRouteSheet(cragId: cragId, wallId: wallId, onCreated: { _ in })
        }
        .sheet(item: $routeToEdit) { route in
            AddRouteSheet(cragId: cragId, wallId: wallId, editing: route, onCreated: { _ in })
        }
        .alert("Delete \(routePendingDelete?.name ?? "")?",
               isPresented: Binding(get: { routePendingDelete != nil },
                                     set: { if !$0 { routePendingDelete = nil } })) {
            Button("Delete", role: .destructive) {
                if let route = routePendingDelete {
                    cragRepo.deleteRoute(cragId: cragId, wallId: wallId, routeId: route.id)
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var setupBanner: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("This wall isn't set up for AR yet")
                .font(.system(size: 15, weight: .bold)).foregroundStyle(RLColor.chalk)
            Text("Take reference photos and measure the wall once \u{2014} then every route on it just needs its clips placed.")
                .font(.system(size: 13)).foregroundStyle(RLColor.cream70)
            NavigationLink {
                SetupWallView(cragId: cragId, wallId: wallId)
            } label: {
                Text("Set up this wall")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(RLColor.chalk)
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(RLColor.rust, in: Capsule())
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RLColor.dusk2, in: RoundedRectangle(cornerRadius: 16))
    }

    private func routeRow(_ route: Route) -> some View {
        // Same interactions as RouteListAdapter: tapping the ROW edits its
        // name/grade/length/bolts (editing in place matters -- delete +
        // recreate would lose the AR clip mapping); long-press deletes.
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(route.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(RLColor.ink)
                Text("\(route.lengthMeters)m \u{00b7} \(route.boltCount) bolts\(route.clips.isEmpty ? "" : " \u{00b7} AR-mapped")")
                    .font(.system(size: 11)).foregroundStyle(Color(hex: 0x7A7266))
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                LocalProfileStore.toggleFavorite(route.id)
                favoritesVersion += 1
            } label: {
                Image(systemName: LocalProfileStore.isFavorite(route.id) ? "heart.fill" : "heart")
                    .foregroundStyle(RLColor.rust)
            }
            .buttonStyle(.plain)
            .id(favoritesVersion)

            // Grade badge: dusk background, chalk text (item_route_editable).
            Text(route.grade)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(RLColor.chalk)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(RLColor.dusk)

            NavigationLink {
                if wall?.isMapped == true {
                    MapRouteView(cragId: cragId, wallId: wallId, routeId: route.id)
                } else {
                    // "Set up this wall first" -- same redirect as Android's
                    // onMapClick when the wall isn't mapped yet.
                    SetupWallView(cragId: cragId, wallId: wallId)
                }
            } label: {
                Text("Map")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(RLColor.chalk)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(RLColor.pine, in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)

            // Only shown once the route already has a primary mapping to add
            // an angle alongside -- same visibility gate as RouteListAdapter.
            if !route.clips.isEmpty {
                NavigationLink {
                    AddAngleView(cragId: cragId, wallId: wallId)
                } label: {
                    Text("+Angle")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(RLColor.chalk)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(RLColor.rust, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .background(RLColor.chalk, in: RoundedRectangle(cornerRadius: 14))
        .contentShape(Rectangle())
        .onTapGesture { routeToEdit = route }
        .onLongPressGesture { routePendingDelete = route }
    }
}

// MARK: - Add/Edit wall + route sheets (dialog ports)

struct AddWallSheet: View {
    @EnvironmentObject var cragRepo: CragRepository
    @Environment(\.dismiss) private var dismiss

    let cragId: String
    var editing: Wall? = nil
    let onCreated: (String) -> Void

    @State private var name = ""

    var body: some View {
        NavigationStack {
            Form { TextField("Wall name", text: $name) }
                .navigationTitle(editing == nil ? "New wall" : "Edit wall")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(editing == nil ? "Add" : "Save") { save() }
                            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                .onAppear { if let editing { name = editing.name } }
        }
        .presentationDetents([.height(200)])
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if let editing {
            cragRepo.updateWallName(cragId: cragId, wallId: editing.id, name: trimmed) { success in
                if success { onCreated(editing.id) }
            }
        } else {
            // Id generated client-side so the caller knows it immediately,
            // without a second round-trip (same as the Android dialog).
            let newId = UUID().uuidString
            cragRepo.addWall(cragId: cragId, wall: Wall(id: newId, name: trimmed)) { success in
                if success { onCreated(newId) }
            }
        }
        dismiss()
    }
}

/// Handles both creating and editing a route -- editing in place matters
/// because delete + recreate would lose the route's AR clip mapping.
struct AddRouteSheet: View {
    @EnvironmentObject var cragRepo: CragRepository
    @Environment(\.dismiss) private var dismiss

    let cragId: String
    let wallId: String
    var editing: Route? = nil
    let onCreated: (String) -> Void

    @State private var name = ""
    @State private var grade = ""
    @State private var lengthText = ""
    @State private var boltsText = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("Route name", text: $name)
                TextField("Grade (e.g. 5.10a)", text: $grade)
                TextField("Length (metres)", text: $lengthText).keyboardType(.numberPad)
                TextField("Bolt count", text: $boltsText).keyboardType(.numberPad)
            }
            .navigationTitle(editing == nil ? "New route" : "Edit route")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(editing == nil ? "Add" : "Save") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                if let editing {
                    name = editing.name
                    grade = editing.grade
                    lengthText = String(editing.lengthMeters)
                    boltsText = String(editing.boltCount)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let length = Int(lengthText) ?? 0
        let bolts = Int(boltsText) ?? 0
        if let editing {
            cragRepo.updateRoute(cragId: cragId, wallId: wallId, routeId: editing.id,
                                  name: trimmed, grade: grade.trimmingCharacters(in: .whitespaces),
                                  lengthMeters: length, boltCount: bolts) { success in
                if success { onCreated(editing.id) }
            }
        } else {
            let newId = UUID().uuidString
            let route = Route(id: newId, name: trimmed, grade: grade.trimmingCharacters(in: .whitespaces),
                               lengthMeters: length, boltCount: bolts)
            cragRepo.addRoute(cragId: cragId, wallId: wallId, route: route) { success in
                if success { onCreated(newId) }
            }
        }
        dismiss()
    }
}

/// Edit-crag-info sheet (dialog_edit_crag_info port).
struct EditCragInfoSheet: View {
    @EnvironmentObject var cragRepo: CragRepository
    @Environment(\.dismiss) private var dismiss
    let cragId: String

    @State private var name = ""
    @State private var area = ""
    @State private var latText = ""
    @State private var lngText = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                TextField("Area", text: $area)
                TextField("Latitude", text: $latText).keyboardType(.numbersAndPunctuation)
                TextField("Longitude", text: $lngText).keyboardType(.numbersAndPunctuation)
            }
            .navigationTitle("Edit crag info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                guard let crag = cragRepo.byId(cragId) else { return }
                name = crag.name; area = crag.area
                latText = String(crag.lat); lngText = String(crag.lng)
            }
        }
        .presentationDetents([.medium])
    }

    private func save() {
        guard let crag = cragRepo.byId(cragId) else { return }
        cragRepo.updateCragInfo(
            cragId: cragId,
            name: name.trimmingCharacters(in: .whitespaces),
            area: area.trimmingCharacters(in: .whitespaces),
            lat: Double(latText) ?? crag.lat,
            lng: Double(lngText) ?? crag.lng
        )
        dismiss()
    }
}
