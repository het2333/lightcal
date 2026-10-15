import SwiftUI

struct AppShellBackground: View {
    var body: some View {
        LinearGradient(
            colors: [Color(hex: "F8FAFC"), Color(hex: "F6F8F3"), Color(hex: "F9F8FB")],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
        .overlay(
            LinearGradient(
                colors: [Color(hex: "159BFF").opacity(0.08), .clear],
                startPoint: .topLeading,
                endPoint: .center
            )
            .ignoresSafeArea()
        )
        .overlay(
            LinearGradient(
                colors: [Color(hex: "111318").opacity(0.035), .clear],
                startPoint: .topTrailing,
                endPoint: .center
            )
            .ignoresSafeArea()
        )
    }
}

struct SoftCardModifier: ViewModifier {
    var radius: CGFloat = 24
    func body(content: Content) -> some View {
        content
            .background(.white.opacity(0.68))
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(.white.opacity(0.72), lineWidth: 1)
            )
            .shadow(color: Color(red: 0.09, green: 0.12, blue: 0.16).opacity(0.055), radius: 22, x: 0, y: 12)
    }
}

extension View {
    func softCard(radius: CGFloat = 24) -> some View {
        modifier(SoftCardModifier(radius: radius))
    }
}

struct CalLoadingCard: View {
    let title: String
    let subtitle: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color(hex: "F1F2F5"))
                ProgressView()
                    .tint(Color(hex: "111318"))
                    .scaleEffect(0.82)
            }
            .frame(width: 52, height: 52)
            .overlay(
                Image(systemName: systemImage)
                    .font(.system(size: 18, weight: .black))
                    .foregroundStyle(Color(hex: "111318").opacity(0.18))
                    .accessibilityHidden(true)
            )

            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 17, weight: .black))
                    .foregroundStyle(Color(hex: "111318"))
                Text(subtitle)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color(hex: "8E949E"))
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(maxWidth: .infinity)
        .softCard(radius: 24)
    }
}

struct AppMarkView: View {
    let size: CGFloat

    var body: some View {
        return ZStack {
            RoundedRectangle(cornerRadius: size * 0.2, style: .continuous)
                .fill(Color(hex: "242329"))
            Image(systemName: "apple.logo")
                .font(.system(size: size * 0.44, weight: .bold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityHidden(true)
            ScanCornerMark(lineWidth: max(1.5, size * 0.07), radius: size * 0.15)
                .stroke(Color(hex: "8C8990"), style: StrokeStyle(lineWidth: max(1.5, size * 0.07), lineCap: .round))
                .frame(width: size * 0.28, height: size * 0.28)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(size * 0.11)
            ScanCornerMark(lineWidth: max(1.5, size * 0.07), radius: size * 0.15)
                .stroke(Color(hex: "8C8990"), style: StrokeStyle(lineWidth: max(1.5, size * 0.07), lineCap: .round))
                .rotationEffect(.degrees(90))
                .frame(width: size * 0.28, height: size * 0.28)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(size * 0.11)
            ScanCornerMark(lineWidth: max(1.5, size * 0.07), radius: size * 0.15)
                .stroke(Color(hex: "8C8990"), style: StrokeStyle(lineWidth: max(1.5, size * 0.07), lineCap: .round))
                .rotationEffect(.degrees(180))
                .frame(width: size * 0.28, height: size * 0.28)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(size * 0.11)
            ScanCornerMark(lineWidth: max(1.5, size * 0.07), radius: size * 0.15)
                .stroke(Color(hex: "8C8990"), style: StrokeStyle(lineWidth: max(1.5, size * 0.07), lineCap: .round))
                .rotationEffect(.degrees(270))
                .frame(width: size * 0.28, height: size * 0.28)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .padding(size * 0.11)
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.16), radius: 12, x: 0, y: 8)
        .accessibilityHidden(true)
    }
}

private struct ScanCornerMark: Shape {
    let lineWidth: CGFloat
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + radius, y: rect.minY),
            control: CGPoint(x: rect.minX, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        return path
    }
}

struct CalPageHeader<Trailing: View>: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let trailing: Trailing

    init(
        title: String,
        subtitle: String,
        systemImage: String,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .black))
                .foregroundStyle(.white)
                .frame(width: 42, height: 42)
                .background(LinearGradient(colors: [Color(hex: "22262C"), Color(hex: "0F1115")], startPoint: .top, endPoint: .bottom))
                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                .shadow(color: .black.opacity(0.12), radius: 14, x: 0, y: 8)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 25, weight: .black))
                    .tracking(-0.4)
                    .foregroundStyle(Color(hex: "111318"))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                Text(subtitle)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .layoutPriority(1)

            Spacer(minLength: 10)
            trailing
        }
    }
}

// MARK: - Day Selector
struct DaySelectorView: View {
    @Binding var selectedDate: Date

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(-3...3, id: \.self) { offset in
                    let date = Calendar.current.date(byAdding: .day, value: offset, to: Date())!
                    let isToday = Calendar.current.isDateInToday(date)
                    let isSelected = Calendar.current.isDate(date, inSameDayAs: selectedDate)
                    VStack(spacing: 4) {
                        Text(chineseWeekday(date))
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(isSelected ? .white.opacity(0.72) : .gray)
                        Text(date.formatted(.dateTime.day()))
                            .font(.system(size: 17, weight: .black))
                    }
                    .frame(width: 44, height: isSelected ? 64 : 54)
                    .background(isSelected ? Color(hex: "20A6D9") : isToday ? Color.white.opacity(0.62) : Color.clear)
                    .foregroundColor(isSelected ? .white : .primary)
                    .clipShape(RoundedRectangle(cornerRadius: isSelected ? 24 : 18, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: isSelected ? 24 : 18, style: .continuous)
                            .stroke(isToday && !isSelected ? Color(hex: "20A6D9").opacity(0.28) : Color.clear, lineWidth: 1)
                    )
                    .shadow(color: isSelected ? Color(hex: "20A6D9").opacity(0.22) : .clear, radius: 14, x: 0, y: 8)
                    .onTapGesture { selectedDate = date }
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func chineseWeekday(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "E"
        return formatter.string(from: date)
    }
}

// MARK: - Calorie Hero
struct CalorieHeroView: View {
    let summary: DailySummary?
    var waterMl: Double = 0
    var waterGoalMl: Double = 2100
    var onOpenHydration: (() -> Void)? = nil
    var onQuickAddWater: (() -> Void)? = nil
    var fastingStatus: FastingStatus? = nil
    var onOpenFasting: (() -> Void)? = nil
    var onScanFood: (() -> Void)? = nil

    private var headline: String {
        let cal = summary?.caloriesConsumed ?? 0
        let goal = max(1, summary?.caloriesGoal ?? 2000)
        let pct = cal / goal
        if cal <= 0 {
            return ""
        }
        if pct < 0.72 {
            return "今天还在可控范围，继续记录就好"
        }
        if pct < 1 {
            return "接近目标了，下一餐清淡一点"
        }
        return "今天热量偏高，后面少油少糖"
    }

    private var fastingSession: FastingSession? {
        fastingStatus?.activeSession
    }

    private var fastingMethod: String {
        fastingSession?.method ?? fastingStatus?.preferences?.method ?? "16:8"
    }

    private var fastingProgress: Double {
        guard let session = fastingSession else { return 0 }
        let elapsed = max(0, session.elapsedSeconds ?? 0)
        let target = max(1, session.targetSeconds ?? Int((session.fastingHours ?? 0) * 3600))
        return min(1, max(0, Double(elapsed) / Double(target)))
    }

    private var inferredFastingStage: (label: String, startsAtHours: Double) {
        guard let elapsedSeconds = fastingSession?.elapsedSeconds else {
            return ("进食窗口", 0)
        }
        let elapsedHours = Double(max(0, elapsedSeconds)) / 3600
        if elapsedHours < 4 { return ("消化吸收", 0) }
        if elapsedHours < 8 { return ("血糖回落", 4) }
        if elapsedHours < 12 { return ("糖原消耗", 8) }
        if elapsedHours < 16 { return ("脂肪动员", 12) }
        return ("轻度酮体", 16)
    }

    private var currentFastingStageLabel: String {
        fastingSession?.stage?.label
            ?? fastingStatus?.currentStage?.label
            ?? inferredFastingStage.label
    }

    private var currentFastingStageStartHour: Double {
        fastingSession?.stage?.startsAtHours
            ?? fastingStatus?.currentStage?.startsAtHours
            ?? inferredFastingStage.startsAtHours
    }

    private var fastingStageTitleText: String {
        if fastingSession != nil {
            return currentFastingStageLabel
        }
        if fastingStatus?.enabled == true {
            return "进食窗口"
        }
        return "未开启"
    }

    private var fastingBodyStatusText: String {
        if let session = fastingSession {
            var parts: [String] = []
            if let enteredTime = fastingStageEnteredTime(session) {
                parts.append("\(enteredTime) 已进入")
            }
            if (session.remainingSeconds ?? 0) > 0 {
                parts.append("还剩 \(heroFastingDuration(session.remainingSeconds))")
            } else {
                parts.append("可结束记录")
            }
            return parts.isEmpty ? "查看当前断食进度" : parts.joined(separator: " · ")
        }
        if fastingStatus?.enabled == true {
            return "\(formattedFastingMethod) · 可开始断食"
        }
        return "设置进食窗口，开启身体六阶段"
    }

    private var fastingBodyStatusIcon: String {
        fastingSession == nil ? "timer" : "bolt.heart.fill"
    }

    var body: some View {
        let cal = summary?.caloriesConsumed ?? 0
        let goal = summary?.caloriesGoal ?? 1600
        let pct = goal > 0 ? min(1, cal / max(1, goal)) : 0
        let waterProgress = min(1, max(0, waterMl / max(1, waterGoalMl)))

        VStack(spacing: 14) {
            HStack(alignment: .center, spacing: 14) {
                calorieDial(cal: cal, goal: goal, progress: pct)

                VStack(spacing: 11) {
                    heroMetricRow(
                        icon: "drop.fill",
                        title: "水分",
                        value: "\(Int(round(waterMl)))",
                        suffix: "/\(Int(round(waterGoalMl))) ml",
                        progress: waterProgress,
                        accent: Color(hex: "1A8DFF"),
                        actionTitle: "+250",
                        rowAction: { onOpenHydration?() },
                        buttonAction: { onQuickAddWater?() }
                    )
                    .frame(height: 76)

                    Divider()
                        .background(Color(hex: "E4EAF1"))

                    heroMetricRow(
                        icon: "timer",
                        title: "进食窗口",
                        value: fastingSession == nil ? formattedFastingMethod : "\(Int(round(fastingProgress * 100)))%",
                        suffix: fastingSession == nil ? " 开始" : " 进行中",
                        progress: fastingSession == nil ? 0 : fastingProgress,
                        accent: Color(hex: "20C05C"),
                        actionTitle: fastingSession == nil ? "开始" : "查看",
                        rowAction: { onOpenFasting?() },
                        buttonAction: { onOpenFasting?() }
                    )
                    .frame(height: 76)
                }
                .frame(maxWidth: .infinity)
            }

            fastingStageStrip
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity)
        .frame(minHeight: 264, alignment: .center)
        .softCard(radius: 28)
    }

    private func calorieDial(cal: Double, goal: Double, progress: Double) -> some View {
        VStack(spacing: 6) {
            ZStack {
                calorieArc(progress: progress)
                    .frame(width: 126, height: 126)
                VStack(spacing: 2) {
                    Image(systemName: "flame.fill")
                        .font(.system(size: 24, weight: .black))
                        .foregroundStyle(Color(hex: "FFB020"))
                        .accessibilityHidden(true)
                    Text("\(Int(cal))")
                        .font(.system(size: 36, weight: .black))
                        .monospacedDigit()
                        .foregroundStyle(Color(hex: "111318"))
                        .lineLimit(1)
                        .minimumScaleFactor(0.62)
                    Text("kcal")
                        .font(.system(size: 14, weight: .black))
                        .foregroundStyle(Color(hex: "66758A"))
                    Text("今日摄入")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color(hex: "66758A"))
                }
                .offset(y: -2)
            }
            .frame(width: 132, height: 132)

            HStack(spacing: 6) {
                Text("目标 \(String(Int(goal))) kcal")
                    .font(.system(size: 11, weight: .black))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                Image(systemName: "pencil")
                    .font(.system(size: 11, weight: .black))
                    .accessibilityHidden(true)
            }
            .foregroundStyle(Color(hex: "18A33F"))
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(Color(hex: "EAFBEF").opacity(0.92))
            .clipShape(Capsule())
        }
        .frame(width: 134)
    }

