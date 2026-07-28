import FirebaseFirestore
import SwiftUI

/// The Profile tab: a READ-ONLY view of your own profile (avatar, name,
/// location, bio) plus account status, and four swipeable tabs -- Recents,
/// Favorites, Posted Reviews, and Friends. Editing anything only happens via
/// the gear icon -> Settings -> Edit Profile, matching the Android design.
struct ProfileView: View {
    @EnvironmentObject var auth: AuthService
    @State private var refreshToken = 0   // bumped on appear to re-read LocalProfileStore
    @State private var selectedTab = 0

    var body: some View {
        VStack(spacing: 0) {
            profileHeader
                .id(refreshToken)

            Picker("", selection: $selectedTab) {
                Text("Recents").tag(0)
                Text("Favorites").tag(1)
                Text("Posted Reviews").tag(2)
                Text("Friends").tag(3)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, RLMetrics.screenPadding)
            .padding(.vertical, 10)

            TabView(selection: $selectedTab) {
                RecentsListView().tag(0)
                FavoritesListView().tag(1)
                PostedReviewsListView().tag(2)
                FriendsView().tag(3)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
        }
        .background(RLColor.limestone)
        .navigationTitle("Profile")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                NavigationLink { SettingsView() } label: { Image(systemName: "gearshape") }
            }
        }
        .onAppear {
            // Refresh in case fields were changed on Edit Profile and we're
            // returning here. A Google account already has a real display
            // name -- use it to pre-fill if the climber hasn't set one.
            if LocalProfileStore.name.isEmpty, auth.isGoogleAccount,
               let name = auth.currentUser?.displayName {
                LocalProfileStore.name = name
            }
            refreshToken += 1
        }
    }

    private var profileHeader: some View {
        VStack(spacing: 8) {
            AvatarCircleView(size: 88)

            Text(LocalProfileStore.name.isEmpty ? "Add your name" : LocalProfileStore.name)
                .font(.system(size: 21, weight: .bold))
                .foregroundStyle(RLColor.ink)

            if !LocalProfileStore.location.isEmpty {
                Text(LocalProfileStore.location)
                    .font(.system(size: 13)).foregroundStyle(RLColor.pine)
            }
            if !LocalProfileStore.bio.isEmpty {
                Text(LocalProfileStore.bio)
                    .font(.system(size: 13)).foregroundStyle(RLColor.ink.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            if !LocalProfileStore.climberType.isEmpty {
                Text("\(LocalProfileStore.climberType) Climber").rlChip(background: RLColor.pine, foreground: RLColor.chalk)
            }

            Text(accountStatus)
                .font(.system(size: 11))
                .foregroundStyle(RLColor.inactiveText)
        }
        .padding(.top, 12)
    }

    private var accountStatus: String {
        guard let user = auth.currentUser else { return "Not signed in" }
        if auth.isGoogleAccount {
            return "Signed in as \(user.email ?? user.displayName ?? "Google account")"
        }
        if auth.isLinkedAccount {
            return "Signed in with Apple"
        }
        return "Independent profile (not linked to an account)"
    }
}

/// The circular avatar, loading the per-account local file (same
/// profile_avatar_{uid}.jpg pattern as Android).
struct AvatarCircleView: View {
    let size: CGFloat
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "person.fill")
                    .font(.system(size: size * 0.45))
                    .foregroundStyle(RLColor.pine)
            }
        }
        .frame(width: size, height: size)
        .background(RLColor.chalk)
        .clipShape(Circle())
        .onAppear { image = AvatarStore.loadLocal() }
    }
}

// MARK: - Recents / Favorites (RecentsFragment / FavoritesFragment ports)

/// Routes the climber has actually scanned with the Clip Finder camera,
/// most-recent first -- recorded automatically, not manually added.
struct RecentsListView: View {
    @EnvironmentObject var cragRepo: CragRepository

    private var items: [ClimbListItem] {
        LocalProfileStore.recentClimbs().compactMap { entry in
            guard let crag = cragRepo.byId(entry.cragId),
                  let wall = cragRepo.wallById(entry.cragId, entry.wallId),
                  let route = wall.routes.first(where: { $0.id == entry.routeId }) else { return nil }
            return ClimbListItem(route: route, wall: wall, crag: crag, distanceKm: nil)
        }
    }

    var body: some View {
        ClimbList(items: items,
                  emptyText: "No recent climbs yet \u{2014} scan a route with the Clip Finder camera to see it here")
    }
}

/// Routes the climber has hearted -- local-only, same as Android.
struct FavoritesListView: View {
    @EnvironmentObject var cragRepo: CragRepository

    private var items: [ClimbListItem] {
        let ids = LocalProfileStore.favoriteRouteIds()
        return cragRepo.crags.flatMap { crag in
            crag.walls.flatMap { wall in
                wall.routes.filter { ids.contains($0.id) }
                    .map { ClimbListItem(route: $0, wall: wall, crag: crag, distanceKm: nil) }
            }
        }
    }

    var body: some View {
        ClimbList(items: items,
                  emptyText: "No favorites yet \u{2014} tap the heart on a route to save it here")
    }
}

