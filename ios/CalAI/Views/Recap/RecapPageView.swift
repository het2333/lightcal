import SwiftUI

struct RecapPageView: View {
    let onScanFood: (() -> Void)?

    @State private var activeTab = "friends"
    @State private var friendName = ""
    @State private var friends: [Friend] = []
    @State private var leaderboard: [LeaderboardEntry] = []
    @State private var score: NutritionScore?
    @State private var challenges: [Challenge] = []
    @State private var streak = 0
    @State private var posts: [CommunityPost] = []
    @State private var loading = false
    @State private var status = ""
    @State private var checkinBusy = false
    @State private var commentDrafts: [String: String] = [:]

    private let topics = ["家常控卡", "食堂吃法", "外卖避坑", "高蛋白", "低油晚餐", "早餐打卡"]
    private var activeChallenges: [Challenge] { challenges.filter { $0.status == "active" } }
    private var topChallenge: Challenge? { activeChallenges.first }
    private var hasShareableStatus: Bool {
        guard let score else { return false }
        if score.score > 0 { return true }
        if !score.highlights.isEmpty || !score.nextActions.isEmpty { return true }
        let headline = score.headline.trimmingCharacters(in: .whitespacesAndNewlines)
        return !headline.isEmpty && !headline.contains("先记录")
    }
    private var checkinHeadlineText: String {
        if let headline = score?.headline.trimmingCharacters(in: .whitespacesAndNewlines), !headline.isEmpty, hasShareableStatus {
            return headline
        }
        return "先拍一餐，整理出今天状态卡后再分享。"
    }
    private var checkinChips: [String] {
        if let highlights = score?.highlights, !highlights.isEmpty {
            return Array(highlights.prefix(3))
        }
        if let nextActions = score?.nextActions, !nextActions.isEmpty {
            return Array(nextActions.prefix(3))
        }
        if !hasShareableStatus {
            return ["拍清楚整盘", "保存后整理", "结果可修改"]
        }
        return []
    }
    private var checkinPrimaryTitle: String {
        if checkinBusy { return "正在发布" }
        return hasShareableStatus ? "发今天状态卡" : "先拍一餐"
    }
    private var checkinPrimaryIcon: String {
        hasShareableStatus ? "square.and.arrow.up" : "camera.fill"
    }

