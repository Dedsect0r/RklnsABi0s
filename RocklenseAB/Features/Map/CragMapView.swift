import CoreLocation
import FirebaseFirestore
import MapKit
import SwiftUI

/// The Crag Map tab: a full-screen map with a draggable sheet over it.
/// Collapsed, the sheet shows a horizontal strip of nearby climbs; dragged
/// up, it becomes a real search bar, Reviews/Grade filter chips, and a
/// vertical list of crag preview cards sorted by distance. Port of
/// CragMapFragment on Apple MapKit (per your platform choice) -- same
/// interactions: tap a pin/card to open the crag, long-press the map to
/// pre-fill coordinates for a new crag, + button to add a crag, first tap of
/// the locate button centers, second tap (while centered) zooms in close.
struct CragMapView: View {
    @EnvironmentObject var cragRepo: CragRepository
    @StateObject private var locationFetcher = LocationFetcher()

    @State private var cameraPosition = MapCameraPosition.region(
        // Same default framing as onMapReady's newLatLngZoom(51.06, -115.24)
        // -- Bow Valley center, seeded crags in view on first launch.
        MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 51.06, longitude: -115.24),
                            span: MKCoordinateSpan(latitudeDelta: 0.35, longitudeDelta: 0.35)))
    @State private var userLocation: CLLocationCoordinate2D?
    @State private var distancesKm: [String: Float] = [:]

    @State private var searchQuery = ""
    @State private var minRatingFilter: Int?    // nil = Any
    @State private var gradeRangeFilter: ClosedRange<Int>?  // nil = Any
    @State private var averageRatingByCrag: [String: Double]?

    @State private var sheetDetent: PresentationDetent = .height(150)
    @State private var showAddCrag = false
    @State private var addCragPrefill: CLLocationCoordinate2D?
    @State private var openCragId: String?
    @State private var cragPendingDelete: Crag?

    var body: some View {
        ZStack {
            mapLayer

            VStack {
                Spacer()
                mapSheet
            }

            // Floating + button (fab_add_crag) -- hidden while the sheet is
            // expanded, same as the Android sheet callback.
            if sheetDetent != .large {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Button {
                            addCragPrefill = nil
                            showAddCrag = true
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 22, weight: .bold))
                                .foregroundStyle(RLColor.chalk)
                                .frame(width: 56, height: 56)
                                .background(RLColor.rust, in: Circle())
                                .shadow(radius: 6)
                        }
                        .padding(.trailing, 20)
                        .padding(.bottom, 190)
                    }
                }
            }
        }
        .navigationTitle("Crag Map")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: fetchLocationAndSort)
        .sheet(isPresented: $showAddCrag) {
            AddCragSheet(prefill: addCragPrefill)
        }
        .navigationDestination(isPresented: Binding(
            get: { openCragId != nil },
            set: { if !$0 { openCragId = nil } }
        )) {
            if let cragId = openCragId {
                CragDetailView(cragId: cragId)
            }
        }
        .alert("Delete \(cragPendingDelete?.name ?? "")?",
               isPresented: Binding(get: { cragPendingDelete != nil },
                                     set: { if !$0 { cragPendingDelete = nil } })) {
            Button("Delete", role: .destructive) {
                if let crag = cragPendingDelete { cragRepo.deleteCrag(crag.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the crag and all its walls and routes. This can't be undone.")
        }
    }

    // MARK: Map

    private var mapLayer: some View {
        MapReader { proxy in
            Map(position: $cameraPosition) {
                UserAnnotation()
                ForEach(cragRepo.crags) { crag in
                    Annotation(crag.name, coordinate: CLLocationCoordinate2D(latitude: crag.lat, longitude: crag.lng)) {
                        Button { openCragId = crag.id } label: {
                            VStack(spacing: 2) {
                                Image(systemName: "mappin.circle.fill")
                                    .font(.system(size: 28))
                                    .foregroundStyle(RLColor.rust)
                                Text("\(crag.routeCount) routes")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(RLColor.ink)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(RLColor.chalk, in: Capsule())
                            }
                        }
                    }
                }
            }
            .mapControls {
                MapUserLocationButton()
                MapCompass()
            }
            .gesture(
                LongPressGesture(minimumDuration: 0.5)
                    .sequenced(before: DragGesture(minimumDistance: 0))
                    .onEnded { value in
                        // Long-press anywhere to drop a pin and pre-fill
                        // coordinates for a new crag (map long-press port).
                        if case .second(true, let drag?) = value,
                           let coordinate = proxy.convert(drag.location, from: .local) {
                            addCragPrefill = coordinate
                            showAddCrag = true
                        }
                    }
            )
            .ignoresSafeArea(edges: .bottom)
        }
    }

    // MARK: Sheet (the BottomSheetBehavior port)

    private var mapSheet: some View {
        VStack(spacing: 0) {
            // Drag handle -- tapping toggles expanded/collapsed like the
            // Android sheet's handle tap.
            Button {
                withAnimation { sheetDetent = sheetDetent == .large ? .height(150) : .large }
            } label: {
                Capsule().fill(RLColor.cream50).frame(width: 44, height: 5).padding(.vertical, 10)
            }

            if sheetDetent == .large {
                expandedSheetContent
            } else {
                collapsedSheetContent
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: sheetDetent == .large ? 520 : 150, alignment: .top)
        .background(RLColor.dusk, in: UnevenRoundedRectangle(topLeadingRadius: RLMetrics.sheetTopCorner,
                                                              topTrailingRadius: RLMetrics.sheetTopCorner))
        .gesture(
            DragGesture(minimumDistance: 20)
                .onEnded { value in
                    withAnimation {
                        if value.translation.height < -40 { sheetDetent = .large }
                        else if value.translation.height > 40 { sheetDetent = .height(150) }
                    }
                }
        )
        .animation(.spring(duration: 0.35), value: sheetDetent == .large)
    }

    private var collapsedSheetContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Climbs Near You")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(RLColor.chalk)
                .padding(.horizontal, 16)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(climbItems) { item in
                        Button { openCragId = item.crag.id } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.route.name)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(RLColor.ink)
                                    .lineLimit(1)
                                Text("\(item.route.grade) \u{00b7} \(item.crag.name)")
                                    .font(.system(size: 11))
                                    .foregroundStyle(RLColor.ink.opacity(0.6))
                                    .lineLimit(1)
                                if let d = item.distanceKm {
                                    Text(String(format: "%.1f km", d))
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(RLColor.foliage)
                                }
                            }
                            .padding(10)
                            .frame(width: 150, alignment: .leading)
                            .background(RLColor.chalk, in: RoundedRectangle(cornerRadius: 14))
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private var expandedSheetContent: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(RLColor.cream50)
                TextField("", text: $searchQuery,
                          prompt: Text("Search crags, walls, routes").foregroundStyle(RLColor.cream50))
                    .foregroundStyle(RLColor.chalk)
            }
            .padding(12)
            .background(RLColor.dusk2, in: RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal, 16)

            HStack(spacing: 10) {
                Menu {
                    ratingOption("Any", nil)
                    ratingOption("3+ stars", 3)
                    ratingOption("4+ stars", 4)
                    ratingOption("5 stars only", 5)
                } label: {
                    Text("\(ratingFilterLabel) \u{25be}").rlChip(background: RLColor.dusk2, foreground: RLColor.chalk)
                }
                Menu {
                    gradeOption("Any", nil)
                    gradeOption("Beginner (5.0\u{2013}5.6)", 0...6)
                    gradeOption("Intermediate (5.7\u{2013}5.9)", 7...9)
                    gradeOption("Advanced (5.10\u{2013}5.11)", 10...11)
                    gradeOption("Expert (5.12+)", 12...99)
                } label: {
                    Text("\(gradeFilterLabel) \u{25be}").rlChip(background: RLColor.dusk2, foreground: RLColor.chalk)
                }
                Spacer()
            }
            .padding(.horizontal, 16)

            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(filteredCrags) { crag in
                        CragPreviewCard(crag: crag, distanceKm: distancesKm[crag.id])
                            .onTapGesture { openCragId = crag.id }
                            .onLongPressGesture { cragPendingDelete = crag }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
        }
    }

    private func ratingOption(_ label: String, _ value: Int?) -> some View {
        Button(label) {
            minRatingFilter = value
            // Fetched once, lazily, the first time the Reviews filter is used.
            if value != nil && averageRatingByCrag == nil { loadAverageRatings() }
        }
    }
    private func gradeOption(_ label: String, _ value: ClosedRange<Int>?) -> some View {
        Button(label) { gradeRangeFilter = value }
    }

    private var ratingFilterLabel: String {
        switch minRatingFilter {
        case nil: return "Reviews"
        case 5: return "5 stars only"
        case let v?: return "\(v)+ stars"
        }
    }
    private var gradeFilterLabel: String {
        switch gradeRangeFilter {
        case nil: return "Grade"
        case 0...6: return "Beginner"
        case 7...9: return "Intermediate"
        case 10...11: return "Advanced"
        default: return "Expert"
        }
    }

    // MARK: Data

    private var climbItems: [ClimbListItem] { buildClimbList(crags: cragRepo.crags, distancesKm: distancesKm) }

    private var filteredCrags: [Crag] {
        cragRepo.crags
            .filter(matchesSearch)
            .filter(matchesRatingFilter)
            .filter(matchesGradeFilter)
            .sorted { (distancesKm[$0.id] ?? .greatestFiniteMagnitude) < (distancesKm[$1.id] ?? .greatestFiniteMagnitude) }
    }

    private func matchesSearch(_ crag: Crag) -> Bool {
        let q = searchQuery.trimmingCharacters(in: .whitespaces).lowercased()
        if q.isEmpty { return true }
        if crag.name.lowercased().contains(q) || crag.area.lowercased().contains(q) { return true }
        return crag.walls.contains { wall in
            wall.name.lowercased().contains(q) || wall.routes.contains { $0.name.lowercased().contains(q) }
        }
    }

    private func matchesRatingFilter(_ crag: Crag) -> Bool {
        guard let minRating = minRatingFilter else { return true }
        guard let avg = averageRatingByCrag?[crag.id] else { return false }
        return avg >= Double(minRating)
    }

    private func matchesGradeFilter(_ crag: Crag) -> Bool {
        guard let range = gradeRangeFilter else { return true }
        return crag.walls.contains { wall in
            wall.routes.contains { route in
                parseGradeNumeric(route.grade).map { range.contains($0) } ?? false
            }
        }
    }

    /// Fetches every review once and averages ratings per crag client-side
    /// -- same "fine at this scale" decision as Android.
    private func loadAverageRatings() {
        Firestore.firestore().collection("reviews").getDocuments { snapshot, _ in
            let reviews = snapshot?.documents.compactMap { try? $0.data(as: Review.self) } ?? []
            averageRatingByCrag = Dictionary(grouping: reviews, by: { $0.cragId })
                .mapValues { revs in Double(revs.map(\.stars).reduce(0, +)) / Double(revs.count) }
        }
    }

    private func fetchLocationAndSort() {
        locationFetcher.fetchCoordinates { coordinate in
            guard let coordinate else { return }
            userLocation = coordinate
            let userLoc = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            distancesKm = Dictionary(uniqueKeysWithValues: cragRepo.crags.map { crag in
                let d = userLoc.distance(from: CLLocation(latitude: crag.lat, longitude: crag.lng))
                return (crag.id, Float(d / 1000))
            })
        }
    }
}