    private var fastingStageStrip: some View {
        Button(action: { onOpenFasting?() }) {
            HStack(spacing: 10) {
                Image(systemName: fastingBodyStatusIcon)
                    .font(.system(size: 15, weight: .black))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(Color(hex: "20C05C"))
                    .clipShape(Circle())
                    .accessibilityHidden(true)

                Text(fastingSession == nil ? "设置进食窗口，开启身体六阶段" : fastingBodyStatusText)
                    .font(.system(size: 14, weight: .black))
                    .foregroundStyle(Color(hex: "66758A"))
                    .lineLimit(1)
                    .minimumScaleFactor(0.62)

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(Color(hex: "94A3B8"))
                    .accessibilityHidden(true)
            }
            .padding(.leading, 12)
            .padding(.trailing, 10)
            .frame(height: 48)
            .background(LinearGradient(colors: [Color(hex: "E9FBF1"), Color(hex: "EAF4FF")], startPoint: .leading, endPoint: .trailing))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(onOpenFasting == nil)
    }

    private var formattedFastingMethod: String {
        let parts = fastingMethod.split(separator: ":").map(String.init)
        guard parts.count == 2, parts[1].count == 1 else {
            return fastingMethod
        }
        return "\(parts[0]):0\(parts[1])"
    }

    private func heroFastingDuration(_ seconds: Int?) -> String {
        guard let seconds, seconds > 0 else { return "0分钟" }
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        if hours > 0 && minutes > 0 {
            return "\(hours)小时\(minutes)分钟"
        }
        if hours > 0 {
            return "\(hours)小时"
        }
        return "\(max(1, minutes))分钟"
    }

    private func fastingStageEnteredTime(_ session: FastingSession) -> String? {
        guard let start = heroParseFastingDate(session.startAt) else { return nil }
        let entered = start.addingTimeInterval(currentFastingStageStartHour * 3600)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: entered)
    }

    private func heroParseFastingDate(_ text: String?) -> Date? {
        guard var text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }
        if !text.contains("Z") && !text.contains("+") {
            text += "+08:00"
        }

        let isoWithFraction = ISO8601DateFormatter()
        isoWithFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = isoWithFraction.date(from: text) {
            return date
        }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: text) {
            return date
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        for format in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss.SSS"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) {
                return date
            }
        }
        return nil
    }

    private func calorieArc(progress: Double) -> some View {
        let startDegrees = 140.0
        let sweepDegrees = 260.0
        let endDegrees = startDegrees + sweepDegrees
        let side: CGFloat = 126
        let lineWidth: CGFloat = 13
        let radius = side / 2 - lineWidth / 2
        let center = CGPoint(x: side / 2, y: side / 2)
        let endRadians = endDegrees * Double.pi / 180
        let endPoint = CGPoint(
            x: center.x + radius * CGFloat(cos(endRadians)),
            y: center.y + radius * CGFloat(sin(endRadians))
        )

        return ZStack {
            Path { path in
                path.addArc(
                    center: center,
                    radius: radius,
                    startAngle: .degrees(startDegrees),
                    endAngle: .degrees(endDegrees),
                    clockwise: false
                )
            }
            .stroke(Color(hex: "EEF0F3"), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))

            if progress > 0.005 {
                Path { path in
                    path.addArc(
                        center: center,
                        radius: radius,
                        startAngle: .degrees(startDegrees),
                        endAngle: .degrees(startDegrees + sweepDegrees * max(0.03, progress)),
                        clockwise: false
                    )
                }
                .stroke(
                    AngularGradient(
                        colors: [Color(hex: "1A8DFF"), Color(hex: "33BFE1"), Color(hex: "74D44C")],
                        center: .center
                    ),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
            }

            Circle()
                .fill(Color(hex: "74D44C"))
                .frame(width: 13, height: 13)
                .position(endPoint)
        }
        .frame(width: side, height: side)
        .accessibilityHidden(true)
    }

    private func heroMetricRow(
        icon: String,
        title: String,
        value: String,
        suffix: String,
        progress: Double,
        accent: Color,
        actionTitle: String,
        rowAction: @escaping () -> Void,
        buttonAction: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 7) {
            Button(action: rowAction) {
                ZStack {
                    Circle()
                        .fill(accent.opacity(0.12))
                    Image(systemName: icon)
                        .font(.system(size: 23, weight: .black))
                        .foregroundStyle(accent)
                        .accessibilityHidden(true)
                }
                .frame(width: 42, height: 42)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.system(size: 15, weight: .black))
                    .foregroundStyle(Color(hex: "111318"))
                    .lineLimit(1)
                    .minimumScaleFactor(0.76)
                Text("\(value)\(suffix)")
                    .font(.system(size: 18, weight: .black))
                    .foregroundStyle(Color(hex: "111318"))
                    .lineLimit(1)
                    .minimumScaleFactor(0.48)
                    .monospacedDigit()
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color(hex: "EBEEF3"))
                        Capsule()
                            .fill(LinearGradient(colors: [accent, accent.opacity(0.58)], startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(progress > 0 ? 8 : 0, proxy.size.width * CGFloat(min(1, max(0, progress)))))
                    }
                }
                .frame(height: 6)
            }
            .layoutPriority(2)

            Button(action: buttonAction) {
                Text(actionTitle)
                    .font(.system(size: 15, weight: .black))
                    .foregroundStyle(accent)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .frame(width: 52)
                    .frame(height: 36)
                    .background(accent.opacity(0.10))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    private func calorieProgressRing(progress: Double) -> some View {
        ZStack {
            Circle()
                .stroke(Color.gray.opacity(0.12), lineWidth: 10)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(Color(hex: "1C1C1E"), style: StrokeStyle(lineWidth: 10, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 1), value: progress)
            Circle()
                .fill(.white)
                .frame(width: 38, height: 38)
                .shadow(color: .black.opacity(0.08), radius: 6, x: 0, y: 3)
            Image(systemName: "flame.fill")
                .font(.system(size: 20, weight: .bold))
                .accessibilityHidden(true)
        }
        .frame(width: 76, height: 76)
        .accessibilityHidden(true)
    }

    private func calorieStatusChip(
        icon: String,
        title: String,
        value: String,
        progress: Double,
        accent: Color,
        actionTitle: String,
        rowAction: @escaping () -> Void,
        buttonAction: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 7) {
            Button(action: rowAction) {
                HStack(spacing: 7) {
                    calorieStatusGlyph(
                        icon: icon,
                        progress: progress,
                        accent: accent,
                        isActive: icon == "timer" && fastingSession != nil
                    )
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title)
                            .font(.system(size: 12, weight: .black))
                            .foregroundStyle(Color(hex: "111318"))
                            .lineLimit(1)
                        Text(value)
                            .font(.system(size: 10, weight: .black))
                            .foregroundStyle(Color(hex: "8E949E"))
                            .lineLimit(1)
                            .minimumScaleFactor(0.62)
                        GeometryReader { proxy in
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(Color(hex: "E8EDF4"))
                                Capsule()
                                    .fill(accent)
                                    .frame(width: max(progress > 0 ? 6 : 0, proxy.size.width * CGFloat(progress)))
                            }
                        }
                        .frame(height: 4)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            Button(action: buttonAction) {
                Text(actionTitle)
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(Color(hex: "111318"))
                    .frame(width: 38, height: 28)
                    .background(.white)
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(Color(hex: "E5E9EF"), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled((icon == "drop.fill" && onQuickAddWater == nil) || (icon == "timer" && onOpenFasting == nil))
        }
        .padding(.horizontal, 9)
        .frame(maxWidth: .infinity)
        .frame(height: 47)
        .background(Color(hex: "F7F8FA"))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    @ViewBuilder
    private func calorieStatusGlyph(icon: String, progress: Double, accent: Color, isActive: Bool) -> some View {
        if icon == "drop.fill" {
            miniWaterBottle(progress: progress, percent: Int(round(progress * 100)))
                .scaleEffect(0.86)
                .frame(width: 34, height: 38)
        } else {
            fastingWindowGlyph(progress: progress, accent: accent, isActive: isActive)
        }
    }

    private func fastingWindowGlyph(progress: Double, accent: Color, isActive: Bool) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(hex: "111318"))
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)

            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.20), lineWidth: 2.5)
                Circle()
                    .trim(from: 0, to: max(0.08, progress))
                    .stroke(accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .opacity(isActive ? 1 : 0.55)
                Image(systemName: isActive ? "fork.knife" : "timer")
                    .font(.system(size: isActive ? 10 : 11, weight: .black))
                    .foregroundStyle(.white)
                    .accessibilityHidden(true)
            }
            .frame(width: 24, height: 24)

            VStack {
                Spacer(minLength: 0)
                Capsule()
                    .fill(accent.opacity(isActive ? 1 : 0.55))
                    .frame(width: 14, height: 4)
                    .padding(.bottom, 5)
            }
        }
        .frame(width: 34, height: 38)
        .accessibilityHidden(true)
    }

    private func miniWaterBottle(progress: Double, percent: Int) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(hex: "F2FAFF"))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color(hex: "D8EEFF"), lineWidth: 1.2)
                )
            GeometryReader { proxy in
                VStack {
                    Spacer(minLength: 0)
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(LinearGradient(
                            colors: [Color(hex: "159BFF"), Color(hex: "73D8FF")],
                            startPoint: .bottom,
                            endPoint: .top
                        ))
                        .frame(height: max(progress > 0 ? 5 : 0, proxy.size.height * CGFloat(progress)))
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .padding(3)
            }
            Image(systemName: "drop.fill")
                .font(.system(size: 13, weight: .black))
                .foregroundStyle(progress > 0.52 ? .white : Color(hex: "159BFF"))
                .accessibilityHidden(true)
        }
        .frame(width: 34, height: 44)
        .overlay(alignment: .top) {
            Capsule()
                .fill(Color(hex: "E8F5FF"))
                .frame(width: 18, height: 6)
                .overlay(Capsule().stroke(Color(hex: "C7E8FF"), lineWidth: 1))
                .offset(y: -4)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Water & Weight Cards
struct WaterCardView: View {
    let currentMl: Double
    let goalMl: Double
    let onOpen: () -> Void
    let onQuickAdd: () -> Void

    var body: some View {
        let progress = min(1, max(0, currentMl / max(1, goalMl)))
        let percent = Int(round(progress * 100))
        let remaining = max(0, goalMl - currentMl)
        return VStack(spacing: 10) {
            Button(action: onOpen) {
                HStack(alignment: .top, spacing: 10) {
                    waterBottle(progress: progress, percent: percent)

                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Text("饮水")
                                .font(.system(size: 13, weight: .black))
                                .foregroundStyle(Color(hex: "111318"))
                            Text("\(percent)%")
                                .font(.system(size: 10, weight: .black))
                                .foregroundStyle(Color(hex: "159BFF"))
                                .padding(.horizontal, 7)
                                .frame(height: 20)
                                .background(Color(hex: "EAF4FF"))
                                .clipShape(Capsule())
                                .lineLimit(1)
                        }

                        HStack(alignment: .firstTextBaseline, spacing: 2) {
                            Text("\(Int(round(currentMl)))")
                                .font(.system(size: 24, weight: .black))
                                .foregroundStyle(Color(hex: "111318"))
                                .lineLimit(1)
                                .minimumScaleFactor(0.62)
                                .monospacedDigit()
                            Text("/\(Int(round(goalMl)))毫升")
                                .font(.system(size: 11, weight: .black))
                                .foregroundColor(.gray)
                                .lineLimit(1)
                                .minimumScaleFactor(0.65)
                        }

                        Text(remaining > 0 ? "还差 \(Int(round(remaining)))毫升" : "今日目标已达成")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(Color(hex: remaining > 0 ? "8E949E" : "159BFF"))
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("饮水，\(Int(currentMl)) 毫升，目标 \(Int(goalMl)) 毫升")

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color(hex: "EAF4FF"))
                    Capsule()
                        .fill(LinearGradient(
                            colors: [Color(hex: "159BFF"), Color(hex: "73D8FF")],
                            startPoint: .leading,
                            endPoint: .trailing
                        ))
                        .frame(width: max(8, proxy.size.width * CGFloat(progress)))
                }
            }
            .frame(height: 7)

            Button(action: onQuickAdd) {
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .black))
                        .accessibilityHidden(true)
                    Text("250毫升")
                        .font(.system(size: 13, weight: .black))
                }
                .foregroundStyle(Color(hex: "159BFF"))
                .frame(maxWidth: .infinity)
                .frame(height: 36)
                .background(Color(hex: "EAF4FF"))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("添加 250 毫升饮水")
        }
        .padding(14)
        .softCard(radius: 22)
    }

    private func waterBottle(progress: Double, percent: Int) -> some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color(hex: "E8F5FF"))
                .frame(width: 24, height: 8)
                .overlay(Capsule().stroke(Color(hex: "C7E8FF"), lineWidth: 1))
                .offset(y: 2)

            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color(hex: "F2FAFF"))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(Color(hex: "D8EEFF"), lineWidth: 1.4)
                    )
                GeometryReader { proxy in
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color.clear)
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(LinearGradient(
                                colors: [Color(hex: "159BFF"), Color(hex: "70D6FF")],
                                startPoint: .bottom,
                                endPoint: .top
                            ))
                            .frame(height: max(progress > 0 ? 7 : 0, proxy.size.height * CGFloat(progress)))
                            .overlay(alignment: .top) {
                                Capsule()
                                    .fill(.white.opacity(0.34))
                                    .frame(width: 24, height: 4)
                                    .padding(.top, 6)
                            }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .padding(3)

                VStack(spacing: 2) {
                    Image(systemName: "drop.fill")
                        .font(.system(size: 16, weight: .black))
                        .foregroundStyle(progress > 0.52 ? .white : Color(hex: "159BFF"))
                        .accessibilityHidden(true)
                    Text("\(percent)%")
                        .font(.system(size: 8, weight: .black))
                        .foregroundStyle(progress > 0.52 ? .white.opacity(0.9) : Color(hex: "159BFF"))
                        .monospacedDigit()
                }
            }
            .frame(width: 44, height: 54)
        }
        .frame(width: 48, height: 62)
        .accessibilityHidden(true)
    }
}