    init(onScanFood: (() -> Void)? = nil) {
        self.onScanFood = onScanFood
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    checkinCard
                    segmentedControl
                    if activeTab == "friends" {
                        buddiesCard
                    } else {
                        discoverGuideCard
                    }
                    if activeTab == "discover" { topicScroller }
                    feedHeader
                    statusBanner
                    feedContent
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 118)
            }
            .background(AppShellBackground())
            .toolbar(.hidden, for: .navigationBar)
            .task { await refreshAll() }
            .refreshable { await refreshAll() }
            .onChange(of: activeTab) { _, _ in
                Task { await loadFeed() }
            }
        }
    }

    private var header: some View {
        CalPageHeader(
            title: "群组",
            subtitle: activeTab == "friends" ? "加入群组，查看朋友们在吃什么。" : "发现群组，和朋友一起达成目标。",
            systemImage: "person.2.fill"
        ) {
            Button { Task { await loadFeed() } } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Color(hex: "111318"))
                    .frame(width: 40, height: 40)
                    .background(.white)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(Color(hex: "F0F0F3"), lineWidth: 1))
                    .shadow(color: .black.opacity(0.05), radius: 10, x: 0, y: 4)
            }
            .disabled(loading)
            .accessibilityLabel("刷新今天打卡")
        }
    }

    private var segmentedControl: some View {
        HStack(spacing: 0) {
            communityTab("friends", "你的群组")
            communityTab("discover", "发现群组")
        }
        .padding(5)
        .background(.white.opacity(0.86))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(.white.opacity(0.85), lineWidth: 1))
        .shadow(color: .black.opacity(0.055), radius: 16, x: 0, y: 10)
    }

    private func communityTab(_ id: String, _ label: String) -> some View {
        Button {
            activeTab = id
        } label: {
            Text(label)
                .font(.system(size: 14, weight: .black))
                .foregroundStyle(activeTab == id ? Color(hex: "111318") : Color(hex: "6B7280"))
                .frame(maxWidth: .infinity)
                .frame(height: 42)
                .background(activeTab == id ? .white : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .shadow(color: activeTab == id ? .black.opacity(0.08) : .clear, radius: 10, x: 0, y: 5)
        }
    }

    private var checkinCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 14) {
                ZStack {
                    Circle()
                        .stroke(Color(hex: "EEF0F3"), lineWidth: 10)
                    Circle()
                        .trim(from: 0, to: min(1, max(0, (score?.score ?? 0) / 100)))
                        .stroke(Color(hex: "72D3A2"), style: StrokeStyle(lineWidth: 10, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    VStack(spacing: 0) {
                        Text("\(Int(round(score?.score ?? 0)))")
                            .font(.system(size: 27, weight: .black))
                            .foregroundStyle(Color(hex: "111318"))
                            .monospacedDigit()
                        Text("状态分")
                            .font(.system(size: 9, weight: .black))
                            .foregroundStyle(Color(hex: "9AA0AA"))
                    }
                }
                .frame(width: 94, height: 94)

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 7) {
                        Image(systemName: "calendar.badge.checkmark")
                            .accessibilityHidden(true)
                        Text("今天状态卡")
                    }
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(Color(hex: "72D3A2"))
                    Text(checkinHeadlineText)
                        .font(.system(size: 14, weight: .black))
                        .foregroundStyle(Color(hex: "24395F"))
                        .lineLimit(2)
                        .lineSpacing(2)
                    HStack(spacing: 8) {
                        checkinMiniMetric("连续", "\(streak)天")
                        checkinMiniMetric("挑战", topChallenge?.title ?? "待加入")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !checkinChips.isEmpty {
                FlowChips(items: checkinChips)
            }

            Button { handleCheckinPrimaryAction() } label: {
                HStack(spacing: 9) {
                    if checkinBusy {
                        ProgressView()
                            .tint(.white)
                            .scaleEffect(0.72)
                    } else {
                        Image(systemName: checkinPrimaryIcon)
                            .accessibilityHidden(true)
                    }
                    Text(checkinPrimaryTitle)
                }
                .font(.system(size: 15, weight: .black))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background(Color(hex: "111318"))
                .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
            }
            .disabled(checkinBusy)
            .opacity(checkinBusy ? 0.55 : 1)
        }
        .padding(16)
        .background(
            LinearGradient(
                colors: [.white.opacity(0.94), Color(hex: "ECFBF3").opacity(0.70)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 28).stroke(.white.opacity(0.86), lineWidth: 1))
        .shadow(color: .black.opacity(0.055), radius: 20, x: 0, y: 12)
    }

    private func checkinMiniMetric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 9, weight: .black))
                .foregroundStyle(Color(hex: "9AA0AA"))
            Text(value)
                .font(.system(size: 11, weight: .black))
                .foregroundStyle(Color(hex: "24395F"))
                .lineLimit(1)
                .minimumScaleFactor(0.68)
        }
        .padding(.horizontal, 9)
        .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
        .background(.white.opacity(0.78))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func handleCheckinPrimaryAction() {
        if hasShareableStatus {
            Task { await shareCheckin() }
        } else if let onScanFood {
            onScanFood()
        } else {
            status = "先从加号里记录一餐，状态卡会自动整理好。"
        }
    }

    private var buddiesCard: some View {
        VStack(spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("打卡伙伴")
                        .font(.system(size: 17, weight: .black))
                    Text(friends.isEmpty ? "先加一个一起坚持的人" : "\(friends.count) 位好友 · \(max(leaderboard.count, 1)) 人打卡")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: -8) {
                    let avatarItems = friends.isEmpty ? ["我"] : friends.prefix(3).map(\.friend)
                    ForEach(avatarItems, id: \.self) { name in
                        Circle()
                            .fill(Color(hex: "F3F4F6"))
                            .frame(width: 32, height: 32)
                            .overlay(Text(String(name.prefix(1))).font(.system(size: 12, weight: .black)))
                            .overlay(Circle().stroke(.white, lineWidth: 2))
                    }
                }
            }
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "person.crop.circle.badge.plus")
                        .font(.system(size: 16, weight: .black))
                        .foregroundStyle(Color(hex: "9AA1AC"))
                        .accessibilityHidden(true)
                        TextField("输入好友昵称", text: $friendName)
                        .font(.system(size: 14, weight: .black))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                .padding(.horizontal, 12)
                .frame(height: 44)
                .background(Color(hex: "F7F8FA"))
                .clipShape(Capsule())
                .overlay(Capsule().stroke(Color.white.opacity(0.9), lineWidth: 1))
                Button { Task { await inviteFriend() } } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 18, weight: .black))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(Color.black)
                        .clipShape(Circle())
                        .shadow(color: .black.opacity(0.12), radius: 12, x: 0, y: 6)
                }
                .accessibilityLabel("添加好友")
            }
        }
        .padding(18)
        .softCard(radius: 24)
    }

    private var discoverGuideCard: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "fork.knife.circle.fill")
                .font(.system(size: 30, weight: .black))
                .foregroundStyle(Color(hex: "111318"))
                .frame(width: 54, height: 54)
                .background(Color(hex: "F5F6F8"))
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                Text("看到合适的，直接记同款")
                    .font(.system(size: 17, weight: .black))
                    .foregroundStyle(Color(hex: "111318"))
                Text("这里不是刷帖，重点是少算一次、少纠结一餐。")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color(hex: "8A9099"))
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            Button {
                onScanFood?()
            } label: {
                Text("拍一餐")
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .frame(height: 36)
                    .background(Color.black)
                    .clipShape(Capsule())
            }
            .disabled(onScanFood == nil)
            .opacity(onScanFood == nil ? 0.45 : 1)
        }
        .padding(16)
        .softCard(radius: 24)
    }

    private var topicScroller: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(topics, id: \.self) { topic in
                    Text(topic)
                        .font(.system(size: 12, weight: .black))
                        .foregroundStyle(Color(hex: "374151"))
                        .padding(.horizontal, 14)
                        .frame(height: 34)
                        .background(.white.opacity(0.8))
                        .clipShape(Capsule())
                        .overlay(Capsule().stroke(.white, lineWidth: 1))
                        .shadow(color: .black.opacity(0.035), radius: 8, x: 0, y: 3)
                }
            }
        }
    }

    private var feedHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(activeTab == "friends" ? "好友今天做了什么" : "能直接记录的餐")
                    .font(.system(size: 20, weight: .black))
                Text(activeTab == "friends" ? "先看谁坚持了，再给一点反馈" : "别人保存过的餐，可以少算一次")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "checkmark.shield")
                    .accessibilityHidden(true)
                Text(activeTab == "friends" ? "少刷，多陪伴" : "能直接记录")
            }
            .font(.system(size: 12, weight: .black))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(.white.opacity(0.8))
            .clipShape(Capsule())
        }
    }

    @ViewBuilder
    private var statusBanner: some View {
        if !status.isEmpty {
            Text(status)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    @ViewBuilder
    private var feedContent: some View {
        if loading {
            Text(activeTab == "friends" ? "正在加载你的群组..." : "正在发现群组...")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
                .softCard(radius: 24)
        } else if posts.isEmpty {
            emptyFeed
        } else {
            ForEach(posts) { post in
                CommunityPostCard(
                    post: post,
                    draft: Binding(
                        get: { commentDrafts[post.id] ?? "" },
                        set: { commentDrafts[post.id] = $0 }
                    ),
                    onReact: { Task { await react(post) } },
                    onComment: { Task { await comment(post) } },
                    onBookmark: { Task { await bookmark(post) } },
                    onReport: { Task { await report(post) } },
                    onPrimary: { Task { await primaryAction(post) } }
                )
            }
        }
    }

    private var emptyFeed: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: activeTab == "friends" ? "calendar.badge.checkmark" : "magnifyingglass")
                .font(.system(size: 23, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 52, height: 52)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .accessibilityHidden(true)
            Text(activeTab == "friends" ? (hasShareableStatus ? "先发今天状态卡" : "先扫描食物，生成可分享状态") : "加入群组，查看朋友们在吃什么。")
                .font(.system(size: 19, weight: .black))
            Text(activeTab == "friends" ? (hasShareableStatus ? "发出去后，好友看到的是你的状态和下一步，不是复杂数据。" : "扫描并保存后，会整理成一张能分享的今日状态卡。") : "创建或加入群组后，可以和朋友一起追踪目标。")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineSpacing(3)
            Button {
                if activeTab == "friends" {
                    handleCheckinPrimaryAction()
                } else {
                    onScanFood?()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: activeTab == "friends" ? checkinPrimaryIcon : "camera.fill")
                        .accessibilityHidden(true)
                    Text(activeTab == "friends" ? checkinPrimaryTitle : "拍一餐生成同款")
                }
                .font(.system(size: 14, weight: .black))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 46)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .disabled(checkinBusy || (activeTab == "discover" && onScanFood == nil))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .softCard(radius: 24)
    }

    private func refreshAll() async {
        await loadOverview()
        await loadFeed()
    }

    private func loadOverview() async {
        async let friendsTask = APIClient.shared.getFriends()
        async let leaderboardTask = APIClient.shared.getLeaderboard()
        async let scoreTask = APIClient.shared.getNutritionScore()
        async let challengesTask = APIClient.shared.getChallenges()
        async let streakTask = APIClient.shared.getStreak()

        friends = (try? await friendsTask) ?? []
        leaderboard = (try? await leaderboardTask) ?? []
        score = try? await scoreTask
        challenges = (try? await challengesTask) ?? []
        streak = (try? await streakTask)?.streakDays ?? 0
    }

    private func loadFeed() async {
        loading = true
        status = ""
        do {
            let data = try await APIClient.shared.getCommunityFeed(tab: activeTab, user: "me", limit: 30)
            posts = data.posts
        } catch {
            posts = []
            status = friendlyCommunityError(error, fallback: "今天打卡暂时加载不出来，稍后再刷新。")
        }
        loading = false
    }

    private func inviteFriend() async {
        let name = friendName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        do {
            try await APIClient.shared.sendFriendRequest(toUser: name)
            friends.append(Friend(friendshipId: "pending-\(name)", friend: name, since: "pending"))
            friendName = ""
            status = "已发出邀请，等对方通过。"
        } catch {
            status = friendlyCommunityError(error, fallback: "好友邀请暂时没发出去，检查网络后再点邀请。")
        }
    }

    @MainActor
    private func shareCheckin() async {
        guard !checkinBusy else { return }
        checkinBusy = true
        status = ""
        defer { checkinBusy = false }
        do {
            let result = try await APIClient.shared.shareDailyCheckin()
            if let post = result.post {
                posts = [post] + posts.filter { $0.id != post.id }
                score = try? await APIClient.shared.getNutritionScore()
            }
            activeTab = "friends"
            status = "今天状态卡已发布。"
        } catch {
            status = friendlyCommunityError(error, fallback: "今天状态卡还没发出去，检查网络后再点发布。")
        }
    }

    private func replace(_ post: CommunityPost) {
        posts = posts.map { $0.id == post.id ? post : $0 }
    }

    private func react(_ post: CommunityPost) async {
        do {
            if let updated = try await APIClient.shared.reactCommunityPost(id: post.id).post {
                replace(updated)
            }
        } catch {
            status = friendlyCommunityError(error, fallback: "这次点赞没成功，检查网络后再点点赞。")
        }
    }

    private func comment(_ post: CommunityPost) async {
        let body = (commentDrafts[post.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        do {
            if let updated = try await APIClient.shared.commentCommunityPost(id: post.id, body: body).post {
                replace(updated)
                commentDrafts[post.id] = ""
            }
        } catch {
            status = friendlyCommunityError(error, fallback: "评论还没发出去，内容还在，检查网络后再点发送。")
        }
    }

    private func bookmark(_ post: CommunityPost) async {
        do {
            if let updated = try await APIClient.shared.bookmarkCommunityPost(id: post.id).post {
                replace(updated)
            }
        } catch {
            status = friendlyCommunityError(error, fallback: "收藏状态暂时没更新，检查网络后再点收藏。")
        }
    }

    private func report(_ post: CommunityPost) async {
        do {
            _ = try await APIClient.shared.reportCommunityPost(id: post.id)
            posts.removeAll { $0.id == post.id }
            status = "已隐藏这条内容"
        } catch {
            status = friendlyCommunityError(error, fallback: "这条内容暂时没隐藏成功，下拉刷新列表。")
        }
    }

    private func primaryAction(_ post: CommunityPost) async {
        if post.isCheckin {
            let challengeId = post.challengeId?.isEmpty == false ? post.challengeId : post.payload?.activeChallenges?.first?.id
            guard let challengeId, !challengeId.isEmpty else {
                status = "这条打卡没有挑战，先给对方点个赞吧。"
                return
            }
            do {
                let updated = try await APIClient.shared.joinChallenge(id: challengeId)
                challenges = challenges.map { $0.id == updated.id ? updated : $0 }
                status = "已加入同一个挑战。"
            } catch {
                status = friendlyCommunityError(error, fallback: "这次还没加入挑战，检查网络后再点加入。")
            }
        } else {
            do {
                let result = try await APIClient.shared.logSameCommunityMeal(id: post.id)
                status = "已把同款记录到今天\(result.saved.map { " · \($0) 项" } ?? "")"
            } catch {
                status = friendlyCommunityError(error, fallback: "群组操作暂时没成功，检查网络后再试。")
            }
        }
    }

    private func friendlyCommunityError(_ error: Error, fallback: String) -> String {
        let raw = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = raw.lowercased()
        if isConnectionFailureMessage(raw) {
            return "现在没连上，今天打卡还没更新；检查网络后下拉刷新。"
        }
        if raw.contains("Not Found") || raw.contains("404") {
            return "今天打卡暂时没更新，下拉刷新列表。"
        }
        if raw.hasPrefix("{")
            || raw.hasPrefix("[")
            || raw.count > 140
            || lowercased.contains("http")
            || lowercased.contains("json")
            || lowercased.contains("traceback")
            || lowercased.contains("internal server")
            || lowercased.contains("endpoint")
            || lowercased.contains("api")
            || lowercased.contains("failed")
            || lowercased.contains("error")
            || lowercased.contains("exception")
            || raw.contains("失败")
            || raw.contains("错误")
            || raw.contains("异常")
            || raw.contains("无法") {
            return fallback
        }
        return raw.isEmpty ? fallback : raw
    }
}

private struct CommunityPostCard: View {
    let post: CommunityPost
    @Binding var draft: String
    let onReact: () -> Void
    let onComment: () -> Void
    let onBookmark: () -> Void
    let onReport: () -> Void
    let onPrimary: () -> Void

    private var liked: Bool { post.activeReactions.contains("like") }
    private var displayTags: [String] {
        post.tags.filter { tag in
            !["red", "green", "yellow"].contains(tag.lowercased())
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                HStack(spacing: 12) {
                    Text(post.avatarInitial?.isEmpty == false ? post.avatarInitial ?? "?" : String(post.authorName.prefix(1)))
                        .font(.system(size: 14, weight: .black))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(Color.black)
                        .clipShape(Circle())
                    VStack(alignment: .leading, spacing: 3) {
                        Text(post.authorName)
                            .font(.system(size: 14, weight: .black))
                Text("\(formatPostTime(post.createdAt)) · \(post.isCheckin ? "今天状态卡" : post.visibility == "public" ? "可参考菜品" : "好友可见")")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button(action: onReport) {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 34, height: 34)
                }
                .accessibilityLabel("更多")
            }

            if !post.isCheckin, let url = APIClient.shared.assetURL(post.imageUrl), !post.imageUrlText.isEmpty {
                LocalMealImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        Color(hex: "F3F4F6")
                    }
                }
                .frame(maxWidth: .infinity)
                .aspectRatio(4 / 3, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(post.title)
                        .font(.system(size: 19, weight: .black))
                        .lineLimit(2)
                    if let body = post.body, !body.isEmpty {
                        Text(body)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color(hex: "6B7280"))
                            .lineSpacing(2)
                    }
                }
                Spacer()
                VStack(spacing: 3) {
                    Text(post.isCheckin ? "\(Int(round(post.statusScore ?? post.payload?.score ?? 0)))" : "\(Int(round(post.calories)))")
                        .font(.system(size: 18, weight: .black))
                    Text(post.isCheckin ? "状态分" : "千卡")
                        .font(.system(size: 10, weight: .bold))
                        .opacity(0.75)
                }
                .foregroundStyle(.white)
                .frame(minWidth: 58)
                .padding(.vertical, 10)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }

            HStack {
                Text((post.healthLabel?.isEmpty == false ? post.healthLabel : nil) ?? calorieBand(post.calories))
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(Color(hex: "111318"))
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background(Color(hex: "F2F4F7"))
                    .clipShape(Capsule())
                ForEach(displayTags.prefix(4), id: \.self) { tag in
                    Text(tag)
                        .font(.system(size: 11, weight: .black))
                        .foregroundStyle(Color(hex: "6B7280"))
                        .padding(.horizontal, 10)
                        .frame(height: 26)
                        .background(.white)
                        .clipShape(Capsule())
                }
            }

            insightBox
            comments
            actions
            commentComposer
        }
        .padding(16)
        .softCard(radius: 24)
    }

    @ViewBuilder
    private var insightBox: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: post.isCheckin ? "trophy" : "sparkles")
                    .accessibilityHidden(true)
                Text(post.isCheckin ? "下一步建议" : "这餐怎么吃更稳")
            }
            .font(.system(size: 12, weight: .black))
            Text((post.aiNote?.isEmpty == false ? post.aiNote : nil) ?? "继续保持记录，下一次可以微调份量和搭配。")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineSpacing(2)
            HStack(spacing: 8) {
                if post.isCheckin {
                    ForEach((post.payload?.dimensions ?? []).prefix(3)) { item in
                        SmallCommunityMetric(label: item.label, value: "\(Int(round(item.score)))分")
                    }
                } else {
                    SmallCommunityMetric(label: "蛋白", value: "\(Int(round(post.protein)))克")
                    SmallCommunityMetric(label: "热量段", value: calorieBand(post.calories))
                    SmallCommunityMetric(label: "菜品数", value: "\(max(post.foods.count, 1))")
                }
            }
        }
        .padding(14)
        .background(Color(hex: "F7F8FA"))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    @ViewBuilder
    private var comments: some View {
        if !post.recentComments.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(post.recentComments) { comment in
                    Text("\(comment.user == "me" ? "我" : comment.user)：\(comment.body)")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color(hex: "4B5563"))
                }
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            actionButton(icon: "heart", filledIcon: "heart.fill", active: liked, label: "\(post.reactions["like"] ?? 0)", spokenLabel: "点赞 \(post.reactions["like"] ?? 0)", color: Color(hex: "DC2626"), action: onReact)
            actionButton(icon: "message", filledIcon: "message.fill", active: false, label: "\(post.commentsCount)", spokenLabel: "评论 \(post.commentsCount)", color: Color.black, action: {})
            actionButton(icon: "bookmark", filledIcon: "bookmark.fill", active: post.bookmarked, label: post.bookmarksCount > 0 ? "\(post.bookmarksCount)" : "收藏", spokenLabel: post.bookmarked ? "取消收藏" : "收藏", color: Color(hex: "111318"), action: onBookmark)
            Spacer()
            Button(action: onPrimary) {
                Text(post.isCheckin ? "加入群组" : "扫描食物")
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .frame(height: 38)
                    .background(Color.black)
                    .clipShape(Capsule())
            }
        }
    }

    private var commentComposer: some View {
        HStack(spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "bubble.left.fill")
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(Color(hex: "A2A8B3"))
                    .accessibilityHidden(true)
                TextField("评论一句", text: $draft)
                    .font(.system(size: 12, weight: .bold))
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
            .background(Color(hex: "F7F8FA"))
            .clipShape(Capsule())
            Button(action: onComment) {
                HStack(spacing: 5) {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 11, weight: .black))
                        .accessibilityHidden(true)
                    Text("发送")
                        .font(.system(size: 12, weight: .black))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 13)
                .frame(height: 40)
                .background(Color.black)
                .clipShape(Capsule())
            }
        }
    }

    private func actionButton(icon: String, filledIcon: String, active: Bool, label: String, spokenLabel: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: active ? filledIcon : icon)
                    .accessibilityHidden(true)
                Text(label)
            }
            .font(.system(size: 12, weight: .black))
            .foregroundStyle(active ? color : Color(hex: "6B7280"))
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(active ? color.opacity(0.1) : .white)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(active ? color.opacity(0.18) : Color(hex: "F0F0F3"), lineWidth: 1))
        }
        .accessibilityLabel(spokenLabel)
    }
}

