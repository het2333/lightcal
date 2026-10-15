import SwiftUI

struct BadgesPageView: View {
    let summary: DailySummary?
    let streak: Int
    let onScanFood: () -> Void
    let onClose: () -> Void

    @State private var challenges: [Challenge] = []
    @State private var loading = true
    @State private var busyChallengeId = ""
    @State private var errorMessage: String?
    @State private var showCreateChallenge = false
    @State private var hasSavedScan = false

    private let badges: [(id: String, name: String, desc: String, icon: String)] = [
        ("first_log", "初次记录", "记录第一餐", "fork.knife"),
        ("scan_saved", "扫描保存", "保存一次扫描结果", "camera.viewfinder"),
        ("calorie_hit", "热量达标", "热量接近目标", "target"),
        ("protein_master", "蛋白质达人", "蛋白质超过 80g", "figure.strengthtraining.traditional"),
        ("water_king", "饮水之王", "喝满目标饮水", "drop.fill"),
        ("streak_3", "连续3天", "连续记录3天", "flame.fill"),
        ("streak_7", "坚持一周", "连续记录7天", "trophy.fill"),
        ("exercise_1", "动起来", "记录一次运动", "figure.run"),
        ("perfect_day", "完美一天", "营养、饮水、运动都完成", "star.fill"),
    ]

    private var unlockedBadgeIds: Set<String> {
        var ids = Set<String>()
        let summary = summary
        if (summary?.mealsCount ?? 0) > 0 { ids.insert("first_log") }
        if hasSavedScan { ids.insert("scan_saved") }
        if let summary, summary.caloriesConsumed > 0, abs(summary.caloriesConsumed - summary.caloriesGoal) <= summary.caloriesGoal * 0.1 {
            ids.insert("calorie_hit")
        }
        if (summary?.protein ?? 0) >= 80 { ids.insert("protein_master") }
        if (summary?.waterMl ?? 0) >= (summary?.waterGoalMl ?? 2000) { ids.insert("water_king") }
        if streak >= 3 { ids.insert("streak_3") }
        if streak >= 7 { ids.insert("streak_7") }
        return ids
    }

    private var unlockedCount: Int {
        unlockedBadgeIds.count
    }

    private var activeChallenges: [Challenge] {
        challenges.filter { $0.status == "active" }
    }

    private var completedChallenges: [Challenge] {
        challenges.filter { $0.status == "completed" || ($0.progress?.completed ?? false) }
    }

    private var challengeStreak: Int {
        activeChallenges.map { $0.progress?.currentStreak ?? 0 }.max() ?? streak
    }

    private var earnedPoints: Int {
        completedChallenges.reduce(0) { $0 + $1.rewardPoints }
    }

    private var achievementProgress: Double {
        let badgePart = Double(unlockedCount) / Double(max(badges.count, 1))
        let challengePart = min(Double(completedChallenges.count) / Double(max(challenges.count, 1)), 1)
        return min(1, badgePart * 0.72 + challengePart * 0.28)
    }