/// Big crag preview card (item_crag_preview port): hero photo + name + grade
/// range + distance + tags.
struct CragPreviewCard: View {
    let crag: Crag
    let distanceKm: Float?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                Group {
                    if let url = crag.photoUrls.first.flatMap(URL.init) {
                        AsyncImage(url: url) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            LinearGradient(colors: [RLColor.foliage, RLColor.foliageDark],
                                           startPoint: .top, endPoint: .bottom)
                        }
                    } else {
                        LinearGradient(colors: [RLColor.foliage, RLColor.foliageDark],
                                       startPoint: .top, endPoint: .bottom)
                    }
                }
                .frame(height: 130)
                .clipped()

                HStack {
                    Text(gradeRangeLabel(crag)).rlChip()
                    if let d = distanceKm {
                        Text(String(format: "%.1f km", d)).rlChip(background: RLColor.pine, foreground: RLColor.chalk)
                    }
                }
                .padding(10)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(crag.name)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(RLColor.chalk)
                Text("\(crag.routeCount) routes \u{00b7} \(crag.area)")
                    .font(.system(size: 13))
                    .foregroundStyle(RLColor.cream70)
            }
            .padding(12)
        }
        .background(RLColor.dusk2, in: RoundedRectangle(cornerRadius: RLMetrics.cardCorner))
        .clipShape(RoundedRectangle(cornerRadius: RLMetrics.cardCorner))
    }
}