private struct SmallCommunityMetric: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .black))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .font(.system(size: 14, weight: .black))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(hex: "F7F8FA"))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct FlowChips: View {
    let items: [String]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(items, id: \.self) { item in
                Text(item)
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(Color(hex: "6B7280"))
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(.white)
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(Color(hex: "F0F0F3"), lineWidth: 1))
            }
        }
    }
}

private func calorieBand(_ calories: Double) -> String {
    if calories <= 0 { return "待估算" }
    if calories < 350 { return "低热量" }
    if calories < 650 { return "中等热量" }
    return "热量偏高"
}

private func formatPostTime(_ value: String) -> String {
    guard !value.isEmpty else { return "刚刚" }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.timeZone = .current
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    if let date = formatter.date(from: value) {
        let minutes = max(0, Int(Date().timeIntervalSince(date) / 60))
        if minutes < 1 { return "刚刚" }
        if minutes < 60 { return "\(minutes) 分钟前" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours) 小时前" }
        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "zh_CN")
        dayFormatter.dateFormat = "M月d日"
        return dayFormatter.string(from: date)
    }
    return String(value.prefix(16))
}

private extension CommunityPost {
    var imageUrlText: String {
        imageUrl?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

struct DiscoverPageView: View {
    let onScanFood: (() -> Void)?

    @State private var selectedTab: DiscoverTab = .friends
    @State private var friends: [Friend] = []
    @State private var friendsPosts: [CommunityPost] = []
    @State private var plazaPosts: [CommunityPost] = []
    @State private var recommendations: [MealRecommendation] = []
    @State private var ownFoods: [FoodLogRow] = []
    @State private var loading = false
    @State private var status = ""
    @State private var showInvite = false
    @State private var inviteName = ""
    @State private var recipeBusyID: String?

    private let visibleTabs: [DiscoverTab] = [.friends, .recipes]

    init(onScanFood: (() -> Void)? = nil) {
        self.onScanFood = onScanFood
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    tabBar
                    tabContent
                }
                .padding(.horizontal, 18)
                .padding(.top, 16)
                .padding(.bottom, 112)
            }
            .background(AppShellBackground())
            .toolbar(.hidden, for: .navigationBar)
            .task { await loadAll() }
            .refreshable { await loadAll() }
            .alert("邀请好友", isPresented: $showInvite) {
                TextField("输入好友昵称", text: $inviteName)
                Button("取消", role: .cancel) { inviteName = "" }
                Button("发送邀请") {
                    Task { await sendInvite() }
                }
                .disabled(inviteName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } message: {
                Text("邀请发出后，对方同意才会出现在好友动态。")
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("发现")
                .font(.system(size: 29, weight: .black))
                .foregroundStyle(Color(hex: "111318"))
            Text("和大家一起，记录饮食，发现健康生活")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Color(hex: "66758A"))
        }
    }