    private var nextBadge: (id: String, name: String, desc: String, icon: String)? {
        badges.first { !unlockedBadgeIds.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    heroSection
                    nextStepSection
                    badgeSection
                    challengeSection
                }
                .padding(.horizontal, 18)
                .padding(.top, 14)
                .padding(.bottom, 34)
            }
            .background(AppShellBackground())
            .navigationTitle("今日打卡目标")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: onClose) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 16, weight: .black))
                            .foregroundStyle(Color(hex: "111318"))
                            .frame(width: 38, height: 38)
                            .background(.white)
                            .clipShape(Circle())
                            .overlay(Circle().stroke(Color(hex: "F0F0F3"), lineWidth: 1))
                    }
                    .accessibilityLabel("返回")
                }
            }
            .task { await loadPageData() }
            .refreshable { await loadPageData() }
            .sheet(isPresented: $showCreateChallenge) {
                CreateChallengeSheetView(
                    onClose: { showCreateChallenge = false },
                    onCreated: { challenge in
                        upsert(challenge)
                        showCreateChallenge = false
                    }
                )
            }
        }
    }

    private var nextStepSection: some View {
        let badge = nextBadge
        return HStack(alignment: .center, spacing: 12) {
            Image(systemName: badge?.icon ?? "checkmark.seal.fill")
                .font(.system(size: 18, weight: .black))
                .foregroundStyle(Color(hex: "111318"))
                .frame(width: 44, height: 44)
                .background(Color(hex: "F1FBF5"))
                .clipShape(Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(nextStepTitle(for: badge?.id))
                    .font(.system(size: 16, weight: .black))
                    .foregroundStyle(Color(hex: "111318"))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(nextStepSubtitle(for: badge))
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color(hex: "7B828C"))
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Button {
                handleNextStep(for: badge?.id)
            } label: {
                Text(nextStepButtonTitle(for: badge?.id))
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 13)
                    .frame(height: 36)
                    .background(Color(hex: "111318"))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .background(.white.opacity(0.92))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color(hex: "EEF0F3"), lineWidth: 1))
    }

    private func nextStepTitle(for badgeId: String?) -> String {
        switch badgeId {
        case "first_log":
            return "先完成第一餐记录"
        case "scan_saved":
            return "拍一餐就能点亮徽章"
        case "calorie_hit":
            return "今天热量接近目标就能拿"
        case "protein_master":
            return "下一餐补蛋白更容易拿"
        case "water_king":
            return "今天把水喝够"
        case "streak_3", "streak_7":
            return "继续保持连续记录"
        case "exercise_1":
            return "补一次运动记录"
        case "perfect_day":
            return "今天补齐饮食、饮水、运动"
        default:
            return "今天已经很稳了"
        }
    }

    private func nextStepSubtitle(for badge: (id: String, name: String, desc: String, icon: String)?) -> String {
        guard let badge else { return "徽章已全部点亮，继续保持今天的记录节奏。" }
        return "下一个：\(badge.name)。\(badge.desc)，达成后这里会自动更新。"
    }

    private func nextStepButtonTitle(for badgeId: String?) -> String {
        switch badgeId {
        case "first_log", "scan_saved":
            return "拍一餐"
        case nil:
            return "刷新"
        default:
            return "刷新进度"
        }
    }

    private func handleNextStep(for badgeId: String?) {
        switch badgeId {
        case "first_log", "scan_saved":
            onClose()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                onScanFood()
            }
        default:
            Task { await loadPageData() }
        }
    }

    private func loadPageData() async {
        async let challengeTask: Void = loadChallenges()
        async let scanTask: Void = loadScanBadgeState()
        _ = await (challengeTask, scanTask)
    }

    private func loadScanBadgeState() async {
        let rows = (try? await APIClient.shared.getFoods(days: 365)) ?? []
        hasSavedScan = rows.contains { row in
            let image = row.imageUrl?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return !image.isEmpty
        }
    }

    private var heroSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    Circle()
                        .stroke(Color.white.opacity(0.16), lineWidth: 12)
                    Circle()
                        .trim(from: 0, to: achievementProgress)
                        .stroke(Color(hex: "73D39B"), style: StrokeStyle(lineWidth: 12, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    VStack(spacing: 0) {
                        Text("\(unlockedCount)")
                            .font(.system(size: 34, weight: .black))
                            .foregroundStyle(.white)
                        Text("枚徽章")
                            .font(.system(size: 11, weight: .black))
                            .foregroundStyle(.white.opacity(0.70))
                    }
                }
                .frame(width: 104, height: 104)

                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 13, weight: .black))
                            .foregroundStyle(Color(hex: "73D39B"))
                            .accessibilityHidden(true)
                        Text("连续打卡")
                            .font(.system(size: 13, weight: .black))
                            .foregroundStyle(.white.opacity(0.74))
                    }
                    Text("\(max(streak, challengeStreak)) 天")
                        .font(.system(size: 38, weight: .black))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(heroSubtitle)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white.opacity(0.68))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 10) {
                heroMetric(title: "进行中", value: "\(activeChallenges.count)", icon: "timer")
                heroMetric(title: "已完成", value: "\(completedChallenges.count)", icon: "checkmark.seal.fill")
                heroMetric(title: "奖励分", value: "\(earnedPoints)", icon: "star.fill")
            }
        }
        .padding(18)
        .background(
            ZStack {
                LinearGradient(colors: [Color(hex: "20252B"), Color(hex: "111318")], startPoint: .topLeading, endPoint: .bottomTrailing)
                LinearGradient(colors: [Color(hex: "73D39B").opacity(0.26), .clear], startPoint: .topTrailing, endPoint: .bottomLeading)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 30).stroke(Color.white.opacity(0.08), lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 24, x: 0, y: 14)
    }

    private var heroSubtitle: String {
        if activeChallenges.isEmpty {
            return "先选一个容易完成的小目标，今天只做一件事。"
        }
        let best = activeChallenges.max { ($0.progress?.percent ?? 0) < ($1.progress?.percent ?? 0) }
        if let best {
            return "\(best.title) 已完成 \(Int(best.progress?.percent ?? 0))%，继续保持节奏。"
        }
        return "今天记录越完整，徽章和挑战进度越快刷新。"
    }

    private func heroMetric(title: String, value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .black))
                .foregroundStyle(Color(hex: "73D39B"))
                .accessibilityHidden(true)
            Text(value)
                .font(.system(size: 22, weight: .black))
                .foregroundStyle(.white)
            Text(title)
                .font(.system(size: 11, weight: .black))
                .foregroundStyle(.white.opacity(0.58))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.white.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var badgeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("成就徽章")
                        .font(.system(size: 22, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                    Text("\(unlockedCount)/\(badges.count) 已解锁")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                ForEach(badges, id: \.id) { badge in
                    let unlocked = unlockedBadgeIds.contains(badge.id)
                    VStack(spacing: 8) {
                        Image(systemName: unlocked ? badge.icon : "lock.fill")
                            .font(.system(size: 23, weight: .black))
                            .foregroundStyle(unlocked ? Color(hex: "111318") : Color(hex: "B7BDC7"))
                            .frame(width: 48, height: 48)
                            .background(unlocked ? Color.white : Color(hex: "F1F2F4"))
                            .clipShape(Circle())
                            .overlay(Circle().stroke(unlocked ? Color(hex: "73D39B").opacity(0.42) : .clear, lineWidth: 2))
                        Text(badge.name)
                            .font(.system(size: 12, weight: .black))
                            .foregroundStyle(Color(hex: "111318"))
                            .lineLimit(1)
                        Text(unlocked ? badge.desc : "未解锁")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 128)
                    .background(
                        LinearGradient(
                            colors: unlocked ? [.white, Color(hex: "F1FBF5")] : [.white.opacity(0.72), Color(hex: "F7F8FA").opacity(0.72)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color(hex: "EEF0F3"), lineWidth: 1))
                }
            }
        }
    }

    private var challengeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("今天的小目标")
                        .font(.system(size: 22, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                    Text(activeChallenges.isEmpty ? "先选一个最容易完成的，别一次开太多。" : "今天先完成进行中的目标。")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button {
                    showCreateChallenge = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .black))
                            .accessibilityHidden(true)
                        Text("选目标")
                    }
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .frame(height: 34)
                    .background(Color(hex: "111318"))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("选择打卡目标")
                if loading {
                    ProgressView()
                        .tint(Color(hex: "111318"))
                }
            }

            if let errorMessage {
                challengeRecoveryCard(errorMessage)
            }

            if loading && challenges.isEmpty {
                challengeLoadingCard
            } else if !loading && challenges.isEmpty {
                emptyChallengeCard
            } else {
                ForEach(sortedChallenges) { challenge in
                    challengeCard(challenge)
                }
            }
        }
    }

    private var challengeLoadingCard: some View {
        HStack(alignment: .top, spacing: 12) {
            ProgressView()
                .tint(Color(hex: "111318"))
                .frame(width: 42, height: 42)
                .background(Color(hex: "F7F8FA"))
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 5) {
                Text("正在同步今天的小目标")
                    .font(.system(size: 16, weight: .black))
                    .foregroundStyle(Color(hex: "111318"))
                Text("同步好后，会直接告诉你今天先做哪一项。")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color(hex: "6D7480"))
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(.white.opacity(0.92))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color(hex: "EEF0F3"), lineWidth: 1))
    }

    private var emptyChallengeCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "flag.checkered")
                    .font(.system(size: 20, weight: .black))
                    .foregroundStyle(.white)
                    .frame(width: 46, height: 46)
                    .background(Color(hex: "111318"))
                    .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 5) {
                    Text("先选一个今天能完成的")
                        .font(.system(size: 17, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                    Text("推荐拍餐、饮水或轻断食，做一次就能看到进度。")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color(hex: "6D7480"))
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 10) {
                Button {
                    showCreateChallenge = true
                } label: {
                    actionLabel(title: "选目标", icon: "plus", filled: true, busy: false)
                }
                Button {
                    onClose()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                        onScanFood()
                    }
                } label: {
                    actionLabel(title: "先拍一餐", icon: "camera.fill", filled: false, busy: false)
                }
            }
        }
        .padding(16)
        .background(.white.opacity(0.92))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(Color(hex: "EEF0F3"), lineWidth: 1))
    }

    private func challengeRecoveryCard(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 18, weight: .black))
                .foregroundStyle(Color(hex: "E5484D"))
                .frame(width: 40, height: 40)
                .background(Color(hex: "FFF1F1"))
                .clipShape(Circle())
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                Text("小目标暂时没同步")
                    .font(.system(size: 15, weight: .black))
                    .foregroundStyle(Color(hex: "111318"))
                Text(message)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color(hex: "8B4A4A"))
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            Button {
                Task { await loadPageData() }
            } label: {
                Text("重新加载")
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .frame(height: 32)
                    .background(Color(hex: "111318"))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .background(Color(hex: "FFF8F8"))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var sortedChallenges: [Challenge] {
        challenges.sorted { left, right in
            statusRank(left.status) < statusRank(right.status)
        }
    }

    private func challengeCard(_ challenge: Challenge) -> some View {
        let progress = challenge.progress
        let percent = min(100, max(0, progress?.percent ?? 0))
        let active = challenge.status == "active"
        let completed = challenge.status == "completed" || (progress?.completed ?? false)

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle()
                        .fill(completed ? Color(hex: "111318") : challengeTint(challenge.status).opacity(0.12))
                    Image(systemName: challengeIcon(challenge.challengeType))
                        .font(.system(size: 18, weight: .black))
                        .foregroundStyle(completed ? .white : challengeTint(challenge.status))
                        .accessibilityHidden(true)
                }
                .frame(width: 44, height: 44)

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text(challenge.title)
                            .font(.system(size: 16, weight: .black))
                            .foregroundStyle(Color(hex: "111318"))
                            .lineLimit(1)
                        statusPill(challenge.status)
                    }
                    Text(challenge.description)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    HStack(spacing: 8) {
                        miniInfo("\(progress?.completedDays ?? 0)/\(progress?.durationDays ?? challenge.durationDays)天")
                        miniInfo("连续\(progress?.currentStreak ?? 0)天")
                        miniInfo("+\(challenge.rewardPoints)分")
                    }
                }
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color(hex: "EEF0F3"))
                    Capsule()
                        .fill(challengeTint(challenge.status))
                        .frame(width: proxy.size.width * percent / 100)
                }
            }
            .frame(height: 8)

            if let days = progress?.days, !days.isEmpty {
                HStack(spacing: 5) {
                    ForEach(days.prefix(14)) { day in
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(day.success ? Color(hex: "73D39B") : day.checked ? Color(hex: "111318") : Color(hex: "E6E8EC"))
                            .frame(height: 18)
                    }
                }
            }

            HStack(spacing: 10) {
                if active || completed {
                    Button {
                        Task { await refresh(challenge) }
                    } label: {
                        actionLabel(title: "刷新进度", icon: "arrow.clockwise", filled: false, busy: busyChallengeId == challenge.id)
                    }
                    .disabled(!busyChallengeId.isEmpty)
                }

                if challenge.status == "available" {
                    Button {
                        Task { await join(challenge) }
                    } label: {
                        actionLabel(title: "开始这个目标", icon: "plus", filled: true, busy: busyChallengeId == challenge.id)
                    }
                    .disabled(!busyChallengeId.isEmpty)
                }
            }
        }
        .padding(16)
        .background(.white.opacity(0.92))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(Color(hex: "EEF0F3"), lineWidth: 1))
        .shadow(color: .black.opacity(0.045), radius: 20, x: 0, y: 10)
    }

    private func miniInfo(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .black))
            .foregroundStyle(Color(hex: "8B94A3"))
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(Color(hex: "F7F8FA"))
            .clipShape(Capsule())
    }

    private func actionLabel(title: String, icon: String, filled: Bool, busy: Bool) -> some View {
        HStack(spacing: 7) {
            if busy {
                ProgressView()
                    .tint(filled ? .white : Color(hex: "111318"))
            } else {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .black))
            }
            Text(title)
        }
        .font(.system(size: 13, weight: .black))
        .foregroundStyle(filled ? .white : Color(hex: "111318"))
        .frame(height: 40)
        .frame(maxWidth: .infinity)
        .background(filled ? Color(hex: "111318") : Color(hex: "F7F8FA"))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func statusPill(_ status: String) -> some View {
        Text(statusText(status))
            .font(.system(size: 10, weight: .black))
            .foregroundStyle(challengeTint(status))
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(challengeTint(status).opacity(0.12))
            .clipShape(Capsule())
    }

    private func loadChallenges() async {
        loading = true
        errorMessage = nil
        do {
            challenges = try await APIClient.shared.getChallenges()
        } catch {
            errorMessage = badgesFriendlyError(error, fallback: "挑战暂时没加载出来，稍后再刷新一次。")
        }
        loading = false
    }

    private func join(_ challenge: Challenge) async {
        guard busyChallengeId.isEmpty else { return }
        busyChallengeId = challenge.id
        errorMessage = nil
        do {
            let updated = try await APIClient.shared.joinChallenge(id: challenge.id)
            upsert(updated)
        } catch {
            errorMessage = badgesFriendlyError(error, fallback: "这次还没加入挑战，检查网络后再点加入。")
        }
        busyChallengeId = ""
    }

    private func refresh(_ challenge: Challenge) async {
        guard busyChallengeId.isEmpty else { return }
        busyChallengeId = challenge.id
        errorMessage = nil
        do {
            let updated = try await APIClient.shared.refreshChallenge(id: challenge.id)
            upsert(updated)
        } catch {
            errorMessage = badgesFriendlyError(error, fallback: "挑战进度暂时没刷新，检查网络后再点刷新。")
        }
        busyChallengeId = ""
    }

    private func upsert(_ challenge: Challenge) {
        if let index = challenges.firstIndex(where: { $0.id == challenge.id }) {
            challenges[index] = challenge
        } else {
            challenges.append(challenge)
        }
    }

    private func statusRank(_ status: String) -> Int {
        switch status {
        case "active": return 0
        case "available": return 1
        case "completed": return 2
        default: return 3
        }
    }

    private func statusText(_ status: String) -> String {
        switch status {
        case "active": return "进行中"
        case "available": return "可加入"
        case "completed": return "已完成"
        case "expired": return "已过期"
        default: return "其他状态"
        }
    }

    private func challengeTint(_ status: String) -> Color {
        switch status {
        case "active": return Color(hex: "159BFF")
        case "completed": return Color(hex: "111318")
        case "expired": return Color(hex: "8B94A3")
        default: return Color(hex: "111318")
        }
    }

    private func challengeIcon(_ type: String) -> String {
        switch type {
        case "hydration_goal", "low_sugar_drinks", "no_sugary_drinks": return "drop.fill"
        case "sleep_goal": return "moon.fill"
        case "steps_goal": return "figure.walk"
        case "fasting_completed": return "timer"
        case "food_photo_checkin": return "camera.fill"
        case "vegetable_goal", "low_processed_day": return "leaf.fill"
        case "daily_status_score": return "gauge.with.dots.needle.bottom.50percent"
        case "protein_breakfast": return "fork.knife"
        default: return "flag.fill"
        }
    }
}

