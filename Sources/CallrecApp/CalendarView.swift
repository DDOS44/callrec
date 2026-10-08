import CallrecCore
import SwiftUI

/// Middle column for the Calendar sidebar row: month summary, month grid, and the picked day's calls.
struct CalendarColumn: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                MonthSummaryBar(totals: model.monthSummary.totals)
                MonthNav()
                MonthGrid(month: model.monthSummary, weeks: CallCalendar.weeks(month: model.calendarMonth, calendar: .current))
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            Divider()
            CallListBody()
                .frame(minHeight: 110)
        }
        .navigationSplitViewColumnWidth(min: 420, ideal: 480, max: 600)
        .navigationTitle("Calendar")
    }
}

private struct MonthSummaryBar: View {
    let totals: CallCalendar.Stats

    var body: some View {
        HStack(spacing: 0) {
            stat("\(totals.calls)", "calls")
            stat("\(totals.connects)", "connects")
            stat("\(totals.booked)", "booked")
            stat(talk(totals.talk), "talk time")
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func talk(_ seconds: Double) -> String {
        let m = Int(seconds) / 60
        return m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m)m"
    }
}

private struct MonthNav: View {
    @EnvironmentObject var model: AppModel

    private static let title: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMMM yyyy"; return f
    }()

    var body: some View {
        HStack(spacing: 8) {
            Button { model.shiftMonth(by: -1) } label: { Image(systemName: "chevron.left") }
                .help("Previous month")
            Text(Self.title.string(from: model.calendarMonth)).font(.headline).frame(minWidth: 120)
            Button { model.shiftMonth(by: 1) } label: { Image(systemName: "chevron.right") }
                .help("Next month")
            Spacer()
            Button("Today") { model.showToday() }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
}

private struct MonthGrid: View {
    @EnvironmentObject var model: AppModel
    let month: CallCalendar.Month
    let weeks: [[CallCalendar.Cell]]

    private static let weekdays = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)
    private let todayKey = CallCalendar.key(Date(), calendar: .current)

    var body: some View {
        VStack(spacing: 4) {
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(Self.weekdays, id: \.self) { Text($0).font(.caption2).foregroundStyle(.secondary) }
            }
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(weeks.flatMap { $0 }) { cell in
                    if let key = cell.key, let number = cell.dayNumber {
                        DayCell(number: number, stats: month.days[key] ?? CallCalendar.Stats(), maxCalls: month.maxCalls,
                                isToday: key == todayKey, isSelected: key == model.calendarDay) {
                            model.pickCalendarDay(key)
                        }
                    } else {
                        Color.clear.frame(height: 54)
                    }
                }
            }
        }
    }
}

private struct DayCell: View {
    let number: Int
    let stats: CallCalendar.Stats
    let maxCalls: Int
    let isToday: Bool
    let isSelected: Bool
    let action: () -> Void

    private var level: Int { CallCalendar.intensity(calls: stats.calls, max: maxCalls) }

    private var fill: Color {
        switch level {
        case 0: return Color.secondary.opacity(0.08)
        case 1: return Color.accentColor.opacity(0.22)
        case 2: return Color.accentColor.opacity(0.42)
        case 3: return Color.accentColor.opacity(0.68)
        default: return Color.accentColor.opacity(0.92)
        }
    }

    private var ink: Color { level >= 3 ? .white : .primary }

    private var detail: String {
        guard stats.calls > 0 else { return "" }
        var bits = ["\(stats.connects) conn"]
        if stats.booked > 0 { bits.append("\(stats.booked) booked") }
        return bits.joined(separator: " · ")
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 2) {
                    Text("\(number)").font(.caption2.weight(isToday ? .bold : .regular)).monospacedDigit()
                    if stats.tests > 0 {
                        Image(systemName: "circle.dotted").font(.system(size: 8)).opacity(0.5)
                            .help("\(stats.tests) test call(s), not counted")
                    }
                    Spacer(minLength: 0)
                    if stats.calls > 0 { Text("\(stats.calls)").font(.callout.weight(.semibold)).monospacedDigit() }
                }
                Text(detail)
                    .font(.system(size: 9))
                    .lineLimit(2).minimumScaleFactor(0.8)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .foregroundStyle(ink)
            .padding(4)
            .frame(maxWidth: .infinity, minHeight: 54, maxHeight: 54, alignment: .topLeading)
            .background(fill, in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isSelected ? Color.accentColor : (isToday ? Color.secondary.opacity(0.6) : .clear),
                                  lineWidth: isSelected ? 2 : 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Day \(number), \(stats.calls) calls")
    }
}