    private func discoverHeaderButton(_ icon: String, badge: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: icon)
                    .font(.system(size: 21, weight: .medium))
                    .foregroundStyle(Color(hex: "111318"))
                    .frame(width: 34, height: 34)
                if let badge {
                    Text(badge)
                        .font(.system(size: 8, weight: .black))
                        .foregroundStyle(.white)
                        .frame(width: 14, height: 14)
                        .background(Color(hex: "FF3B30"))
                        .clipShape(Circle())
                        .offset(x: 3, y: -2)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(visibleTabs) { tab in
                Button {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                        selectedTab = tab
                    }
                } label: {
                    VStack(spacing: 8) {
                        Text(tab.title)
                            .font(.system(size: 15, weight: .black))
                            .foregroundStyle(selectedTab == tab ? Color(hex: "05A34B") : Color(hex: "46546A"))
                            .lineLimit(1)
                            .minimumScaleFactor(0.78)
                        Capsule()
                            .fill(selectedTab == tab ? Color(hex: "05A34B") : Color.clear)
                            .frame(width: 26, height: 3)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 42)
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .friends:
            friendsContent
        case .plaza:
            plazaContent
        case .recipes:
            recipesContent
        }
    }

    private var friendsContent: some View {
        VStack(alignment: .leading, spacing: 15) {
            if friends.isEmpty {
                inviteCard
                sectionHeader("我的打卡历史")
                ownHistoryContent
            } else {
                DiscoverCheckinCard(onScanFood: onScanFood)
                sectionHeader("好友动态")
                if friendDisplayPosts.isEmpty {
                    discoverEmptyState("好友今天还没打卡", "先看看自己的记录，或拍一餐发起今天的打卡。", "person.2")
                    ownHistoryContent
                } else {
                    ForEach(friendDisplayPosts.prefix(3), id: \.id) { post in
                        DiscoverFriendPostCard(post: post)
                    }
                }
            }
            if !status.isEmpty {
                Text(status)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color(hex: "66758A"))
            }
        }
    }

    private var inviteCard: some View {
        Button { showInvite = true } label: {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(LinearGradient(colors: [Color(hex: "E8F9E7"), Color(hex: "F5FBED")], startPoint: .topLeading, endPoint: .bottomTrailing))
                HStack(spacing: -8) {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.system(size: 46, weight: .bold))
                        .foregroundStyle(Color(hex: "22C55E"))
                    Image(systemName: "person.crop.circle.fill")
                        .font(.system(size: 42, weight: .bold))
                        .foregroundStyle(Color(hex: "FFB34D"))
                }
            }
            .frame(width: 118, height: 92)

            VStack(alignment: .leading, spacing: 7) {
                Text("邀请好友一起打卡")
                    .font(.system(size: 18, weight: .black))
                    .foregroundStyle(Color(hex: "111318"))
                Text("互看饮食记录，互相鼓励，一起养成好习惯")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color(hex: "66758A"))
                    .lineLimit(2)
                Text("邀请好友 〉")
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(Color(hex: "05A34B"))
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .background(.white.opacity(0.75))
                    .clipShape(Capsule())
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(LinearGradient(colors: [Color(hex: "F1FBED"), Color(hex: "FBF7EA")], startPoint: .leading, endPoint: .trailing))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var plazaContent: some View {
        VStack(alignment: .leading, spacing: 15) {
            sectionHeader("热门饮食动态")
            if plazaDisplayPosts.isEmpty {
                discoverEmptyState("还没有公开动态", "公开发布功能完善后会在这里开放。", "person.3.fill")
            } else {
                ForEach(plazaDisplayPosts.prefix(3), id: \.id) { post in
                    DiscoverPlazaPostCard(post: post)
                }
            }
        }
    }

    private var recipesContent: some View {
        VStack(alignment: .leading, spacing: 15) {
            sectionHeader("为你推荐")
            if recipeItems.isEmpty {
                discoverEmptyState("还没有个性化菜谱", "先记录一餐，我们再根据真实饮食推荐。", "fork.knife")
            } else {
                ForEach(recipeItems.prefix(4)) { item in
                    DiscoverRecipeCard(
                        item: item,
                        busy: recipeBusyID == item.id,
                        onAddToNextMeal: { Task { await addToNextMeal(item) } },
                        onLogNow: { Task { await logRecommendation(item) } }
                    )
                }
                if !status.isEmpty {
                    Text(status)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color(hex: "66758A"))
                }
            }
        }
    }

    @ViewBuilder
    private var ownHistoryContent: some View {
        let groups = Array(MealHistoryGroup.makeGroups(from: ownFoods).prefix(3))
        if groups.isEmpty {
            discoverEmptyState("你还没有打卡记录", "拍下第一餐后，这里会保留自己的打卡历史。", "camera.fill")
        } else {
            ForEach(groups) { group in
                HStack(spacing: 12) {
                    Image(systemName: "fork.knife.circle.fill")
                        .font(.system(size: 28, weight: .black))
                        .foregroundStyle(Color(hex: "20B85A"))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(group.title)
                            .font(.system(size: 16, weight: .black))
                            .foregroundStyle(Color(hex: "111318"))
                        Text("\(group.foods.first?.date ?? String((group.loggedAt ?? "").prefix(10))) · \(group.foods.count) 项")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Color(hex: "66758A"))
                    }
                    Spacer()
                    Text("\(Int(round(group.calories))) kcal")
                        .font(.system(size: 14, weight: .black))
                        .foregroundStyle(Color(hex: "05A34B"))
                }
                .padding(14)
                .background(.white.opacity(0.9))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 19, weight: .black))
                .foregroundStyle(Color(hex: "111318"))
            Spacer()
        }
    }

    private func discoverEmptyState(_ title: String, _ message: String, _ icon: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .black))
                .foregroundStyle(Color(hex: "05A34B"))
                .frame(width: 44, height: 44)
                .background(Color(hex: "EAFBEF"))
                .clipShape(Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 16, weight: .black))
                    .foregroundStyle(Color(hex: "111318"))
                Text(message)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color(hex: "66758A"))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(15)
        .background(.white.opacity(0.9))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color(hex: "EEF0F3"), lineWidth: 1))
    }

    private func searchPill(_ placeholder: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Color(hex: "7A8799"))
            Text(placeholder)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color(hex: "8A96A8"))
            Spacer()
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(Color(hex: "F1F3F6"))
        .clipShape(Capsule())
    }

    private func categoryScroller(_ categories: [DiscoverCategory]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 17) {
                ForEach(categories) { category in
                    VStack(spacing: 8) {
                        Image(systemName: category.icon)
                            .font(.system(size: 15, weight: .black))
                            .foregroundStyle(category.color)
                            .frame(width: 38, height: 38)
                            .background(category.color.opacity(0.13))
                            .clipShape(Circle())
                        Text(category.title)
                            .font(.system(size: 13, weight: .black))
                            .foregroundStyle(Color(hex: "46546A"))
                    }
                    .frame(width: 48)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var topicStrip: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("热门话题")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(["# 减脂早餐打卡", "# 低卡便当分享", "# 高蛋白饮食"], id: \.self) { title in
                        HStack(spacing: 8) {
                            Image("RecommendationDish1")
                                .resizable()
                                .scaledToFill()
                                .frame(width: 34, height: 34)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(title)
                                    .font(.system(size: 13, weight: .black))
                                    .foregroundStyle(Color(hex: "111318"))
                                Text("1.2万次讨论")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(Color(hex: "8A96A8"))
                            }
                        }
                        .padding(.horizontal, 8)
                        .frame(height: 52)
                        .background(Color(hex: "FFF7E8"))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
            }
        }
    }

    private var plazaSwitch: some View {
        HStack {
            ForEach(["热门", "最新", "关注"], id: \.self) { item in
                Text(item)
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(item == "热门" ? Color(hex: "05A34B") : Color(hex: "66758A"))
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 34)
    }

    private var friendDisplayPosts: [CommunityPost] { friendsPosts }
    private var plazaDisplayPosts: [CommunityPost] { plazaPosts }

    private var recipeItems: [DiscoverRecipeItem] {
        if recommendations.isEmpty { return [] }
        return recommendations.enumerated().map { index, rec in
            DiscoverRecipeItem(
                id: rec.id,
                title: rec.title,
                calories: rec.calories,
                minutes: rec.prepTimeMinutes,
                tags: rec.protein >= 25 ? ["高蛋白", "低脂", "减脂"] : ["低脂", "快手", "营养"],
                imageName: "RecommendationDish\(index % 4 + 1)",
                reason: rec.reason,
                recommendation: rec
            )
        }
    }

    private let plazaCategories = [
        DiscoverCategory(title: "推荐", icon: "star.fill", color: Color(hex: "05A34B")),
        DiscoverCategory(title: "减脂", icon: "heart.fill", color: Color(hex: "FF6B76")),
        DiscoverCategory(title: "高蛋白", icon: "shield.fill", color: Color(hex: "3A8BFF")),
        DiscoverCategory(title: "便当", icon: "takeoutbag.and.cup.and.straw.fill", color: Color(hex: "FF7A45")),
        DiscoverCategory(title: "低卡", icon: "gift.fill", color: Color(hex: "8B5CF6")),
        DiscoverCategory(title: "更多", icon: "ellipsis", color: Color(hex: "8A96A8"))
    ]

    private let recipeCategories = [
        DiscoverCategory(title: "减脂餐", icon: "star.fill", color: Color(hex: "05A34B")),
        DiscoverCategory(title: "高蛋白", icon: "drop.fill", color: Color(hex: "FF9F1C")),
        DiscoverCategory(title: "家常菜", icon: "house.fill", color: Color(hex: "22C55E")),
        DiscoverCategory(title: "素食", icon: "leaf.fill", color: Color(hex: "38B26D")),
        DiscoverCategory(title: "快手菜", icon: "flame.fill", color: Color(hex: "FF6B3D")),
        DiscoverCategory(title: "低卡甜点", icon: "gift.fill", color: Color(hex: "8B5CF6"))
    ]

    @MainActor
    private func loadAll() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        async let friendFeed = APIClient.shared.getCommunityFeed(tab: "friends", user: "me", limit: 12)
        async let recTask = APIClient.shared.getTodayRecommendations(mealType: "dinner", prepTimeMinutes: 20, limit: 4, useAI: false)
        async let friendsTask = APIClient.shared.getFriends(user: "me")
        async let ownFoodTask = APIClient.shared.getFoods(days: 30)
        if let feed = try? await friendFeed {
            friendsPosts = feed.posts
        }
        if let recs = try? await recTask {
            recommendations = recs.recommendations
        }
        if let loadedFriends = try? await friendsTask {
            friends = loadedFriends
        }
        if let loadedFoods = try? await ownFoodTask {
            ownFoods = loadedFoods
        }
    }

    @MainActor
    private func sendInvite() async {
        let name = inviteName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        do {
            try await APIClient.shared.sendFriendRequest(toUser: name)
            status = "已向 \(name) 发送好友邀请。"
            inviteName = ""
        } catch {
            status = discoverError(error, fallback: "邀请暂时没发出去，请稍后重试。")
        }
    }

    private func recommendationFoods(_ item: DiscoverRecipeItem) -> [FoodItem] {
        let foods = item.recommendation.foods.map {
            FoodItem(
                id: $0.id,
                name: $0.name,
                calories: $0.calories,
                protein: $0.protein,
                carbs: $0.carbs,
                fat: $0.fat,
                fiber: $0.fiber ?? 0,
                sugar: $0.sugar ?? 0,
                sodium: $0.sodium ?? 0,
                servingSize: $0.servingSize,
                processingLevel: $0.processingLevel ?? "whole"
            )
        }
        if !foods.isEmpty { return foods }
        return [FoodItem(name: item.title, calories: item.recommendation.calories, protein: item.recommendation.protein, carbs: item.recommendation.carbs, fat: item.recommendation.fat, servingSize: item.recommendation.servingSize)]
    }

    @MainActor
    private func addToNextMeal(_ item: DiscoverRecipeItem) async {
        guard recipeBusyID == nil else { return }
        recipeBusyID = item.id
        defer { recipeBusyID = nil }
        do {
            _ = try await APIClient.shared.saveMealTemplate(
                title: item.title,
                foods: recommendationFoods(item),
                mealCategory: item.recommendation.mealType,
                note: "来自个性化推荐"
            )
            status = "已把“\(item.title)”加入下一餐。"
        } catch {
            status = discoverError(error, fallback: "下一餐暂时没保存上，请稍后重试。")
        }
    }

    @MainActor
    private func logRecommendation(_ item: DiscoverRecipeItem) async {
        guard recipeBusyID == nil else { return }
        recipeBusyID = item.id
        defer { recipeBusyID = nil }
        do {
            let response = try await APIClient.shared.logRecommendation(
                id: item.id,
                portionMultiplier: item.recommendation.portionMultiplier ?? 1,
                mealCategory: item.recommendation.mealType
            )
            status = response.alreadyLogged == true
                ? "这餐已经记录过了。"
                : "已记录“\(item.title)”。"
            ownFoods = (try? await APIClient.shared.getFoods(days: 30)) ?? ownFoods
        } catch {
            status = discoverError(error, fallback: "这餐暂时没记上，请稍后重试。")
        }
    }

    private func discoverError(_ error: Error, fallback: String) -> String {
        if let urlError = error as? URLError, urlError.code == .notConnectedToInternet {
            return "当前网络不可用，连接后再试一次。"
        }
        return fallback
    }
}

