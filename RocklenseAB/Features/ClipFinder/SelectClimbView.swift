import SwiftUI

/// The Clip Finder tab's entry screen: a breadcrumb-style drill-down picker
/// (crag -> wall -> route). Once all three are chosen, tapping the logo opens
/// the camera (ARClipFinderScreen) already pointed at that specific route.
/// Port of SelectClimbFragment, including:
///  - creating a new wall or route right from the picker (creating a wall
///    jumps straight into setting it up; a new route jumps into mapping its
///    first clip, via wall setup first if needed);
///  - reactively re-validating the selection against the live crag data and
///    clearing anything that no longer exists;
///  - only showing AR-*mapped* crags/walls and *clip-mapped* routes.
struct SelectClimbView: View {
    @EnvironmentObject var cragRepo: CragRepository

    @State private var selectedCragId: String?
    @State private var selectedWallId: String?
    @State private var selectedRouteId: String?

    @State private var showCragPicker = false
    @State private var showWallPicker = false
    @State private var showRoutePicker = false
    @State private var toastText: String?

    @State private var showAddWall = false
    @State private var showAddRoute = false
    @State private var navigateToSetupWall: (cragId: String, wallId: String)?
    @State private var navigateToMapRoute: (cragId: String, wallId: String, routeId: String)?
    @State private var launchAR = false
    @State private var showARUnsupported = false

    private var mappedCrags: [Crag] { cragRepo.crags.filter { $0.walls.contains { $0.isMapped } } }
    private var selectedCrag: Crag? { selectedCragId.flatMap { cragRepo.byId($0) } }
    private var selectedWall: Wall? {
        guard let cragId = selectedCragId, let wallId = selectedWallId else { return nil }
        return cragRepo.wallById(cragId, wallId)
    }
    private var selectedRoute: Route? { selectedWall?.routes.first { $0.id == selectedRouteId } }
    private var mappedWalls: [Wall] { selectedCrag?.walls.filter { $0.isMapped } ?? [] }
    private var mappedRoutes: [Route] { selectedWall?.routes.filter { !$0.clips.isEmpty } ?? [] }