struct WeightCardView: View {
    let weight: Double?
    var body: some View {
        HStack {
            Image(systemName: "scalemass.fill")
                .foregroundColor(.gray)
                .accessibilityHidden(true)
            VStack(alignment: .leading) {
                Text(weight.map { "\(String(format: "%.1f", $0)) 公斤" } ?? "-- 公斤").font(.subheadline.bold())
                Text("体重").font(.caption).foregroundColor(.gray)
            }
            Spacer()
        }
        .padding(12)
        .softCard(radius: 16)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Hydration
enum HydrationRuntimeCache {
    private static let freshSeconds: TimeInterval = 30
    private static var summaryByDate: [String: HydrationSummary] = [:]
    private static var logsByDate: [String: [HydrationLog]] = [:]
    private static var weeklyLogsByDate: [String: [HydrationLog]] = [:]
    private static var loadedAtByDate: [String: Date] = [:]
    private static var cachedPresets: [DrinkPreset] = []
    private static var cachedReminders: [ReminderItem] = []

    static func todayDateKey() -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    static func normalizedDateKey(_ date: String) -> String {
        let clean = date.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? todayDateKey() : clean
    }

    static func isFresh(dateKey: String) -> Bool {
        guard let loadedAt = loadedAtByDate[dateKey] else { return false }
        return Date().timeIntervalSince(loadedAt) < freshSeconds
    }

    static func hasCachedHydration(dateKey: String) -> Bool {
        summaryByDate[dateKey] != nil || logsByDate[dateKey] != nil
    }

    static func summary(dateKey: String) -> HydrationSummary? {
        summaryByDate[dateKey]
    }

    static func logs(dateKey: String) -> [HydrationLog] {
        logsByDate[dateKey] ?? []
    }

    static func weeklyLogs(dateKey: String) -> [HydrationLog] {
        weeklyLogsByDate[dateKey] ?? logs(dateKey: dateKey)
    }

    static func presets() -> [DrinkPreset] {
        cachedPresets
    }

    static func reminders() -> [ReminderItem] {
        cachedReminders
    }

    static func save(
        dateKey: String,
        summary: HydrationSummary?,
        logs: [HydrationLog]?,
        weeklyLogs: [HydrationLog]? = nil,
        presets: [DrinkPreset]? = nil,
        reminders: [ReminderItem]? = nil
    ) {
        if let summary {
            summaryByDate[dateKey] = summary
        }
        if let logs {
            logsByDate[dateKey] = logs
        }
        if let weeklyLogs {
            weeklyLogsByDate[dateKey] = weeklyLogs
        }
        if let presets {
            cachedPresets = presets
        }
        if let reminders {
            cachedReminders = reminders
        }
        loadedAtByDate[dateKey] = Date()
    }
}

private struct HydrationDaySummary: Identifiable {
    let dateKey: String
    let weekdayLabel: String
    let dayLabel: String
    let effectiveMl: Double
    let amountMl: Double
    let count: Int
    let goalMl: Double
    let isSelected: Bool

    var id: String { dateKey }
    var progress: Double { min(1, max(0, effectiveMl / max(1, goalMl))) }
    var reachedGoal: Bool { effectiveMl >= goalMl && goalMl > 0 }
}

struct HydrationPageView: View {
    let logDate: String
    let onClose: () -> Void
    let onChanged: () -> Void

    @State private var summary: HydrationSummary?
    @State private var logs: [HydrationLog] = []
    @State private var weeklyLogs: [HydrationLog] = []
    @State private var presets: [DrinkPreset] = []
    @State private var reminders: [ReminderItem] = []
    @State private var loading = true
    @State private var busyDrink = ""
    @State private var deletingId = ""
    @State private var clearingToday = false
    @State private var errorMessage = ""
    @State private var selectedPreset: DrinkPreset?
    @State private var showCustomDrinkEditor = false
    @State private var showHydrationGoalSettings = false
    @State private var selectedHydrationTab = "today"

    init(logDate: String = "", onClose: @escaping () -> Void, onChanged: @escaping () -> Void) {
        self.logDate = logDate
        self.onClose = onClose
        self.onChanged = onChanged
        let dateKey = HydrationRuntimeCache.normalizedDateKey(logDate)
        _summary = State(initialValue: HydrationRuntimeCache.summary(dateKey: dateKey))
        _logs = State(initialValue: HydrationRuntimeCache.logs(dateKey: dateKey))
        _weeklyLogs = State(initialValue: HydrationRuntimeCache.weeklyLogs(dateKey: dateKey))
        _presets = State(initialValue: HydrationRuntimeCache.presets())
        _reminders = State(initialValue: HydrationRuntimeCache.reminders())
        _loading = State(initialValue: !HydrationRuntimeCache.hasCachedHydration(dateKey: dateKey))
    }

    private var hydrationDateKey: String {
        HydrationRuntimeCache.normalizedDateKey(logDate)
    }

    private var selectedDateLabel: String {
        let dateKey = hydrationDateKey
        if dateKey == HydrationRuntimeCache.todayDateKey() {
            return "今天"
        }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: dateKey) else {
            return "所选日期"
        }
        formatter.dateFormat = "M月d日"
        return formatter.string(from: date)
    }

    private var currentMl: Double { summary?.hydrationEffectiveMl ?? 0 }
    private var goalMl: Double { max(1, summary?.hydrationGoalMl ?? 2100) }
    private var progress: Double { min(1, max(0, currentMl / goalMl)) }

    private var weeklyHydrationRows: [HydrationDaySummary] {
        let formatter = Self.dateKeyFormatter()
        let calendar = Calendar(identifier: .gregorian)
        let endDate = formatter.date(from: hydrationDateKey) ?? Date()
        var grouped: [String: [HydrationLog]] = [:]
        for log in weeklyLogs {
            let key = log.date ?? log.loggedAt.flatMap(Self.dateKeyFromLogTimestamp) ?? hydrationDateKey
            grouped[key, default: []].append(log)
        }
        return (0..<7).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset - 6, to: endDate) else {
                return nil
            }
            let key = formatter.string(from: date)
            let dayLogs = grouped[key] ?? []
            let effective = dayLogs.reduce(0) { $0 + $1.effectiveMl }
            let amount = dayLogs.reduce(0) { $0 + $1.amountMl }
            return HydrationDaySummary(
                dateKey: key,
                weekdayLabel: Self.shortWeekdayLabel(for: date),
                dayLabel: Self.shortDateLabel(for: date),
                effectiveMl: effective,
                amountMl: amount,
                count: dayLogs.count,
                goalMl: goalMl,
                isSelected: key == hydrationDateKey
            )
        }
    }

    private var weeklyAverageMl: Double {
        let rows = weeklyHydrationRows
        guard !rows.isEmpty else { return 0 }
        return rows.reduce(0) { $0 + $1.effectiveMl } / Double(rows.count)
    }

    private var weeklyReachedDays: Int {
        weeklyHydrationRows.filter(\.reachedGoal).count
    }

    private var weeklyBestDay: HydrationDaySummary? {
        weeklyHydrationRows.max { $0.effectiveMl < $1.effectiveMl }
    }

    private var displayPresets: [DrinkPreset] {
        let source = presets.isEmpty ? Self.fallbackPresets : presets
        let order = ["water", "sparkling_water", "tea", "coffee", "milk", "juice", "latte", "energy_drink", "alcohol"]
        return source.sorted {
            (order.firstIndex(of: $0.drinkType) ?? 999) < (order.firstIndex(of: $1.drinkType) ?? 999)
        }
    }

    private var hydrationReminder: ReminderItem? {
        reminders.first { $0.category == "hydration" || $0.mealType == "hydration" }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                hydrationPageBackground

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 16) {
                        header
                        if loading {
                            CalLoadingCard(
                                title: "正在读取饮水",
                                subtitle: "同步\(selectedDateLabel)饮品、目标和提醒",
                                systemImage: "drop.fill"
                            )
                            .padding(.vertical, 84)
                        } else {
                            waterHero
                            hydrationStreakCard
                            quickAmountRow
                            hydrationMetricStrip
                            hydrationTabs
                            Group {
                                if selectedHydrationTab == "today" {
                                    hydrationTimeline
                                    todayLogs
                                    hydrationPaceCard
                                } else if selectedHydrationTab == "drinks" {
                                    drinkTypeGrid
                                    drinkBreakdownCard
                                    hydrationInsights
                                } else {
                                    weeklyHydrationChart
                                    hydrationHistorySummary
                                    drinkBreakdownCard
                                }
                            }
                        }
                        if !errorMessage.isEmpty {
                            Text(errorMessage)
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(Color(hex: "EF4444"))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 18)
                    .padding(.bottom, 42)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .task { await loadHydration() }
            .sheet(item: $selectedPreset) { preset in
                DrinkPresetDetailSheet(
                    preset: preset,
                    onLog: { amount, type in
                        Task { await logDrink(amount: amount, type: type) }
                    }
                )
                .presentationDetents([.medium])
                .presentationDragIndicator(.hidden)
            }
            .sheet(isPresented: $showCustomDrinkEditor) {
                CustomDrinkPresetSheet { name, amount, factor, caffeine, sugar, calories in
                    Task {
                        await addCustomPreset(
                            name: name,
                            amount: amount,
                            factor: factor,
                            caffeine: caffeine,
                            sugar: sugar,
                            calories: calories
                        )
                    }
                }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.hidden)
            }
            .sheet(isPresented: $showHydrationGoalSettings) {
                HydrationGoalSettingsSheet(
                    currentGoalMl: goalMl,
                    reminder: hydrationReminder
                ) { goal, reminderEnabled, reminderTime, reminderIntervalMinutes in
                    await saveHydrationGoal(
                        goal,
                        reminderEnabled: reminderEnabled,
                        reminderTime: reminderTime,
                        reminderIntervalMinutes: reminderIntervalMinutes
                    )
                }
                .presentationDetents([.medium])
                .presentationDragIndicator(.hidden)
            }
        }
    }

    private var hydrationPageBackground: some View {
        AppShellBackground()
    }

    private var hydrationOverview: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .stroke(Color(hex: "DDEEFF"), lineWidth: 8)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(Color(hex: "159BFF"), style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.7), value: progress)
                Image(systemName: "drop.fill")
                    .font(.system(size: 25, weight: .black))
                    .foregroundStyle(Color(hex: "159BFF"))
                    .accessibilityHidden(true)
            }
            .frame(width: 78, height: 78)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                Text("饮水")
                    .font(.system(size: 26, weight: .black))
                    .foregroundStyle(Color(hex: "111318"))
                Text("\(Int(round(currentMl))) / \(Int(round(goalMl))) 毫升")
                    .font(.system(size: 15, weight: .black))
                    .foregroundStyle(Color(hex: "5A6B82"))
                Text(reminderLabel)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color(hex: "8E949E"))
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(Int(round(progress * 100)))%")
                    .font(.system(size: 34, weight: .black))
                    .foregroundStyle(Color(hex: "159BFF"))
                Text(progress >= 1 ? "已达标" : selectedDateLabel)
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(Color(hex: "8E949E"))
            }
        }
        .padding(18)
        .background(.white.opacity(0.94))
        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
        .shadow(color: Color(hex: "159BFF").opacity(0.10), radius: 20, x: 0, y: 10)
    }

    private var hydrationTabs: some View {
        HStack(spacing: 8) {
            hydrationTabButton(id: "today", title: selectedDateLabel, icon: "drop.fill")
            hydrationTabButton(id: "drinks", title: "饮品", icon: "cup.and.saucer.fill")
            hydrationTabButton(id: "history", title: "历史", icon: "chart.bar.fill")
        }
        .padding(5)
        .background(Color(hex: "F2F4F7"))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func hydrationTabButton(id: String, title: String, icon: String) -> some View {
        let active = selectedHydrationTab == id
        return Button {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                selectedHydrationTab = id
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .black))
                Text(title)
                    .font(.system(size: 13, weight: .black))
            }
            .foregroundStyle(active ? .white : Color(hex: "6D7480"))
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .background(
                active
                ? LinearGradient(colors: [Color(hex: "159BFF"), Color(hex: "56C7FF")], startPoint: .leading, endPoint: .trailing)
                : LinearGradient(colors: [Color.clear, Color.clear], startPoint: .leading, endPoint: .trailing)
            )
            .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var reminderLabel: String {
        guard let hydrationReminder, hydrationReminder.enabled else {
            return "提醒已关闭"
        }
        let time = hydrationReminder.time.isEmpty ? "15:00" : hydrationReminder.time
        let interval = hydrationReminder.intervalMinutes
        return "\(time) 开始 · 每 \(interval) 分钟"
    }

    private var header: some View {
        CalPageHeader(
            title: "饮水",
            subtitle: progress >= 1 ? "\(selectedDateLabel)补水已达标" : "还差 \(Int(round(max(0, goalMl - currentMl)))) 毫升",
            systemImage: "drop.fill"
        ) {
            HStack(spacing: 10) {
                hydrationHeaderButton(systemImage: "target", label: "饮水目标") {
                    showHydrationGoalSettings = true
                }
                hydrationHeaderButton(systemImage: "arrow.clockwise", label: "刷新饮水") {
                    Task { await loadHydration(force: true) }
                }
                hydrationHeaderButton(systemImage: "xmark", label: "关闭饮水", action: onClose)
            }
        }
    }

    private func hydrationHeaderButton(systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .black))
                .foregroundStyle(Color(hex: "111318"))
                .frame(width: 42, height: 42)
                .background(.white.opacity(0.86))
                .clipShape(Circle())
                .overlay(Circle().stroke(Color(hex: "EEF0F3"), lineWidth: 1))
                .shadow(color: .black.opacity(0.05), radius: 10, x: 0, y: 6)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private var waterHero: some View {
        let remainingMl = max(0, goalMl - currentMl)
        return VStack(spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("\(selectedDateLabel)饮水")
                        .font(.system(size: 14, weight: .black))
                        .foregroundStyle(Color(hex: "8E949E"))
                    Text(progress >= 1 ? "目标完成" : "还差 \(Int(round(remainingMl))) 毫升")
                        .font(.system(size: 20, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                        .lineLimit(1)
                        .minimumScaleFactor(0.76)
                }
                Spacer()
                Button {
                    showHydrationGoalSettings = true
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "target")
                            .accessibilityHidden(true)
                        Text("目标")
                    }
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(Color(hex: "159BFF"))
                    .padding(.horizontal, 11)
                    .frame(height: 32)
                    .background(Color(hex: "F1F8FF"))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }

            VStack(spacing: 10) {
                waterMinderBottle(progress: progress)

                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(Int(round(currentMl)))")
                        .font(.system(size: 44, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                    Text("/\(Int(round(goalMl)))毫升")
                        .font(.system(size: 17, weight: .black))
                        .foregroundStyle(Color(hex: "8E949E"))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
                Text(lastDrinkLabel)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color(hex: "8E949E"))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }

            hydrationNextStepCard

            HStack(spacing: 10) {
                waterHeroStat("剩余", "\(Int(round(remainingMl)))毫升")
                waterHeroStat("目标", "\(Int(round(goalMl)))毫升")
                waterHeroStat("记录", "\(summary?.drinkCount ?? logs.count)次")
            }

            Button {
                Task { await logDrink(amount: 250, type: "water") }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "plus")
                    Text("+250毫升")
                }
                .font(.system(size: 20, weight: .black))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 58)
                .background(LinearGradient(
                    colors: [Color(hex: "159BFF"), Color(hex: "56C7FF")],
                    startPoint: .leading,
                    endPoint: .trailing
                ))
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .shadow(color: Color(hex: "159BFF").opacity(0.22), radius: 18, x: 0, y: 10)
            }
            .buttonStyle(.plain)
            .disabled(!busyDrink.isEmpty)
        }
        .padding(18)
        .frame(maxWidth: .infinity)
        .softCard(radius: 30)
    }

    private var hydrationStreakCard: some View {
        let reachedToday = progress >= 1
        let bestDay = weeklyBestDay
        let bestValue = Int(round(bestDay?.effectiveMl ?? 0))
        let selectedRow = weeklyHydrationRows.first { $0.isSelected }
        let todayCount = selectedRow?.count ?? logs.count
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(reachedToday ? Color(hex: "EAFBF2") : Color(hex: "EAF4FF"))
                    Image(systemName: reachedToday ? "checkmark" : "drop.fill")
                        .font(.system(size: 18, weight: .black))
                        .foregroundStyle(reachedToday ? Color(hex: "27B36A") : Color(hex: "159BFF"))
                        .accessibilityHidden(true)
                }
                .frame(width: 48, height: 48)

                VStack(alignment: .leading, spacing: 4) {
                    Text(reachedToday ? "今日补水已达标" : "继续补水")
                        .font(.system(size: 18, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                    Text(reachedToday ? "保持小口慢喝，明天继续延续节奏。" : "还差 \(Int(round(max(0, goalMl - currentMl)))) 毫升，本周已达标 \(weeklyReachedDays) 天。")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color(hex: "8E949E"))
                        .lineLimit(2)
                        .minimumScaleFactor(0.82)
                }
                Spacer(minLength: 6)
                Text("\(Int(round(progress * 100)))%")
                    .font(.system(size: 24, weight: .black))
                    .foregroundStyle(reachedToday ? Color(hex: "27B36A") : Color(hex: "159BFF"))
                    .monospacedDigit()
            }

            HStack(spacing: 10) {
                hydrationBadgeMetric(title: "本周达标", value: "\(weeklyReachedDays)/7", color: Color(hex: "159BFF"))
                hydrationBadgeMetric(title: "今日记录", value: "\(todayCount)次", color: Color(hex: "111318"))
                hydrationBadgeMetric(title: "最好一天", value: bestValue > 0 ? "\(bestValue)毫升" : "--", color: Color(hex: "27B36A"))
            }
        }
        .padding(16)
        .background(.white.opacity(0.96))
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(reachedToday ? Color(hex: "D9F7E8") : Color(hex: "E0F1FF"), lineWidth: 1)
        )
        .shadow(color: Color(hex: "159BFF").opacity(0.06), radius: 16, x: 0, y: 8)
    }

    private func hydrationBadgeMetric(title: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(value)
                .font(.system(size: 15, weight: .black))
                .foregroundStyle(Color(hex: "111318"))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            HStack(spacing: 5) {
                Circle()
                    .fill(color)
                    .frame(width: 6, height: 6)
                Text(title)
                    .font(.system(size: 10, weight: .black))
                    .foregroundStyle(Color(hex: "8E949E"))
                    .lineLimit(1)
                    .minimumScaleFactor(0.76)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(hex: "F7F8FA"))
        .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
    }

    private var lastDrinkLabel: String {
        guard let latest = logs.first else {
            return "\(selectedDateLabel)先记一杯水，进度会立刻更新"
        }
        return "上次 \(displayName(forDrinkType: latest.drinkType)) · \(Int(round(latest.amountMl)))毫升 · \(displayLogTime(latest.loggedAt))"
    }

    private var hydrationNextStepCard: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(progress >= 1 ? Color(hex: "EAFBF2") : Color(hex: "EAF4FF"))
                Image(systemName: progress >= 1 ? "checkmark" : "bell.badge.fill")
                    .font(.system(size: 14, weight: .black))
                    .foregroundStyle(progress >= 1 ? Color(hex: "27B36A") : Color(hex: "159BFF"))
                    .accessibilityHidden(true)
            }
            .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text(progress >= 1 ? "\(selectedDateLabel)已达标" : "下一杯建议")
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(Color(hex: "111318"))
                Text(progress >= 1 ? "继续少量多次，避免一次性喝太多。" : "\(reminderLabel) · 建议先加 250 毫升。")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color(hex: "8E949E"))
                    .lineLimit(2)
                    .minimumScaleFactor(0.82)
            }
            Spacer()
            if let latest = logs.first {
                Button {
                    Task { await deleteLog(latest.id) }
                } label: {
                    if deletingId == latest.id {
                        ProgressView()
                            .tint(Color(hex: "159BFF"))
                    } else {
                        Text("撤销上次")
                            .font(.system(size: 11, weight: .black))
                            .foregroundStyle(Color(hex: "159BFF"))
                            .padding(.horizontal, 10)
                            .frame(height: 30)
                            .background(.white)
                            .clipShape(Capsule())
                    }
                }
                .buttonStyle(.plain)
                .disabled(!deletingId.isEmpty || clearingToday)
                .accessibilityLabel("撤销上次饮水记录")
            }
        }
        .padding(12)
        .background(Color(hex: "F7FBFF"))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color(hex: "E0F1FF"), lineWidth: 1))
    }

    private func displayLogTime(_ loggedAt: String?) -> String {
        guard let value = loggedAt, !value.isEmpty else { return "刚刚" }
        if let date = Self.parseLogDate(value) {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "zh_CN")
            formatter.dateFormat = "HH:mm"
            return formatter.string(from: date)
        }
        let timeText = value.split(separator: " ").last.map(String.init) ?? value
        return String(timeText.prefix(5))
    }

    private func waterMinderBottle(progress: Double) -> some View {
        let clamped = min(1, max(0, progress))
        return VStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(hex: "F5FBFF"))
                .frame(width: 50, height: 15)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color(hex: "CDEBFF"), lineWidth: 2)
                )
                .offset(y: 2)

            ZStack {
                RoundedRectangle(cornerRadius: 34, style: .continuous)
                    .fill(Color(hex: "F6FBFF"))
                    .overlay(
                        RoundedRectangle(cornerRadius: 34, style: .continuous)
                            .stroke(clamped >= 1 ? Color(hex: "27B36A") : Color(hex: "CDEBFF"), lineWidth: 2)
                    )
                    .shadow(color: (clamped >= 1 ? Color(hex: "27B36A") : Color(hex: "159BFF")).opacity(clamped >= 1 ? 0.20 : 0.10), radius: 18, x: 0, y: 10)

                GeometryReader { proxy in
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 31, style: .continuous)
                            .fill(Color.clear)
                        RoundedRectangle(cornerRadius: 31, style: .continuous)
                            .fill(LinearGradient(
                                colors: [Color(hex: "138EFF"), Color(hex: "72D9FF")],
                                startPoint: .bottom,
                                endPoint: .top
                            ))
                            .frame(height: max(10, proxy.size.height * CGFloat(clamped)))
                            .overlay(alignment: .top) {
                                Capsule()
                                    .fill(.white.opacity(0.38))
                                    .frame(width: proxy.size.width * 0.68, height: 6)
                                    .padding(.top, 9)
                            }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 31, style: .continuous))
                }
                .padding(6)

                VStack {
                    HStack {
                        Spacer()
                        Text(clamped >= 1 ? "满" : "\(Int(round(clamped * 100)))")
                            .font(.system(size: 10, weight: .black))
                            .foregroundStyle(clamped >= 1 ? Color(hex: "27B36A") : Color(hex: "159BFF"))
                            .padding(.horizontal, 7)
                            .frame(height: 20)
                            .background(.white.opacity(0.84))
                            .clipShape(Capsule())
                    }
                    Spacer()
                }
                .padding(10)

                VStack(spacing: 5) {
                    Image(systemName: "drop.fill")
                        .font(.system(size: 27, weight: .black))
                        .foregroundStyle(clamped > 0.52 ? .white : Color(hex: "159BFF"))
                        .accessibilityHidden(true)
                    Text("\(Int(round(clamped * 100)))%")
                        .font(.system(size: 22, weight: .black))
                        .foregroundStyle(clamped > 0.52 ? .white : Color(hex: "159BFF"))
                        .monospacedDigit()
                    Text("补水")
                        .font(.system(size: 10, weight: .black))
                        .foregroundStyle((clamped > 0.52 ? Color.white : Color(hex: "159BFF")).opacity(0.78))
                }

                VStack(spacing: 18) {
                    ForEach(0..<4, id: \.self) { _ in
                        Capsule()
                            .fill(Color.white.opacity(0.42))
                            .frame(width: 22, height: 2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, 11)
                .accessibilityHidden(true)
            }
            .frame(width: 128, height: 166)
        }
        .frame(width: 142, height: 186)
        .shadow(color: Color(hex: "159BFF").opacity(0.13), radius: 20, x: 0, y: 12)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("饮水进度 \(Int(round(clamped * 100)))%")
    }

    private func waterHeroStat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .black))
                .foregroundStyle(Color(hex: "8E949E"))
            Text(value)
                .font(.system(size: 15, weight: .black))
                .foregroundStyle(Color(hex: "111318"))
                .lineLimit(1)
                .minimumScaleFactor(0.76)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(hex: "F7F8FA"))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var quickAmountRow: some View {
        HStack(spacing: 10) {
            ForEach([(150, "小杯"), (250, "常用"), (350, "大杯"), (500, "水瓶")], id: \.0) { amount, label in
                let isPrimary = amount == 250
                Button {
                    Task { await logDrink(amount: Double(amount), type: "water") }
                } label: {
                    VStack(spacing: 6) {
                        Image(systemName: "drop.fill")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(isPrimary ? .white : Color(hex: "159BFF"))
                            .accessibilityHidden(true)
                        Text("+\(amount)毫升")
                            .font(.system(size: 14, weight: .black))
                            .foregroundStyle(isPrimary ? .white : Color(hex: "111318"))
                        Text(label)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(isPrimary ? .white.opacity(0.78) : Color(hex: "8E949E"))
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 74)
                    .background(
                        isPrimary
                        ? LinearGradient(colors: [Color(hex: "159BFF"), Color(hex: "56C7FF")], startPoint: .topLeading, endPoint: .bottomTrailing)
                        : LinearGradient(colors: [.white, .white], startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .shadow(color: (isPrimary ? Color(hex: "159BFF") : .black).opacity(isPrimary ? 0.18 : 0.045), radius: 16, x: 0, y: 8)
                }
                .buttonStyle(.plain)
                .disabled(!busyDrink.isEmpty)
            }
        }
    }

    private var hydrationMetricStrip: some View {
        HStack(spacing: 10) {
            waterMetricTile("剩余", "\(Int(max(0, goalMl - currentMl)))毫升", "flag.fill", Color(hex: "159BFF"))
            waterMetricTile("有效", "\(Int(round(summary?.hydrationEffectiveMl ?? 0)))毫升", "checkmark.circle.fill", Color(hex: "111318"))
            waterMetricTile("目标", "\(Int(round(goalMl)))毫升", "target", Color(hex: "6D7480"))
        }
    }

    private var drinkBreakdownCard: some View {
        let rows = drinkSummaryRows
        let totalEffective = max(1, rows.reduce(0) { $0 + $1.effectiveMl })
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("饮品构成")
                        .font(.system(size: 20, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                    Text("不同饮品按补水系数计入目标")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color(hex: "8E949E"))
                }
                Spacer()
                Text("\(Int(round(pureWaterShare)))% 水")
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(Color(hex: "159BFF"))
                    .padding(.horizontal, 11)
                    .frame(height: 30)
                    .background(Color(hex: "F2F4F7"))
                    .clipShape(Capsule())
            }

            if rows.isEmpty {
                Text("\(selectedDateLabel)先加一杯饮品，我会按类型拆分补水、咖啡因、糖和热量。")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color(hex: "8E949E"))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(Color(hex: "F7F8FA"))
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            } else {
                HStack(spacing: 4) {
                    ForEach(rows) { row in
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(row.color)
                            .frame(maxWidth: .infinity)
                            .frame(height: 12)
                            .layoutPriority(max(0.08, row.effectiveMl / totalEffective))
                    }
                }
                .clipShape(Capsule())
                .background(Color(hex: "F2F4F7"))
                .clipShape(Capsule())

                VStack(spacing: 10) {
                    ForEach(rows.prefix(5)) { row in
                        drinkBreakdownRow(row, totalEffective: totalEffective)
                    }
                }
            }
        }
        .padding(16)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .shadow(color: .black.opacity(0.035), radius: 14, x: 0, y: 8)
    }

    private var hydrationPaceCard: some View {
        let periods = Self.hydrationPeriods
        let perPeriodGoal = max(1, goalMl / Double(periods.count))
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(selectedDateLabel)节奏")
                        .font(.system(size: 20, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                    Text("按时间分布看饮水是否集中")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color(hex: "8E949E"))
                }
                Spacer()
                Text("\(summary?.drinkCount ?? logs.count)次")
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(Color(hex: "159BFF"))
                    .padding(.horizontal, 11)
                    .frame(height: 30)
                    .background(Color(hex: "F2F4F7"))
                    .clipShape(Capsule())
            }

            HStack(alignment: .bottom, spacing: 10) {
                ForEach(periods) { period in
                    let amount = hydrationAmount(in: period)
                    let pct = min(1, max(0, amount / perPeriodGoal))
                    VStack(spacing: 8) {
                        ZStack(alignment: .bottom) {
                            RoundedRectangle(cornerRadius: 15, style: .continuous)
                                .fill(Color(hex: "EDF7FF"))
                            RoundedRectangle(cornerRadius: 15, style: .continuous)
                                .fill(LinearGradient(
                                    colors: [Color(hex: "159BFF"), Color(hex: "70D6FF")],
                                    startPoint: .bottom,
                                    endPoint: .top
                                ))
                                .frame(height: 18 + 74 * CGFloat(pct))
                        }
                        .frame(height: 96)
                        .overlay(alignment: .top) {
                            Image(systemName: period.icon)
                                .font(.system(size: 13, weight: .black))
                                .foregroundStyle(pct > 0.25 ? .white : Color(hex: "159BFF"))
                                .padding(.top, 10)
                                .accessibilityHidden(true)
                        }

                        VStack(spacing: 2) {
                            Text(period.title)
                                .font(.system(size: 12, weight: .black))
                                .foregroundStyle(Color(hex: "111318"))
                            Text("\(Int(round(amount)))毫升")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Color(hex: "8E949E"))
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }

            Text(hydrationPaceMessage)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color(hex: "5A6B82"))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color(hex: "F7F8FA"))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .padding(16)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .shadow(color: .black.opacity(0.035), radius: 14, x: 0, y: 8)
    }

    private var hydrationTimeline: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("饮水时间线")
                    .font(.system(size: 18, weight: .black))
                    .foregroundStyle(Color(hex: "111318"))
                Spacer()
                Text("\(logs.count) 条记录")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color(hex: "8E949E"))
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color(hex: "E8F5FF"))
                        .frame(height: 12)
                    Capsule()
                        .fill(LinearGradient(
                            colors: [Color(hex: "159BFF"), Color(hex: "65D0FF")],
                            startPoint: .leading,
                            endPoint: .trailing
                        ))
                        .frame(width: proxy.size.width * CGFloat(progress), height: 12)
                    HStack(spacing: 0) {
                        ForEach(0..<6, id: \.self) { index in
                            Circle()
                                .fill(index == 0 || Double(index) / 5.0 <= progress ? Color.white : Color(hex: "D9EDFF"))
                                .frame(width: 7, height: 7)
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
            .frame(height: 14)
            HStack {
                Text("0 毫升")
                Spacer()
                Text("\(Int(round(goalMl))) 毫升")
            }
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(Color(hex: "8E949E"))
        }
        .padding(16)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: .black.opacity(0.035), radius: 14, x: 0, y: 8)
    }

    private var weeklyHydrationChart: some View {
        let rows = weeklyHydrationRows
        let maxValue = max(goalMl, rows.map(\.effectiveMl).max() ?? goalMl, 1)
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("7天趋势")
                        .font(.system(size: 20, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                    Text("按有效补水量统计，目标 \(Int(round(goalMl))) 毫升")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color(hex: "8E949E"))
                }
                Spacer()
                Text("达标 \(weeklyReachedDays)/7")
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(weeklyReachedDays > 0 ? Color(hex: "159BFF") : Color(hex: "8E949E"))
                    .padding(.horizontal, 11)
                    .frame(height: 30)
                    .background(Color(hex: "F2F8FF"))
                    .clipShape(Capsule())
            }

            HStack(alignment: .bottom, spacing: 9) {
                ForEach(rows) { row in
                    VStack(spacing: 7) {
                        Text(row.effectiveMl > 0 ? "\(Int(round(row.effectiveMl)))" : "--")
                            .font(.system(size: 9, weight: .black))
                            .foregroundStyle(row.isSelected ? Color(hex: "111318") : Color(hex: "9BA2AE"))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        ZStack(alignment: .bottom) {
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(Color(hex: "EEF3F8"))
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(LinearGradient(
                                    colors: row.reachedGoal
                                        ? [Color(hex: "27B36A"), Color(hex: "7DE4AA")]
                                        : [Color(hex: "159BFF"), Color(hex: "74D7FF")],
                                    startPoint: .bottom,
                                    endPoint: .top
                                ))
                                .frame(height: max(8, 86 * CGFloat(row.effectiveMl / maxValue)))
                        }
                        .frame(height: 86)
                        .overlay(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .stroke(row.isSelected ? Color(hex: "159BFF") : Color.clear, lineWidth: 2)
                        )
                        Text(row.weekdayLabel)
                            .font(.system(size: 10, weight: .black))
                            .foregroundStyle(row.isSelected ? Color(hex: "159BFF") : Color(hex: "8E949E"))
                        Text(row.dayLabel)
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Color(hex: "B0B6C0"))
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(16)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: .black.opacity(0.035), radius: 14, x: 0, y: 8)
    }

    private var drinkTypeGrid: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("饮品")
                    .font(.system(size: 20, weight: .black))
                    .foregroundStyle(Color(hex: "111318"))
                Spacer()
                Button {
                    showCustomDrinkEditor = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus")
                        Text("自定义")
                    }
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(Color(hex: "159BFF"))
                    .padding(.horizontal, 12)
                    .frame(height: 34)
                    .background(Color(hex: "F2F4F7"))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                ForEach(displayPresets.prefix(9)) { preset in
                    Button {
                        selectedPreset = preset
                    } label: {
                        VStack(spacing: 8) {
                            Image(systemName: symbolName(for: preset))
                                .font(.system(size: 23, weight: .semibold))
                                .foregroundStyle(Color(hex: colorHex(forDrinkType: preset.drinkType)))
                                .frame(width: 48, height: 48)
                                .background(Color(hex: colorHex(forDrinkType: preset.drinkType)).opacity(0.12))
                                .clipShape(Circle())
                            Text(displayName(forDrinkType: preset.drinkType, fallback: preset.name))
                                .font(.system(size: 12, weight: .black))
                                .foregroundStyle(Color(hex: "111318"))
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                            Text("\(Int(round(preset.defaultAmountMl))) 毫升")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Color(hex: "8E949E"))
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 114)
                        .background(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .shadow(color: .black.opacity(0.04), radius: 16, x: 0, y: 8)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var hydrationInsights: some View {
        HStack(spacing: 10) {
            insightTile("咖啡因", "\(Int(round(summary?.caffeineMg ?? 0)))毫克", Color(hex: "6D7480"), "cup.and.saucer.fill")
            insightTile("饮品糖", "\(Int(round(summary?.sugarG ?? 0)))克", Color(hex: "6D7480"), "cube.fill")
            insightTile("记录", "\(summary?.drinkCount ?? logs.count)", Color(hex: "111318"), "list.bullet")
        }
    }

    private var hydrationHistorySummary: some View {
        let pureWaterMl = weeklyLogs
            .filter { $0.drinkType == "water" || $0.drinkType == "sparkling_water" }
            .reduce(0) { $0 + $1.effectiveMl }
        let weeklyTotal = weeklyHydrationRows.reduce(0) { $0 + $1.effectiveMl }
        let waterShare = weeklyTotal <= 0 ? 0 : min(100, max(0, pureWaterMl / weeklyTotal * 100))
        let bestDay = weeklyBestDay
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("历史")
                    .font(.system(size: 20, weight: .black))
                    .foregroundStyle(Color(hex: "111318"))
                Spacer()
                Text(selectedDateLabel)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color(hex: "8E949E"))
            }
            HStack(spacing: 10) {
                insightTile("7日平均", "\(Int(round(weeklyAverageMl)))毫升", Color(hex: "159BFF"), "drop.fill")
                insightTile("水占比", "\(Int(round(waterShare)))%", Color(hex: "111318"), "chart.pie.fill")
                insightTile("最好一天", bestDay.map { "\(Int(round($0.effectiveMl)))毫升" } ?? "--", Color(hex: "6D7480"), "clock.fill")
            }
            if weeklyLogs.isEmpty {
                Text("先加一杯水，7 天趋势和达标天数会自动出现。")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color(hex: "8E949E"))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(Color(hex: "F7F8FA"))
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        }
        .padding(16)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: .black.opacity(0.035), radius: 14, x: 0, y: 8)
    }

    private var todayLogs: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(selectedDateLabel)
                    .font(.system(size: 20, weight: .black))
                    .foregroundStyle(Color(hex: "111318"))
                Spacer()
                Text("\(logs.count) 条")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color(hex: "8E949E"))
                if !logs.isEmpty {
                    Button {
                        Task { await clearTodayLogs() }
                    } label: {
                        if clearingToday {
                            ProgressView()
                                .tint(Color(hex: "EF4444"))
                        } else {
                            Text("清空")
                                .font(.system(size: 12, weight: .black))
                                .foregroundStyle(Color(hex: "EF4444"))
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(clearingToday || !deletingId.isEmpty)
                    .accessibilityLabel("清空\(selectedDateLabel)饮水记录")
                }
            }
            if logs.isEmpty {
                Text("先加一杯水")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color(hex: "8E949E"))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            } else {
                ForEach(logs.prefix(8)) { log in
                    HStack(spacing: 12) {
                        Image(systemName: symbolName(forDrinkType: log.drinkType))
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(Color(hex: "159BFF"))
                            .frame(width: 42, height: 42)
                            .background(Color(hex: "F2F4F7"))
                            .clipShape(Circle())
                        VStack(alignment: .leading, spacing: 3) {
                            Text(displayName(forDrinkType: log.drinkType))
                                .font(.system(size: 14, weight: .black))
                                .foregroundStyle(Color(hex: "111318"))
                            Text("\(Int(round(log.amountMl))) 毫升 · 有效 \(Int(round(log.effectiveMl))) 毫升")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(Color(hex: "8E949E"))
                        }
                        Spacer()
                        Button {
                            Task { await deleteLog(log.id) }
                        } label: {
                            if deletingId == log.id {
                                ProgressView().tint(Color(hex: "159BFF"))
                            } else {
                                Image(systemName: "minus.circle.fill")
                                    .font(.system(size: 22, weight: .bold))
                                    .foregroundStyle(Color(hex: "C9D3DF"))
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(13)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                }
            }
        }
    }

    private func insightTile(_ label: String, _ value: String, _ color: Color, _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .black))
                .foregroundStyle(color)
                .accessibilityHidden(true)
            Text(value)
                .font(.system(size: 19, weight: .black))
                .foregroundStyle(Color(hex: "111318"))
            Text(label)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color(hex: "8E949E"))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.035), radius: 14, x: 0, y: 8)
    }

    private func waterMetricTile(_ label: String, _ value: String, _ icon: String, _ color: Color) -> some View {
        VStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .black))
                .foregroundStyle(color)
                .frame(width: 28, height: 28)
                .background(color.opacity(0.12))
                .clipShape(Circle())
                .accessibilityHidden(true)
            Text(value)
                .font(.system(size: 15, weight: .black))
                .foregroundStyle(Color(hex: "111318"))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color(hex: "8E949E"))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Color(hex: "F7F8FA"))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func drinkBreakdownRow(_ row: HydrationDrinkSummary, totalEffective: Double) -> some View {
        let share = totalEffective <= 0 ? 0 : row.effectiveMl / totalEffective
        return HStack(spacing: 12) {
            Image(systemName: symbolName(forDrinkType: row.drinkType))
                .font(.system(size: 17, weight: .black))
                .foregroundStyle(row.color)
                .frame(width: 40, height: 40)
                .background(row.color.opacity(0.12))
                .clipShape(Circle())
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(row.name)
                        .font(.system(size: 14, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                        .lineLimit(1)
                    Text("\(row.count)次")
                        .font(.system(size: 10, weight: .black))
                        .foregroundStyle(Color(hex: "8E949E"))
                        .padding(.horizontal, 7)
                        .frame(height: 20)
                        .background(Color(hex: "F1F6FB"))
                        .clipShape(Capsule())
                    Spacer()
                    Text("\(Int(round(share * 100)))%")
                        .font(.system(size: 13, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                }

                HStack(spacing: 8) {
                    Text("\(Int(round(row.amountMl)))毫升")
                    Text("有效 \(Int(round(row.effectiveMl)))毫升")
                    Text("补水力 \(Int(round(row.hydrationFactor * 100)))%")
                }
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color(hex: "8E949E"))
                .lineLimit(1)
                .minimumScaleFactor(0.72)

                if row.caffeineMg > 0 || row.sugarG > 0 || row.calories > 0 {
                    HStack(spacing: 6) {
                        if row.caffeineMg > 0 {
                            miniRiskPill("咖啡因 \(Int(round(row.caffeineMg)))毫克", color: Color(hex: "6D7480"))
                        }
                        if row.sugarG > 0 {
                            miniRiskPill("糖 \(Int(round(row.sugarG)))克", color: Color(hex: "6D7480"))
                        }
                        if row.calories > 0 {
                            miniRiskPill("\(Int(round(row.calories)))千卡", color: Color(hex: "6D7480"))
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(Color(hex: "F7F8FA"))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func miniRiskPill(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .black))
            .foregroundStyle(color)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(color.opacity(0.10))
            .clipShape(Capsule())
    }

    private var hydrationPaceMessage: String {
        if logs.isEmpty {
            return "先记录一杯水，我会整理出\(selectedDateLabel)的饮水节奏。"
        }
        let periods = Self.hydrationPeriods
        let maxPeriod = periods.max { hydrationAmount(in: $0) < hydrationAmount(in: $1) }
        guard let maxPeriod else {
            return "\(selectedDateLabel)饮水节奏平稳，继续保持少量多次。"
        }
        let maxAmount = hydrationAmount(in: maxPeriod)
        if maxAmount >= currentMl * 0.62, currentMl > 0 {
            return "\(maxPeriod.title)饮水偏集中，下一杯可以提前一点。"
        }
        return "饮水分布较均匀，继续保持少量多次。"
    }

    private func hydrationAmount(in period: HydrationPeriod) -> Double {
        logs.reduce(0) { total, log in
            guard let hour = loggedHour(log), period.contains(hour: hour) else { return total }
            return total + log.effectiveMl
        }
    }

    private var drinkSummaryRows: [HydrationDrinkSummary] {
        let grouped = Dictionary(grouping: logs, by: \.drinkType)
        return grouped.map { type, items in
            let preset = presets.first { $0.drinkType == type || $0.id == type }
                ?? Self.fallbackPresets.first { $0.drinkType == type || $0.id == type }
            let amount = items.reduce(0) { $0 + $1.amountMl }
            let effective = items.reduce(0) { $0 + $1.effectiveMl }
            let factor = amount <= 0 ? (preset?.hydrationFactor ?? 1) : effective / amount
            return HydrationDrinkSummary(
                drinkType: type,
                name: displayName(forDrinkType: type),
                count: items.count,
                amountMl: amount,
                effectiveMl: effective,
                hydrationFactor: factor,
                caffeineMg: items.reduce(0) { $0 + $1.caffeineMg },
                sugarG: items.reduce(0) { $0 + $1.sugarG },
                calories: items.reduce(0) { $0 + $1.calories },
                color: Color(hex: colorHex(forDrinkType: type))
            )
        }
        .sorted {
            if $0.effectiveMl == $1.effectiveMl {
                return $0.name < $1.name
            }
            return $0.effectiveMl > $1.effectiveMl
        }
    }

    private var pureWaterShare: Double {
        let total = max(0, logs.reduce(0) { $0 + $1.effectiveMl })
        guard total > 0 else { return 0 }
        let pure = logs
            .filter { $0.drinkType == "water" || $0.drinkType == "sparkling_water" }
            .reduce(0) { $0 + $1.effectiveMl }
        return min(100, max(0, pure / total * 100))
    }

    private func loggedHour(_ log: HydrationLog) -> Int? {
        guard let value = log.loggedAt, let date = Self.parseLogDate(value) else { return nil }
        return Calendar.current.component(.hour, from: date)
    }

    private static func parseLogDate(_ value: String) -> Date? {
        let isoWithFraction = ISO8601DateFormatter()
        isoWithFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = isoWithFraction.date(from: value) {
            return date
        }

        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: value) {
            return date
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        for format in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss.SSS"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) {
                return date
            }
        }
        return nil
    }

    private static func dateKeyFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }

    private static func dateKeyFromLogTimestamp(_ value: String) -> String? {
        guard let date = parseLogDate(value) else { return nil }
        return dateKeyFormatter().string(from: date)
    }

    private static func shortWeekdayLabel(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "E"
        return formatter.string(from: date)
    }

    private static func shortDateLabel(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M/d"
        return formatter.string(from: date)
    }

    private static let hydrationPeriods: [HydrationPeriod] = [
        HydrationPeriod(title: "上午", startHour: 5, endHour: 11, icon: "sunrise.fill"),
        HydrationPeriod(title: "中午", startHour: 11, endHour: 15, icon: "sun.max.fill"),
        HydrationPeriod(title: "下午", startHour: 15, endHour: 19, icon: "cloud.sun.fill"),
        HydrationPeriod(title: "晚上", startHour: 19, endHour: 24, icon: "moon.fill")
    ]

    private func loadHydration(force: Bool = false) async {
        let dateKey = hydrationDateKey
        if !force, HydrationRuntimeCache.isFresh(dateKey: dateKey) {
            summary = HydrationRuntimeCache.summary(dateKey: dateKey) ?? summary
            logs = HydrationRuntimeCache.logs(dateKey: dateKey)
            weeklyLogs = HydrationRuntimeCache.weeklyLogs(dateKey: dateKey)
            if !HydrationRuntimeCache.presets().isEmpty {
                presets = HydrationRuntimeCache.presets()
            }
            if !HydrationRuntimeCache.reminders().isEmpty {
                reminders = HydrationRuntimeCache.reminders()
            }
            loading = false
            return
        }
        loading = summary == nil && logs.isEmpty
        errorMessage = ""
        defer { loading = false }
        async let nextSummary = APIClient.shared.getHydrationSummary(date: logDate)
        async let nextLogs = APIClient.shared.getHydration(date: logDate)
        async let nextWeeklyLogs = APIClient.shared.getHydration(date: logDate, days: 7)
        async let nextPresets = APIClient.shared.getDrinkPresets()
        async let nextReminders = APIClient.shared.getReminders()
        do {
            summary = try await nextSummary
            logs = (try? await nextLogs) ?? logs
            weeklyLogs = (try? await nextWeeklyLogs) ?? logs
            presets = (try? await nextPresets) ?? presets
            reminders = (try? await nextReminders) ?? reminders
            HydrationRuntimeCache.save(
                dateKey: dateKey,
                summary: summary,
                logs: logs,
                weeklyLogs: weeklyLogs,
                presets: presets,
                reminders: reminders
            )
        } catch {
            errorMessage = hydrationFriendlyError(error, fallback: "饮水数据暂时没加载出来，稍后再刷新一次。")
        }
    }

    private func logDrink(amount: Double, type: String) async {
        guard busyDrink.isEmpty else { return }
        busyDrink = type
        errorMessage = ""
        defer { busyDrink = "" }
        do {
            _ = try await APIClient.shared.addHydration(amountMl: amount, drinkType: type, date: logDate)
            onChanged()
            await loadHydration(force: true)
        } catch {
            errorMessage = hydrationFriendlyError(error, fallback: "这杯饮品还没记上，检查网络后再点记录饮品。")
        }
    }

    private func deleteLog(_ id: String) async {
        guard deletingId.isEmpty else { return }
        deletingId = id
        errorMessage = ""
        defer { deletingId = "" }
        do {
            let response = try await APIClient.shared.deleteHydration(ids: [id], date: logDate)
            if let next = response.summary { summary = next }
            logs.removeAll { $0.id == id }
            weeklyLogs.removeAll { $0.id == id }
            HydrationRuntimeCache.save(dateKey: hydrationDateKey, summary: summary, logs: logs, weeklyLogs: weeklyLogs)
            onChanged()
        } catch {
            errorMessage = hydrationFriendlyError(error, fallback: "这条饮品暂时没删掉，返回后再删一次。")
        }
    }

    private func clearTodayLogs() async {
        guard !clearingToday, !logs.isEmpty else { return }
        clearingToday = true
        errorMessage = ""
        defer { clearingToday = false }
        do {
            let response = try await APIClient.shared.deleteHydration(ids: logs.map(\.id), date: logDate)
            if let next = response.summary {
                summary = next
            } else {
                summary = HydrationSummary(
                    date: summary?.date,
                    hydrationMl: 0,
                    hydrationEffectiveMl: 0,
                    hydrationGoalMl: goalMl,
                    caffeineMg: 0,
                    alcoholG: 0,
                    sugarG: 0,
                    calories: 0,
                    drinkCount: 0
                )
            }
            weeklyLogs.removeAll { ($0.date ?? $0.loggedAt.flatMap(Self.dateKeyFromLogTimestamp) ?? hydrationDateKey) == hydrationDateKey }
            logs = []
            HydrationRuntimeCache.save(dateKey: hydrationDateKey, summary: summary, logs: logs, weeklyLogs: weeklyLogs)
            onChanged()
        } catch {
            errorMessage = hydrationFriendlyError(error, fallback: "今天的饮品暂时没清空，刷新后再清空。")
        }
    }

    private func addCustomPreset(name: String, amount: Double, factor: Double, caffeine: Double, sugar: Double, calories: Double) async {
        errorMessage = ""
        do {
            let preset = try await APIClient.shared.addDrinkPreset(
                name: name,
                defaultAmountMl: amount,
                hydrationFactor: factor,
                caffeineMg: caffeine,
                sugarG: sugar,
                calories: calories
            )
            presets.append(preset)
            selectedPreset = preset
            HydrationRuntimeCache.save(dateKey: hydrationDateKey, summary: summary, logs: logs, presets: presets)
            await loadHydration(force: true)
        } catch {
            errorMessage = hydrationFriendlyError(error, fallback: "这个常喝饮品暂时没保存，检查网络后再点保存。")
        }
    }

    private func saveHydrationGoal(_ goal: Double, reminderEnabled: Bool, reminderTime: String, reminderIntervalMinutes: Int) async -> String? {
        errorMessage = ""
        do {
            let settings = try await APIClient.shared.saveHydrationSettings(goalMl: goal)
            let existing = hydrationReminder
            let hydration = ReminderItem(
                id: existing?.id ?? "hydration_daily_goal",
                mealType: "hydration",
                time: reminderTime,
                enabled: reminderEnabled,
                category: "hydration",
                title: "补充饮水",
                targetId: "daily_water_goal",
                daysOfWeek: existing?.daysOfWeek.isEmpty == false ? existing?.daysOfWeek ?? "" : "1,2,3,4,5,6,7",
                intervalMinutes: reminderIntervalMinutes
            )
            let preserved = reminders.filter { item in
                item.category != "hydration" && item.mealType != "hydration"
            }
            reminders = try await APIClient.shared.saveReminders(preserved + [hydration])
            let nextGoal = settings.hydrationGoalMl
            summary = HydrationSummary(
                date: summary?.date,
                hydrationMl: summary?.hydrationMl ?? 0,
                hydrationEffectiveMl: summary?.hydrationEffectiveMl ?? 0,
                hydrationGoalMl: nextGoal,
                caffeineMg: summary?.caffeineMg ?? 0,
                alcoholG: summary?.alcoholG ?? 0,
                sugarG: summary?.sugarG ?? 0,
                calories: summary?.calories ?? 0,
                drinkCount: summary?.drinkCount ?? logs.count
            )
            onChanged()
            HydrationRuntimeCache.save(dateKey: hydrationDateKey, summary: summary, logs: logs, reminders: reminders)
            await loadHydration(force: true)
            return nil
        } catch {
            let friendly = hydrationFriendlyError(error, fallback: "饮水目标暂时没保存，检查网络后再点保存。")
            errorMessage = friendly
            return friendly
        }
    }

    private func symbolName(for preset: DrinkPreset) -> String {
        symbolName(forDrinkType: preset.drinkType)
    }

    private func symbolName(forDrinkType type: String) -> String {
        switch type {
        case "tea": return "leaf.fill"
        case "coffee", "latte": return "cup.and.saucer.fill"
        case "milk": return "mug.fill"
        case "juice": return "takeoutbag.and.cup.and.straw.fill"
        case "energy_drink": return "bolt.fill"
        case "alcohol": return "wineglass.fill"
        case "sparkling_water": return "bubbles.and.sparkles"
        default: return "drop.fill"
        }
    }

    private func displayName(forDrinkType type: String) -> String {
        displayName(forDrinkType: type, fallback: nil)
    }

    private func displayName(forDrinkType type: String, fallback: String?) -> String {
        switch type {
        case "water": return "水"
        case "sparkling_water": return "气泡水"
        case "tea": return "茶"
        case "coffee": return "咖啡"
        case "latte": return "拿铁"
        case "milk": return "牛奶"
        case "juice": return "果汁"
        case "energy_drink": return "能量饮料"
        case "alcohol": return "酒精饮品"
        default:
            return fallback
                ?? presets.first { $0.drinkType == type || $0.id == type }?.name
                ?? Self.fallbackPresets.first { $0.drinkType == type || $0.id == type }?.name
                ?? type
        }
    }

    private func colorHex(forDrinkType type: String) -> String {
        switch type {
        case "tea": return "111318"
        case "coffee", "latte": return "6D7480"
        case "milk": return "B8C7D9"
        case "juice": return "9AA3AF"
        case "energy_drink": return "111318"
        case "alcohol": return "6D7480"
        case "sparkling_water": return "159BFF"
        default: return "159BFF"
        }
    }

    private static let fallbackPresets: [DrinkPreset] = [
        DrinkPreset(id: "water", drinkType: "water", name: "水", defaultAmountMl: 250, hydrationFactor: 1, caffeineMg: 0, alcoholG: 0, sugarG: 0, calories: 0, color: "#159BFF", icon: "drop", custom: false),
        DrinkPreset(id: "sparkling_water", drinkType: "sparkling_water", name: "气泡水", defaultAmountMl: 250, hydrationFactor: 1, caffeineMg: 0, alcoholG: 0, sugarG: 0, calories: 0, color: "#159BFF", icon: "bubbles", custom: false),
        DrinkPreset(id: "tea", drinkType: "tea", name: "茶", defaultAmountMl: 240, hydrationFactor: 0.9, caffeineMg: 35, alcoholG: 0, sugarG: 0, calories: 0, color: "#111318", icon: "leaf", custom: false),
        DrinkPreset(id: "coffee", drinkType: "coffee", name: "咖啡", defaultAmountMl: 240, hydrationFactor: 0.85, caffeineMg: 95, alcoholG: 0, sugarG: 0, calories: 0, color: "#6D7480", icon: "coffee", custom: false),
        DrinkPreset(id: "latte", drinkType: "latte", name: "拿铁", defaultAmountMl: 300, hydrationFactor: 0.85, caffeineMg: 75, alcoholG: 0, sugarG: 10, calories: 150, color: "#6D7480", icon: "coffee", custom: false),
        DrinkPreset(id: "milk", drinkType: "milk", name: "牛奶", defaultAmountMl: 250, hydrationFactor: 0.9, caffeineMg: 0, alcoholG: 0, sugarG: 12, calories: 130, color: "#B8C7D9", icon: "milk", custom: false),
        DrinkPreset(id: "juice", drinkType: "juice", name: "果汁", defaultAmountMl: 250, hydrationFactor: 0.8, caffeineMg: 0, alcoholG: 0, sugarG: 24, calories: 110, color: "#9AA3AF", icon: "juice", custom: false),
        DrinkPreset(id: "energy_drink", drinkType: "energy_drink", name: "能量饮料", defaultAmountMl: 250, hydrationFactor: 0.75, caffeineMg: 80, alcoholG: 0, sugarG: 27, calories: 115, color: "#111318", icon: "bolt", custom: false),
        DrinkPreset(id: "alcohol", drinkType: "alcohol", name: "酒精饮品", defaultAmountMl: 330, hydrationFactor: 0.45, caffeineMg: 0, alcoholG: 13, sugarG: 3, calories: 140, color: "#6D7480", icon: "wineglass", custom: false),
    ]
}

private func hydrationFriendlyError(_ error: Error, fallback: String) -> String {
    let raw = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !raw.isEmpty else { return fallback }
    let lowercased = raw.lowercased()
    if lowercased.contains("could not connect")
        || lowercased.contains("connection")
        || lowercased.contains("timed out")
        || raw.contains("连接不到")
        || raw.contains("无法连接")
        || raw.contains("网络") {
        return "现在没连上，这次饮水还没保存；检查网络后再点保存。"
    }
    if lowercased.contains("not found") || raw.contains("404") {
        return "这条饮品记录暂时找不到，刷新饮水列表。"
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

private struct HydrationPeriod: Identifiable {
    let title: String
    let startHour: Int
    let endHour: Int
    let icon: String

    var id: String { "\(startHour)-\(endHour)-\(title)" }

    func contains(hour: Int) -> Bool {
        hour >= startHour && hour < endHour
    }
}

private struct HydrationDrinkSummary: Identifiable {
    let drinkType: String
    let name: String
    let count: Int
    let amountMl: Double
    let effectiveMl: Double
    let hydrationFactor: Double
    let caffeineMg: Double
    let sugarG: Double
    let calories: Double
    let color: Color

    var id: String { drinkType }
}

private struct DrinkPresetDetailSheet: View {
    @Environment(\.dismiss) private var dismiss

    let preset: DrinkPreset
    let onLog: (Double, String) -> Void

    private var color: Color {
        Color(hex: colorHex(forDrinkType: preset.drinkType))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 14) {
                Image(systemName: symbolName(forDrinkType: preset.drinkType))
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(color)
                    .frame(width: 68, height: 68)
                    .background(.white)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(Color(hex: "E9EEF5"), lineWidth: 1))
                VStack(alignment: .leading, spacing: 5) {
                    Text(displayName(forDrinkType: preset.drinkType, fallback: preset.name))
                        .font(.system(size: 28, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                    Text("默认 \(Int(round(preset.defaultAmountMl))) 毫升 · 有效 \(Int(round(preset.defaultAmountMl * preset.hydrationFactor))) 毫升")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Color(hex: "8E949E"))
                }
                Spacer()
            }

            HStack(spacing: 10) {
                nutrientPill("咖啡因", "\(Int(round(preset.caffeineMg)))毫克")
                nutrientPill("糖", "\(Int(round(preset.sugarG)))克")
                nutrientPill("热量", "\(Int(round(preset.calories)))千卡")
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 2), spacing: 10) {
                ForEach([150, 250, 350, 500], id: \.self) { amount in
                    Button {
                        onLog(Double(amount), preset.drinkType)
                        dismiss()
                    } label: {
                        Text("+\(amount) 毫升")
                            .font(.system(size: 18, weight: .black))
                            .foregroundStyle(Color(hex: "111318"))
                            .frame(maxWidth: .infinity)
                            .frame(height: 58)
                            .background(Color(hex: "F2F4F7"))
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }

            Button {
                onLog(preset.defaultAmountMl, preset.drinkType)
                dismiss()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "plus")
                    Text("添加 \(Int(round(preset.defaultAmountMl))) 毫升")
                }
                .font(.system(size: 20, weight: .black))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 62)
                .background(Color(hex: "159BFF"))
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .shadow(color: Color(hex: "159BFF").opacity(0.22), radius: 16, x: 0, y: 9)
            }
            .buttonStyle(.plain)
        }
        .padding(24)
        .background(AppShellBackground())
    }

    private func nutrientPill(_ label: String, _ value: String) -> some View {
        VStack(spacing: 5) {
            Text(value)
                .font(.system(size: 17, weight: .black))
                .foregroundStyle(Color(hex: "111318"))
            Text(label)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color(hex: "8E949E"))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func displayName(forDrinkType type: String, fallback: String?) -> String {
        switch type {
        case "water": return "水"
        case "sparkling_water": return "气泡水"
        case "tea": return "茶"
        case "coffee": return "咖啡"
        case "latte": return "拿铁"
        case "milk": return "牛奶"
        case "juice": return "果汁"
        case "energy_drink": return "能量饮料"
        case "alcohol": return "酒精饮品"
        default: return fallback ?? "其他饮品"
        }
    }

    private func colorHex(forDrinkType type: String) -> String {
        switch type {
        case "water", "sparkling_water": return "159BFF"
        case "tea", "energy_drink": return "111318"
        case "coffee", "latte", "alcohol": return "6D7480"
        case "milk": return "B8C7D9"
        case "juice": return "9AA3AF"
        default: return "159BFF"
        }
    }

    private func symbolName(forDrinkType type: String) -> String {
        switch type {
        case "tea": return "leaf.fill"
        case "coffee", "latte": return "cup.and.saucer.fill"
        case "milk": return "mug.fill"
        case "juice": return "takeoutbag.and.cup.and.straw.fill"
        case "energy_drink": return "bolt.fill"
        case "alcohol": return "wineglass.fill"
        case "sparkling_water": return "bubbles.and.sparkles"
        default: return "drop.fill"
        }
    }
}