private func badgesFriendlyError(_ error: Error, fallback: String) -> String {
    let raw = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !raw.isEmpty else { return fallback }
    let lowercased = raw.lowercased()
    if lowercased.contains("could not connect")
        || lowercased.contains("connection")
        || lowercased.contains("timed out")
        || raw.contains("连接不到")
        || raw.contains("无法连接")
        || raw.contains("网络") {
        return "现在没连上，小目标还没同步。检查网络后再试一次。"
    }
    if lowercased.contains("not found") || raw.contains("404") {
        return "这个小目标暂时找不到，刷新列表。"
    }
    if raw.hasPrefix("{") || raw.hasPrefix("[") || raw.count > 120 || lowercased.contains("json") {
        return fallback
    }
    if raw.contains("失败")
        || raw.contains("错误")
        || raw.contains("异常")
        || raw.contains("无法")
        || lowercased.contains("failed")
        || lowercased.contains("error")
        || lowercased.contains("exception") {
        return fallback
    }
    return raw
}

private struct CreateChallengeSheetView: View {
    let onClose: () -> Void
    let onCreated: (Challenge) -> Void

    @State private var title = "7天拍照记录"
    @State private var description = "每天拍照记录一餐，培养稳定记录习惯。"
    @State private var challengeType = "food_photo_checkin"
    @State private var durationDays = 7
    @State private var targetValue = 1.0
    @State private var rewardPoints = 80
    @State private var saving = false
    @State private var errorMessage: String?