private struct ClimbList: View {
    let items: [ClimbListItem]
    let emptyText: String

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                if items.isEmpty {
                    Text(emptyText)
                        .font(.system(size: 13))
                        .foregroundStyle(RLColor.inactiveText)
                        .multilineTextAlignment(.center)
                        .padding(.top, 40)
                        .padding(.horizontal, 30)
                }
                ForEach(items) { item in
                    NavigationLink {
                        CragDetailView(cragId: item.crag.id)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.route.name)
                                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(RLColor.ink)
                                Text("\(item.route.grade) \u{00b7} \(item.wall.name) \u{00b7} \(item.crag.name)")
                                    .font(.system(size: 12)).foregroundStyle(RLColor.pine)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(RLColor.inactiveText)
                        }
                        .padding(12)
                        .background(RLColor.chalk, in: RoundedRectangle(cornerRadius: 14))
                    }
                }
            }
            .padding(RLMetrics.screenPadding)
        }
    }
}

// MARK: - Posted reviews (PostedReviewsFragment port)

/// Reviews posted from this device -- "reviews I remember posting," not a
/// cross-device history (see LocalProfileStore.postedReviewIds).
struct PostedReviewsListView: View {
    @State private var reviews: [Review] = []
    @State private var loaded = false

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                if loaded && reviews.isEmpty {
                    Text("No reviews posted yet")
                        .font(.system(size: 13)).foregroundStyle(RLColor.inactiveText)
                        .padding(.top, 40)
                }
                ForEach(reviews) { review in
                    ReviewRow(review: review)
                }
            }
            .padding(RLMetrics.screenPadding)
        }
        .onAppear(perform: load)
    }

    private func load() {
        let ids = Array(LocalProfileStore.postedReviewIds().prefix(30))
        guard !ids.isEmpty else { loaded = true; reviews = []; return }
        // whereIn(documentId) tops out at 30 values -- plenty for a personal list.
        Firestore.firestore().collection("reviews")
            .whereField(FieldPath.documentID(), in: ids)
            .getDocuments { snapshot, _ in
                let loadedReviews = snapshot?.documents.compactMap { doc -> Review? in
                    var r = try? doc.data(as: Review.self)
                    r?.id = doc.documentID
                    return r
                } ?? []
                reviews = loadedReviews.sorted { $0.timestampMillis > $1.timestampMillis }
                loaded = true
            }
    }
}

// MARK: - Friends (FriendsFragment port)

struct FriendsView: View {
    @State private var searchQuery = ""
    @State private var searchResults: [UserProfile] = []
    @State private var requests: [FriendRequest] = []
    @State private var friends: [FriendRequest] = []
    @State private var toastText: String?

    private var myUid: String { AuthService.shared.currentUser?.uid ?? "" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                // Search-for-friends bar -- lives here (on the Friends tab),
                // same placement decision as Android.
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(RLColor.inactiveText)
                    TextField("Search climbers by name", text: $searchQuery)
                        .autocorrectionDisabled()
                }
                .padding(12)
                .background(RLColor.chalk, in: RoundedRectangle(cornerRadius: 14))
                .onChange(of: searchQuery) { query in
                    let q = query.trimmingCharacters(in: .whitespaces)
                    guard q.count >= 2 else { searchResults = []; return }
                    FriendsRepository.shared.searchUsers(query: q) { searchResults = $0 }
                }