private struct CustomDrinkPresetSheet: View {
    @Environment(\.dismiss) private var dismiss

    let onSave: (String, Double, Double, Double, Double, Double) -> Void

    @State private var name = ""
    @State private var amount = 250.0
    @State private var factor = 1.0
    @State private var caffeine = 0.0
    @State private var sugar = 0.0
    @State private var calories = 0.0

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("自定义饮品")
                        .font(.system(size: 29, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                    Text("保存后会加入常用饮品列表，下次可一键记录。")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Color(hex: "8E949E"))
                }

                VStack(spacing: 14) {
                    TextField("饮品名称", text: $name)
                        .font(.system(size: 18, weight: .bold))
                        .padding(16)
                        .background(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                    sliderRow(title: "默认容量", value: $amount, range: 50...1000, step: 10, suffix: "毫升")
                    sliderRow(title: "有效饮水系数", value: $factor, range: 0.1...1.2, step: 0.05, suffix: "x")
                    sliderRow(title: "咖啡因", value: $caffeine, range: 0...300, step: 5, suffix: "毫克")
                    sliderRow(title: "糖", value: $sugar, range: 0...80, step: 1, suffix: "克")
                    sliderRow(title: "热量", value: $calories, range: 0...500, step: 5, suffix: "千卡")
                }

                Button {
                    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    onSave(trimmed, amount, factor, caffeine, sugar, calories)
                    dismiss()
                } label: {
                    Text("保存饮品")
                        .font(.system(size: 20, weight: .black))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 62)
                        .background(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color(hex: "B7C5D3") : Color(hex: "159BFF"))
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .shadow(color: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .clear : Color(hex: "159BFF").opacity(0.2), radius: 16, x: 0, y: 9)
                }
                .buttonStyle(.plain)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(24)
            .padding(.bottom, 24)
        }
        .background(AppShellBackground())
    }

    private func sliderRow(title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, suffix: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                    .font(.system(size: 15, weight: .black))
                    .foregroundStyle(Color(hex: "111318"))
                Spacer()
                Text(display(value.wrappedValue, suffix: suffix))
                    .font(.system(size: 15, weight: .black))
                    .foregroundStyle(Color(hex: "111318"))
            }
            Slider(value: value, in: range, step: step)
                .tint(Color(hex: "159BFF"))
        }
        .padding(16)
        .softCard(radius: 18)
    }

    private func display(_ value: Double, suffix: String) -> String {
        if suffix == "x" {
            return String(format: "%.2fx", value)
        }
        return "\(Int(round(value)))\(suffix)"
    }
}