    private let challengeTypes: [(id: String, label: String, defaultTitle: String, defaultDesc: String, target: Double)] = [
        ("food_photo_checkin", "拍照记录", "7天拍照记录", "每天拍照记录一餐，培养稳定记录习惯。", 1),
        ("daily_status_score", "状态分达标", "状态分80分挑战", "每天把今日状态分保持在80分以上。", 80),
        ("hydration_goal", "饮水达标", "5天饮水达标", "每天完成有效饮水目标。", 1),
        ("fasting_completed", "轻断食完成", "5天轻断食完成", "按计划完成当天轻断食。", 1),
        ("sleep_goal", "睡眠达标", "7天睡够7小时", "每天记录睡眠并接近睡眠目标。", 7),
        ("steps_goal", "步数达标", "一周多走路", "每天完成目标步数。", 8000),
        ("vegetable_goal", "蔬菜达标", "一周多吃蔬菜", "每天保证足量蔬菜摄入。", 1),
        ("low_processed_day", "少加工食品", "一周少油少糖", "减少高加工、高油糖食物。", 1),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("选一个今天能开始的小目标")
                            .font(.system(size: 28, weight: .black))
                            .foregroundStyle(Color(hex: "111318"))
                        Text("推荐先选拍照记录或饮水达标，默认设置不用改。")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        fieldTitle("今天先做什么")
                        Picker("今天先做什么", selection: $challengeType) {
                            ForEach(challengeTypes, id: \.id) { item in
                                Text(item.label).tag(item.id)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(Color(hex: "F7F8FA"))
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .onChange(of: challengeType) { _, newValue in
                            applyTypeDefaults(newValue)
                        }

                        fieldTitle("显示名称")
                        TextField("例如：7天拍照记录", text: $title)
                            .textFieldStyle(.plain)
                            .padding(12)
                            .background(Color(hex: "F7F8FA"))
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                        fieldTitle("达成规则")
                        TextField("例如：每天拍照记录一餐", text: $description, axis: .vertical)
                            .textFieldStyle(.plain)
                            .lineLimit(3, reservesSpace: true)
                            .padding(12)
                            .background(Color(hex: "F7F8FA"))
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .padding(16)
                    .softCard(radius: 24)

                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("默认不用改")
                                .font(.system(size: 12, weight: .black))
                                .foregroundStyle(Color(hex: "6D7480"))
                            Spacer()
                        }
                        Stepper("持续 \(durationDays) 天", value: $durationDays, in: 1...30)
                            .font(.system(size: 15, weight: .black))
                        Stepper("目标 \(formatTarget(targetValue))", value: $targetValue, in: 1...20000, step: targetStep)
                            .font(.system(size: 15, weight: .black))
                        Stepper("奖励 \(rewardPoints) 分", value: $rewardPoints, in: 0...500, step: 10)
                            .font(.system(size: 15, weight: .black))
                    }
                    .padding(16)
                    .softCard(radius: 24)

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Color(hex: "E5484D"))
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(hex: "FFF1F1"))
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }

                    Button {
                        Task { await create() }
                    } label: {
                        HStack(spacing: 8) {
                            if saving {
                                ProgressView().tint(.white)
                            } else {
                                Image(systemName: "checkmark")
                                    .accessibilityHidden(true)
                            }
                            Text(saving ? "正在开始" : "开始这个目标")
                        }
                        .font(.system(size: 16, weight: .black))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                        .background(canSave ? Color(hex: "111318") : Color(hex: "B9BEC8"))
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    }
                    .disabled(!canSave || saving)
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 28)
            }
            .background(AppShellBackground())
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .black))
                            .foregroundStyle(Color(hex: "111318"))
                            .frame(width: 34, height: 34)
                            .background(.white)
                            .clipShape(Circle())
                    }
                    .accessibilityLabel("关闭选择目标")
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
    }

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && durationDays > 0 && targetValue > 0
    }

    private var targetStep: Double {
        challengeType == "steps_goal" ? 500 : 1
    }

    private func fieldTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .black))
            .foregroundStyle(Color(hex: "6D7480"))
    }

    private func applyTypeDefaults(_ type: String) {
        guard let item = challengeTypes.first(where: { $0.id == type }) else { return }
        title = item.defaultTitle
        description = item.defaultDesc
        targetValue = item.target
    }

    private func create() async {
        guard canSave, !saving else { return }
        saving = true
        errorMessage = nil
        do {
            let challenge = try await APIClient.shared.createChallenge(ChallengeCreateRequest(
                title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                description: description.trimmingCharacters(in: .whitespacesAndNewlines),
                challengeType: challengeType,
                durationDays: durationDays,
                targetValue: targetValue,
                rewardPoints: rewardPoints
            ))
            onCreated(challenge)
        } catch {
            errorMessage = badgesFriendlyError(error, fallback: "这个目标还没开始成功，检查网络后再点开始。")
        }
        saving = false
    }

    private func formatTarget(_ value: Double) -> String {
        if challengeType == "steps_goal" {
            return "\(Int(value))步"
        }
        if value.rounded() == value {
            return "\(Int(value))"
        }
        return String(format: "%.1f", value)
    }
}