    var body: some View {
        ZStack {
            RLColor.limestone.ignoresSafeArea()
            VStack(spacing: 32) {
                Spacer()

                // The logo button -- tap once fully selected to open the camera.
                Button {
                    guard selectedCrag != nil, selectedWall != nil, selectedRoute != nil else {
                        toast("Choose a crag, wall, and route first"); return
                    }
                    if ARCapability.isSupported { launchAR = true } else { showARUnsupported = true }
                } label: {
                    ZStack {
                        Circle().fill(RLColor.dusk).frame(width: 150, height: 150)
                        Image(systemName: "camera.viewfinder")
                            .font(.system(size: 54))
                            .foregroundStyle(RLColor.rust)
                    }
                }
                Text("Tap to open the Clip Finder camera")
                    .font(.system(size: 13))
                    .foregroundStyle(RLColor.inactiveText)

                VStack(alignment: .leading, spacing: 20) {
                    breadcrumbRow(text: "\u{003E} \(selectedCrag?.name ?? "select a crag")",
                                  active: true) { openCragPicker() }
                    breadcrumbRow(text: "\u{003E} \(selectedWall?.name ?? "select a wall")",
                                  active: selectedCrag != nil) { openWallPicker() }
                    breadcrumbRow(text: "\u{003E} \(selectedRoute.map { "\($0.name) (\($0.grade))" } ?? "select a route")",
                                  active: selectedWall != nil) { openRoutePicker() }
                }
                .padding(.horizontal, 36)

                Spacer()

                if let toastText {
                    Text(toastText)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(RLColor.chalk)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(RLColor.dusk.opacity(0.9), in: Capsule())
                        .padding(.bottom, 12)
                        .transition(.opacity)
                }
            }
        }
        .navigationTitle("Clip Finder")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: cragRepo.crags) { _ in revalidateSelection() }
        // Pickers
        .confirmationDialog("Select a crag", isPresented: $showCragPicker, titleVisibility: .visible) {
            ForEach(mappedCrags) { crag in
                Button(crag.name) {
                    selectedCragId = crag.id
                    selectedWallId = nil
                    selectedRouteId = nil
                }
            }
        }
        .confirmationDialog("Select a wall", isPresented: $showWallPicker, titleVisibility: .visible) {
            ForEach(mappedWalls) { wall in
                Button(wall.name) {
                    selectedWallId = wall.id
                    selectedRouteId = nil
                }
            }
            Button("+ Create new wall") { showAddWall = true }
        }
        .confirmationDialog("Select a route", isPresented: $showRoutePicker, titleVisibility: .visible) {
            ForEach(mappedRoutes) { route in
                Button("\(route.name) (\(route.grade))") { selectedRouteId = route.id }
            }
            Button("+ Create new route") { showAddRoute = true }
        }
        // Create-new sheets
        .sheet(isPresented: $showAddWall) {
            if let crag = selectedCrag {
                AddWallSheet(cragId: crag.id) { newWallId in
                    // A freshly created wall always needs setup before it's
                    // usable anywhere -- jump straight there.
                    navigateToSetupWall = (crag.id, newWallId)
                }
            }
        }
        .sheet(isPresented: $showAddRoute) {
            if let crag = selectedCrag, let wall = selectedWall {
                AddRouteSheet(cragId: crag.id, wallId: wall.id) { newRouteId in
                    // A freshly created route has no clips yet -- go place its
                    // first one right away (via wall setup first if needed).
                    if wall.isMapped {
                        navigateToMapRoute = (crag.id, wall.id, newRouteId)
                    } else {
                        navigateToSetupWall = (crag.id, wall.id)
                    }
                }
            }
        }
        // Navigation
        .navigationDestination(isPresented: Binding(
            get: { navigateToSetupWall != nil },
            set: { if !$0 { navigateToSetupWall = nil } }
        )) {
            if let dest = navigateToSetupWall {
                SetupWallView(cragId: dest.cragId, wallId: dest.wallId)
            }
        }
        .navigationDestination(isPresented: Binding(
            get: { navigateToMapRoute != nil },
            set: { if !$0 { navigateToMapRoute = nil } }
        )) {
            if let dest = navigateToMapRoute {
                MapRouteView(cragId: dest.cragId, wallId: dest.wallId, routeId: dest.routeId)
            }
        }
        .fullScreenCover(isPresented: $launchAR) {
            if let crag = selectedCrag, let wall = selectedWall, let route = selectedRoute {
                ARClipFinderScreen(cragId: crag.id, wallId: wall.id, routeId: route.id)
                    .environmentObject(cragRepo)
            }
        }
        .alert("AR isn't available on this device", isPresented: $showARUnsupported) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The Clip Finder camera needs ARKit support. The Crag Map and Profile tabs work everywhere.")
        }
    }

    private func breadcrumbRow(text: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(active ? RLColor.ink : RLColor.inactiveText)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func openCragPicker() {
        if mappedCrags.isEmpty { toast("No AR-mapped crags yet"); return }
        showCragPicker = true
    }
    private func openWallPicker() {
        guard selectedCrag != nil else { toast("Select a crag first"); return }
        showWallPicker = true
    }
    private func openRoutePicker() {
        guard selectedCrag != nil, selectedWall != nil else { toast("Select a crag and wall first"); return }
        showRoutePicker = true
    }

    /// Drops any part of the current selection that no longer exists -- e.g.
    /// a wall/route deleted and recreated (brand-new id) since it was picked.
    private func revalidateSelection() {
        guard let cragId = selectedCragId, cragRepo.byId(cragId) != nil else {
            selectedCragId = nil; selectedWallId = nil; selectedRouteId = nil; return
        }
        guard let wallId = selectedWallId, cragRepo.wallById(cragId, wallId) != nil else {
            selectedWallId = nil; selectedRouteId = nil; return
        }
        if let routeId = selectedRouteId {
            let route = cragRepo.wallById(cragId, wallId)?.routes.first { $0.id == routeId }
            if route == nil || route!.clips.isEmpty { selectedRouteId = nil }
        }
    }

    private func toast(_ text: String) {
        withAnimation { toastText = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation { toastText = nil }
        }
    }
}