/// New-crag form (dialog_add_crag port) -- name/area/lat/lng/blurb/tags,
/// with a "use current location" pre-fill and optional coordinates prefilled
/// from a map long-press.
struct AddCragSheet: View {
    @EnvironmentObject var cragRepo: CragRepository
    @Environment(\.dismiss) private var dismiss
    @StateObject private var locationFetcher = LocationFetcher()

    let prefill: CLLocationCoordinate2D?

    @State private var name = ""
    @State private var area = ""
    @State private var latText = ""
    @State private var lngText = ""
    @State private var blurb = ""
    @State private var tags = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                TextField("Area (e.g. Canmore)", text: $area)
                HStack {
                    TextField("Latitude", text: $latText).keyboardType(.numbersAndPunctuation)
                    TextField("Longitude", text: $lngText).keyboardType(.numbersAndPunctuation)
                }
                Button {
                    locationFetcher.fetchCoordinates { coordinate in
                        if let coordinate {
                            latText = String(coordinate.latitude)
                            lngText = String(coordinate.longitude)
                        }
                    }
                } label: {
                    Label("Use current location", systemImage: "location.fill")
                }
                TextField("Short description", text: $blurb, axis: .vertical).lineLimit(2...4)
                TextField("Tags (comma separated)", text: $tags)
            }
            .navigationTitle("New crag")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { save() }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                if let prefill {
                    latText = String(prefill.latitude)
                    lngText = String(prefill.longitude)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func save() {
        let crag = Crag(
            name: name.trimmingCharacters(in: .whitespaces),
            area: area.trimmingCharacters(in: .whitespaces),
            lat: Double(latText) ?? 0,
            lng: Double(lngText) ?? 0,
            blurb: blurb.trimmingCharacters(in: .whitespaces),
            tags: tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        )
        cragRepo.addCrag(crag)
        dismiss()
    }
}