private enum DiscoverTab: String, CaseIterable, Identifiable {
    case friends, plaza, recipes
    var id: String { rawValue }
    var title: String {
        switch self {
        case .friends: return "好友动态"
        case .plaza: return "饮食广场"
        case .recipes: return "菜谱灵感"
        }
    }
}

private struct DiscoverCategory: Identifiable {
    let id = UUID().uuidString
    let title: String
    let icon: String
    let color: Color
}

private struct DiscoverRecipeItem: Identifiable {
    let id: String
    let title: String
    let calories: Double
    let minutes: Int
    let tags: [String]
    let imageName: String
    let reason: String
    let recommendation: MealRecommendation
}

private struct DiscoverCheckinCard: View {
    let onScanFood: (() -> Void)?

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 16) {
                ZStack {
                    Circle()
                        .trim(from: 0.06, to: 0.92)
                        .stroke(Color(hex: "EEF0F3"), style: StrokeStyle(lineWidth: 9, lineCap: .round))
                        .rotationEffect(.degrees(115))
                    Circle()
                        .trim(from: 0.06, to: 0.74)
                        .stroke(
                            AngularGradient(colors: [Color(hex: "1A8DFF"), Color(hex: "31C4D7"), Color(hex: "6DD14D")], center: .center),
                            style: StrokeStyle(lineWidth: 9, lineCap: .round)
                        )
                        .rotationEffect(.degrees(115))
                    VStack(spacing: 3) {
                        Image(systemName: "doc.text.image.fill")
                            .font(.system(size: 23, weight: .black))
                            .foregroundStyle(Color(hex: "72D3A2"))
                        Text("待生成")
                            .font(.system(size: 16, weight: .black))
                        Text("今日状态卡")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Color(hex: "66758A"))
                    }
                }
                .frame(width: 132, height: 132)

                VStack(alignment: .leading, spacing: 9) {
                    HStack(spacing: 6) {
                        Image(systemName: "calendar.badge.checkmark")
                        Text("今日打卡")
                    }
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(Color(hex: "05A34B"))
                    Text("还未记录饮食")
                        .font(.system(size: 19, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                    Text("拍一餐生成今日状态卡")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Color(hex: "66758A"))
                    HStack(spacing: 10) {
                        mini("连续打卡", "0 天")
                        mini("今日状态", "未打卡")
                    }
                }
            }
            Button(action: { onScanFood?() }) {
                HStack(spacing: 8) {
                    Image(systemName: "camera.fill")
                    Text("拍照打卡")
                }
                .font(.system(size: 16, weight: .black))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(Color(hex: "05A34B"))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .background(.white.opacity(0.88))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: Color(hex: "8BA7C2").opacity(0.11), radius: 18, x: 0, y: 10)
    }

    private func mini(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color(hex: "8A96A8"))
            Text(value)
                .font(.system(size: 14, weight: .black))
                .foregroundStyle(Color(hex: "111318"))
        }
        .padding(.horizontal, 10)
        .frame(height: 50)
        .background(Color(hex: "F4F6F8"))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct DiscoverFriendPostCard: View {
    let post: CommunityPost

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(post.avatarInitial?.isEmpty == false ? post.avatarInitial ?? "食" : String(post.authorName.prefix(1)))
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(Color(hex: "111318"))
                    .clipShape(Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(post.authorName)
                        .font(.system(size: 14, weight: .black))
                    Text(formatPostTime(post.createdAt))
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color(hex: "8A96A8"))
                }
                Spacer()
                Image(systemName: "ellipsis")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Color(hex: "66758A"))
            }
            HStack(spacing: 12) {
                mealImage(post: post, fallback: "RecommendationDish1")
                    .frame(width: 132, height: 88)
                    .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                VStack(alignment: .leading, spacing: 8) {
                    Text(post.title)
                        .font(.system(size: 16, weight: .black))
                        .lineLimit(2)
                    Text(post.body?.isEmpty == false ? post.body ?? "" : "今天也认真记录饮食。")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Color(hex: "66758A"))
                        .lineLimit(2)
                    Text("约 \(Int(round(post.calories))) kcal")
                        .font(.system(size: 13, weight: .black))
                        .foregroundStyle(Color(hex: "05A34B"))
                }
            }
            HStack(spacing: 18) {
                labelIcon("hand.thumbsup.fill", "\(post.reactions["like"] ?? 0)")
                labelIcon("bubble.left", "\(post.commentsCount)")
                Spacer()
                Text("打招呼")
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(Color(hex: "66758A"))
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .background(Color(hex: "F3F7FC"))
                    .clipShape(Capsule())
            }
        }
        .padding(13)
        .background(.white.opacity(0.88))
        .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
        .shadow(color: Color(hex: "8BA7C2").opacity(0.09), radius: 14, x: 0, y: 8)
    }
}