private struct HydrationGoalSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss

    let currentGoalMl: Double
    let reminder: ReminderItem?
    let onSave: (Double, Bool, String, Int) async -> String?

    @State private var goalMl: Double
    @State private var reminderEnabled: Bool
    @State private var reminderTime: String
    @State private var reminderIntervalMinutes: Int
    @State private var isSaving = false
    @State private var saveError = ""

    private let reminderTimes = ["09:00", "11:00", "15:00", "20:00"]
    private let reminderIntervals = [30, 60, 90, 120]

    init(currentGoalMl: Double, reminder: ReminderItem?, onSave: @escaping (Double, Bool, String, Int) async -> String?) {
        self.currentGoalMl = currentGoalMl
        self.reminder = reminder
        self.onSave = onSave
        _goalMl = State(initialValue: min(6000, max(500, currentGoalMl)))
        _reminderEnabled = State(initialValue: reminder?.enabled ?? true)
        _reminderTime = State(initialValue: reminder?.time.isEmpty == false ? reminder?.time ?? "15:00" : "15:00")
        _reminderIntervalMinutes = State(initialValue: reminder?.intervalMinutes ?? 60)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 14) {
                Image(systemName: "drop.fill")
                    .font(.system(size: 27, weight: .black))
                    .foregroundStyle(Color(hex: "159BFF"))
                    .frame(width: 62, height: 62)
                    .background(.white)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(Color(hex: "E9EEF5"), lineWidth: 1))
                VStack(alignment: .leading, spacing: 5) {
                    Text("每日目标")
                        .font(.system(size: 29, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                    Text("首页、饮水页和今日状态分会一起更新")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Color(hex: "8E949E"))
                }
                Spacer()
            }

            VStack(spacing: 16) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(Int(round(goalMl)))")
                        .font(.system(size: 52, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                    Text("毫升")
                        .font(.system(size: 18, weight: .black))
                        .foregroundStyle(Color(hex: "8FA2B9"))
                }

                Slider(value: $goalMl, in: 500...6000, step: 50)
                    .tint(Color(hex: "159BFF"))

                HStack(spacing: 10) {
                    ForEach([1800, 2100, 2500, 3000], id: \.self) { amount in
                        Button {
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                                goalMl = Double(amount)
                            }
                        } label: {
                            Text("\(amount)")
                                .font(.system(size: 14, weight: .black))
                                .foregroundStyle(Int(round(goalMl)) == amount ? .white : Color(hex: "111318"))
                                .frame(maxWidth: .infinity)
                                .frame(height: 42)
                                .background(Int(round(goalMl)) == amount ? Color(hex: "159BFF") : Color(hex: "F2F4F7"))
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(18)
            .softCard(radius: 24)

            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    HStack(spacing: 10) {
                        Image(systemName: "bell.badge.fill")
                            .font(.system(size: 18, weight: .black))
                            .foregroundStyle(Color(hex: "159BFF"))
                        VStack(alignment: .leading, spacing: 3) {
                            Text("饮水提醒")
                                .font(.system(size: 16, weight: .black))
                                .foregroundStyle(Color(hex: "111318"))
                            Text(reminderEnabled ? "\(reminderTime) 开始，每 \(reminderIntervalMinutes) 分钟提醒" : "提醒已关闭")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(Color(hex: "8E949E"))
                        }
                    }
                    Spacer()
                    Toggle("", isOn: $reminderEnabled)
                        .labelsHidden()
                        .tint(Color(hex: "159BFF"))
                }

                HStack(spacing: 10) {
                    ForEach(reminderTimes, id: \.self) { time in
                        Button {
                            reminderTime = time
                            reminderEnabled = true
                        } label: {
                            Text(time)
                                .font(.system(size: 14, weight: .black))
                                .foregroundStyle(reminderTime == time && reminderEnabled ? .white : Color(hex: "111318"))
                                .frame(maxWidth: .infinity)
                                .frame(height: 42)
                                .background(reminderTime == time && reminderEnabled ? Color(hex: "159BFF") : Color(hex: "F2F4F7"))
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .opacity(reminderEnabled ? 1 : 0.48)

                VStack(alignment: .leading, spacing: 10) {
                    Text("提醒间隔")
                        .font(.system(size: 13, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                    HStack(spacing: 10) {
                        ForEach(reminderIntervals, id: \.self) { minutes in
                            Button {
                                reminderIntervalMinutes = minutes
                                reminderEnabled = true
                            } label: {
                                Text("\(minutes)分")
                                    .font(.system(size: 14, weight: .black))
                                    .foregroundStyle(reminderIntervalMinutes == minutes && reminderEnabled ? .white : Color(hex: "111318"))
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 42)
                                    .background(reminderIntervalMinutes == minutes && reminderEnabled ? Color(hex: "159BFF") : Color(hex: "F2F4F7"))
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .opacity(reminderEnabled ? 1 : 0.48)
            }
            .padding(18)
            .softCard(radius: 24)

            Button {
                Task {
                    guard !isSaving else { return }
                    isSaving = true
                    saveError = ""
                    let error = await onSave(goalMl, reminderEnabled, reminderTime, reminderIntervalMinutes)
                    isSaving = false
                    if let error, !error.isEmpty {
                        saveError = error
                    } else {
                        dismiss()
                    }
                }
            } label: {
                HStack(spacing: 10) {
                    if isSaving {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Image(systemName: "checkmark")
                        Text("保存目标")
                    }
                }
                .font(.system(size: 20, weight: .black))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 62)
                .background(Color(hex: "159BFF"))
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .shadow(color: Color(hex: "159BFF").opacity(isSaving ? 0 : 0.22), radius: 16, x: 0, y: 9)
            }
            .buttonStyle(.plain)
            .disabled(isSaving)

            if !saveError.isEmpty {
                Text(saveError)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color(hex: "DC2626"))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Color(hex: "FFF1F2"))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
        .padding(24)
        .background(AppShellBackground())
    }
}