                ForEach(searchResults, id: \.uid) { user in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(user.displayName).font(.system(size: 14, weight: .semibold)).foregroundStyle(RLColor.ink)
                            if !user.location.isEmpty {
                                Text(user.location).font(.system(size: 12)).foregroundStyle(RLColor.pine)
                            }
                        }
                        Spacer()
                        Button("Add") {
                            FriendsRepository.shared.sendFriendRequest(toUid: user.uid, toName: user.displayName) { success in
                                toast(success ? "Friend request sent" : "Couldn't send request \u{2014} try again")
                            }
                        }
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(RLColor.rust)
                    }
                    .padding(12)
                    .background(RLColor.chalk, in: RoundedRectangle(cornerRadius: 14))
                }

                if !requests.isEmpty {
                    Text("Friend requests")
                        .font(.system(size: 14, weight: .bold)).foregroundStyle(RLColor.ink)
                    ForEach(requests) { request in
                        HStack {
                            Text(request.fromName)
                                .font(.system(size: 14, weight: .semibold)).foregroundStyle(RLColor.ink)
                            Spacer()
                            Button("Accept") { respond(request, accept: true) }
                                .font(.system(size: 13, weight: .semibold)).foregroundStyle(RLColor.pine)
                            Button("Decline") { respond(request, accept: false) }
                                .font(.system(size: 13, weight: .semibold)).foregroundStyle(RLColor.rust)
                                .padding(.leading, 8)
                        }
                        .padding(12)
                        .background(RLColor.chalk, in: RoundedRectangle(cornerRadius: 14))
                    }
                }

                Text("Friends")
                    .font(.system(size: 14, weight: .bold)).foregroundStyle(RLColor.ink)
                if friends.isEmpty {
                    Text("No friends yet \u{2014} search for climbers above")
                        .font(.system(size: 13)).foregroundStyle(RLColor.inactiveText)
                }
                ForEach(friends) { friendship in
                    let otherUid = friendship.fromUid == myUid ? friendship.toUid : friendship.fromUid
                    let otherName = friendship.fromUid == myUid ? friendship.toName : friendship.fromName
                    NavigationLink {
                        FriendProfileView(uid: otherUid)
                    } label: {
                        HStack(spacing: 10) {
                            // Best-effort per-row avatar lookup, same as
                            // FriendRequestAdapter -- fine at friend-list scale.
                            FriendAvatarView(uid: otherUid)
                            Text(otherName).font(.system(size: 14, weight: .semibold)).foregroundStyle(RLColor.ink)
                            Spacer()
                            Text("Friend")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(RLColor.pine)
                            Image(systemName: "chevron.right").foregroundStyle(RLColor.inactiveText)
                        }
                        .padding(12)
                        .background(RLColor.chalk, in: RoundedRectangle(cornerRadius: 14))
                    }
                }

                if let toastText {
                    Text(toastText).font(.system(size: 12)).foregroundStyle(RLColor.pine)
                }
            }
            .padding(RLMetrics.screenPadding)
        }
        .onAppear(perform: load)
    }

    private func load() {
        FriendsRepository.shared.incomingPendingRequests { requests = $0 }
        FriendsRepository.shared.friendsList { friends = $0 }
    }

    private func respond(_ request: FriendRequest, accept: Bool) {
        FriendsRepository.shared.respondToRequest(requestId: request.id, accept: accept) { success in
            if success {
                if accept { toast("Friend added") }
                load()
            } else {
                toast("Couldn't respond \u{2014} try again")
            }
        }
    }

    private func toast(_ text: String) {
        toastText = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { toastText = nil }
    }
}

// MARK: - Friend profile (FriendProfileFragment port)

/// Small circular avatar for a friend row -- fetches the public profile's
/// avatarUrl on appear (FriendRequestAdapter's Glide lookup equivalent).
struct FriendAvatarView: View {
    let uid: String
    @State private var avatarUrl: URL?

    var body: some View {
        Group {
            if let avatarUrl {
                AsyncImage(url: avatarUrl) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Image(systemName: "person.fill").font(.system(size: 14)).foregroundStyle(RLColor.pine)
                }
            } else {
                Image(systemName: "person.fill").font(.system(size: 14)).foregroundStyle(RLColor.pine)
            }
        }
        .frame(width: 32, height: 32)
        .background(RLColor.limestone)
        .clipShape(Circle())
        .onAppear {
            FriendsRepository.shared.fetchUserProfile(uid: uid) { profile in
                if let url = profile.flatMap({ $0.avatarUrl.isEmpty ? nil : URL(string: $0.avatarUrl) }) {
                    avatarUrl = url
                }
            }
        }
    }
}

/// A friend's profile -- READ-ONLY, with a Remove Friend action where the
/// settings gear sits on your own profile.
struct FriendProfileView: View {
    @Environment(\.dismiss) private var dismiss
    let uid: String

    @State private var profile: UserProfile?
    @State private var confirmRemove = false
    @State private var loadFailed = false

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                Group {
                    if let url = profile.flatMap({ $0.avatarUrl.isEmpty ? nil : URL(string: $0.avatarUrl) }) {
                        AsyncImage(url: url) { image in image.resizable().scaledToFill() }
                            placeholder: { ProgressView() }
                    } else {
                        Image(systemName: "person.fill")
                            .font(.system(size: 40)).foregroundStyle(RLColor.pine)
                    }
                }
                .frame(width: 96, height: 96)
                .background(RLColor.chalk)
                .clipShape(Circle())
                .padding(.top, 24)

                Text(profile?.displayName ?? "")
                    .font(.system(size: 22, weight: .bold)).foregroundStyle(RLColor.ink)
                if let location = profile?.location, !location.isEmpty {
                    Text(location).font(.system(size: 13)).foregroundStyle(RLColor.pine)
                }
                if let type = profile?.climberType, !type.isEmpty {
                    Text("\(type) Climber").rlChip(background: RLColor.pine, foreground: RLColor.chalk)
                }
                if let bio = profile?.bio, !bio.isEmpty {
                    Text(bio)
                        .font(.system(size: 14)).foregroundStyle(RLColor.ink.opacity(0.75))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 30)
                }

                if loadFailed {
                    Text("Couldn't load this profile")
                        .font(.system(size: 13)).foregroundStyle(RLColor.rust)
                }

                Button("Remove friend", role: .destructive) { confirmRemove = true }
                    .padding(.top, 24)
            }
        }
        .background(RLColor.limestone)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            FriendsRepository.shared.fetchUserProfile(uid: uid) { fetched in
                if fetched == nil { loadFailed = true } else { profile = fetched }
            }
        }
        .alert("Remove this friend?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) {
                FriendsRepository.shared.removeFriend(otherUid: uid) { success in
                    if success { dismiss() }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}