private struct DiscoverPlazaPostCard: View {
    let post: CommunityPost

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(post.avatarInitial?.isEmpty == false ? post.avatarInitial ?? "食" : String(post.authorName.prefix(1)))
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(Color(hex: "111318"))
                    .clipShape(Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(post.authorName)
                        .font(.system(size: 14, weight: .black))
                    Text(formatPostTime(post.createdAt))
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color(hex: "8A96A8"))
                }
                Spacer()
                Image(systemName: "ellipsis")
                    .foregroundStyle(Color(hex: "66758A"))
            }
            Text(post.body?.isEmpty == false ? post.body ?? post.title : post.title)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Color(hex: "2F3B4A"))
                .lineLimit(3)
            HStack(spacing: 8) {
                mealImage(post: post, fallback: "RecommendationDish1")
                mealImage(post: post, fallback: "RecommendationDish2")
                mealImage(post: post, fallback: "RecommendationDish4")
            }
            .frame(height: 92)
            HStack(spacing: 22) {
                labelIcon("hand.thumbsup.fill", "\(post.reactions["like"] ?? 0)")
                labelIcon("bubble.left", "\(post.commentsCount)")
                labelIcon("star.fill", "收藏")
            }
        }
        .padding(13)
        .background(.white.opacity(0.88))
        .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
        .shadow(color: Color(hex: "8BA7C2").opacity(0.09), radius: 14, x: 0, y: 8)
    }
}

private struct DiscoverRecipeCard: View {
    let item: DiscoverRecipeItem
    let busy: Bool
    let onAddToNextMeal: () -> Void
    let onLogNow: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
        HStack(spacing: 14) {
            Image(item.imageName)
                .resizable()
                .scaledToFill()
                .frame(width: 92, height: 92)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(item.title)
                        .font(.system(size: 18, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: "star")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Color(hex: "66758A"))
                }
                HStack(spacing: 6) {
                    ForEach(item.tags.prefix(3), id: \.self) { tag in
                        Text(tag)
                            .font(.system(size: 11, weight: .black))
                            .foregroundStyle(Color(hex: "05A34B"))
                            .padding(.horizontal, 7)
                            .frame(height: 22)
                            .background(Color(hex: "EAFBEF"))
                            .clipShape(Capsule())
                    }
                }
                HStack(spacing: 18) {
                    Text("约 \(Int(round(item.calories))) kcal")
                    Label("\(item.minutes) 分钟", systemImage: "clock")
                }
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color(hex: "66758A"))
            }
        }
        HStack(spacing: 7) {
            Image(systemName: "sparkles")
            Text("为什么推荐：\(item.reason.isEmpty ? item.tags.first ?? "符合你的饮食目标" : item.reason)")
                .lineLimit(2)
        }
        .font(.system(size: 13, weight: .bold))
        .foregroundStyle(Color(hex: "557064"))
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(hex: "EFFAF2"))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

        HStack(spacing: 10) {
            Button(action: onAddToNextMeal) {
                Label("加入下一餐", systemImage: "calendar.badge.plus")
                    .frame(maxWidth: .infinity)
                    .frame(height: 38)
            }
            .buttonStyle(.bordered)
            Button(action: onLogNow) {
                Label("记录这餐", systemImage: "plus.circle.fill")
                    .frame(maxWidth: .infinity)
                    .frame(height: 38)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color(hex: "05A34B"))
        }
        .font(.system(size: 14, weight: .black))
        .disabled(busy)
        }
        .padding(12)
        .background(.white.opacity(0.88))
        .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
        .shadow(color: Color(hex: "8BA7C2").opacity(0.09), radius: 14, x: 0, y: 8)
    }
}

private func labelIcon(_ icon: String, _ text: String) -> some View {
    HStack(spacing: 6) {
        Image(systemName: icon)
        Text(text)
    }
    .font(.system(size: 13, weight: .bold))
    .foregroundStyle(Color(hex: "66758A"))
}

private func mealImage(post: CommunityPost, fallback: String) -> some View {
    Group {
        if let url = APIClient.shared.assetURL(post.imageUrl), !post.imageUrlText.isEmpty {
            LocalMealImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                default:
                    Image(fallback).resizable().scaledToFill()
                }
            }
        } else {
            Image(fallback).resizable().scaledToFill()
        }
    }
    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
}
