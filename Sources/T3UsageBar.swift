import AppKit
import SQLite3
import SwiftUI

enum Period: String, CaseIterable, Identifiable {
    case today = "今日"
    case week = "近 7 天"
    case month = "近 30 天"

    var id: Self { self }
    var days: Int {
        switch self {
        case .today: 1
        case .week: 7
        case .month: 30
        }
    }
}

enum Provider: String, CaseIterable, Identifiable {
    case codex, antigravity

    var id: Self { self }
    var name: String { self == .codex ? "GPT · Codex" : "Google · Antigravity" }
    var accent: Color { self == .codex ? .teal : .indigo }
    var featuredModels: [String] {
        switch self {
        case .codex: ["gpt-6.2-astra", "gpt-6.2-sol"]
        case .antigravity: ["gemini-4-neon", "gemini-4-carbon", "claude-opus-5-5"]
        }
    }
}

struct Tokens {
    var input: Int64 = 0
    var cached: Int64 = 0
    var output: Int64 = 0
    var measuredInput: Int64 = 0
    var turns: Int64 = 0

    var total: Int64 { input + output }
    var hitRate: Double? {
        guard measuredInput > 0 else { return nil }
        return Double(cached) / Double(measuredInput)
    }

    mutating func add(_ other: Self) {
        input += other.input
        cached += other.cached
        output += other.output
        measuredInput += other.measuredInput
        turns += other.turns
    }
}

struct UsageRow {
    let day: String
    let provider: Provider
    let model: String
    let tokens: Tokens
}

struct ModelUsage: Identifiable {
    let id: String
    let title: String?
    let tokens: Tokens

    var name: String {
        if let title, !title.isEmpty { return title }
        return switch id {
        case "gpt-6.2-astra": "GPT-6.2-Astra"
        case "gpt-6.2-sol": "GPT-6.2-Sol"
        case "gemini-4-neon": "Gemini 4 Neon"
        case "gemini-4-carbon": "Gemini 4 Carbon"
        case "claude-opus-5-5": "Claude Opus 5.5"
        default: id
        }
    }
}

struct Quota: Decodable, Identifiable {
    let id: String
    let kind: String
    let label: String
    let usedPercent: Double?
    let resetsAt: String?
    let approximateReset: Bool?

    var title: String {
        switch id {
        case "gemini-5h": "Gemini · 5 小时"
        case "gemini-weekly": "Gemini · 周额度"
        case "gemini-argon-wtu-weekly": "Gemini 4 Argon · 周额度"
        case "3p-5h": "Claude / GPT · 5 小时"
        case "3p-weekly": "Claude / GPT · 周额度"
        default:
            switch label {
            case "Weekly": "周额度"
            case "5-hour", "5 hours", "5-hour limit": "5 小时"
            default: label
            }
        }
    }
}

struct QuotaSnapshot: Decodable {
    let checkedAt: String?
    let windows: [Quota]
    let source: String?
    let plan: String?

    init(checkedAt: String?, windows: [Quota], source: String?, plan: String? = nil) {
        self.checkedAt = checkedAt
        self.windows = windows
        self.source = source
        self.plan = plan
    }
}

struct ProviderCache: Decodable {
    struct Model: Decodable {
        let slug: String
        let name: String?
    }

    struct Auth: Decodable {
        let label: String?
    }

    let auth: Auth?
    let usageLimits: QuotaSnapshot?
    let models: [Model]?

    var chatGPTPlan: String? {
        let suffix = " Subscription"
        guard let label = auth?.label, label.hasPrefix("ChatGPT "), label.hasSuffix(suffix) else { return nil }
        return String(label.dropLast(suffix.count))
    }
}

struct Report {
    let readAt: Date
    let rows: [UsageRow]
    let catalogs: [Provider: ProviderCache]
    let desktopQuota: QuotaSnapshot?
    let days: [String]

    func quota(for provider: Provider) -> QuotaSnapshot? {
        if let cached = catalogs[provider]?.usageLimits, !cached.windows.isEmpty { return cached }
        return provider == .antigravity ? desktopQuota : nil
    }

    func summary(_ period: Period, provider: Provider) -> (tokens: Tokens, models: [ModelUsage], daily: [Int64]) {
        let selectedDays = Array(days.suffix(period.days))
        let selected = Set(selectedDays)
        var totals = Tokens()
        var byModel: [String: Tokens] = [:]
        var byDay: [String: Int64] = [:]
        var titles: [String: String] = [:]
        for model in catalogs[provider]?.models ?? [] where !model.slug.isEmpty {
            titles[model.slug] = model.name ?? model.slug
        }
        for row in rows where row.provider == provider && selected.contains(row.day) {
            totals.add(row.tokens)
            byModel[row.model, default: Tokens()].add(row.tokens)
            byDay[row.day, default: 0] += row.tokens.total
        }
        let models = provider.featuredModels.map { model in
            ModelUsage(id: model, title: titles[model], tokens: byModel[model, default: Tokens()])
        }
        return (totals, models, selectedDays.map { byDay[$0, default: 0] })
    }

    static func read(home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> Report {
        let now = Date()
        let calendar = Calendar.current
        let midnight = calendar.startOfDay(for: now)
        let localDay = DateFormatter()
        localDay.calendar = calendar
        localDay.locale = Locale(identifier: "en_US_POSIX")
        localDay.dateFormat = "yyyy-MM-dd"
        let dates = (0..<30).reversed().compactMap { calendar.date(byAdding: .day, value: -$0, to: midnight) }
        let days = dates.map { localDay.string(from: $0) }
        let timestamp = ISO8601DateFormatter()
        timestamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let t3 = home.appendingPathComponent(".t3")
        let db = t3.appendingPathComponent("userdata/statev2.sqlite")
        let rows = try readRows(db: db, since: timestamp.string(from: dates.first ?? midnight))
        var catalogs: [Provider: ProviderCache] = [:]
        for provider in Provider.allCases {
            let cache = t3.appendingPathComponent("caches/\(provider.rawValue).json")
            if let data = try? Data(contentsOf: cache) {
                catalogs[provider] = try? JSONDecoder().decode(ProviderCache.self, from: data)
            }
        }
        let quotaFile = home.appendingPathComponent("Library/Application Support/T3 Usage Bar/antigravity-quota.json")
        let desktopQuota = (try? Data(contentsOf: quotaFile))
            .flatMap { try? JSONDecoder().decode(QuotaSnapshot.self, from: $0) }
        return Report(readAt: now, rows: rows, catalogs: catalogs, desktopQuota: desktopQuota, days: days)
    }

    private static func readRows(db: URL, since: String) throws -> [UsageRow] {
        var database: OpaquePointer?
        let result = sqlite3_open_v2(db.path, &database, SQLITE_OPEN_READONLY, nil)
        defer { sqlite3_close(database) }
        guard result == SQLITE_OK, let database else { throw ReadError.database }
        sqlite3_busy_timeout(database, 800)

        // The run's selected model is the fallback for Antigravity turns without a reported model.
        let sql = """
            WITH portions AS (
                SELECT date(turn.completed_at, 'localtime') AS day,
                       coalesce(provider.driver, provider.provider) AS driver,
                       coalesce(json_extract(turn.payload_json, '$.model'),
                                CASE WHEN json_array_length(turn.payload_json, '$.turnTokenUsage.models') = 1
                                     THEN json_extract(turn.payload_json, '$.turnTokenUsage.models[0]') END,
                                json_extract(run.payload_json, '$.modelSelection.model'), '') AS model,
                       json_extract(turn.payload_json, '$.turnTokenUsage.inputTokens') AS input,
                       json_extract(turn.payload_json, '$.turnTokenUsage.cachedInputTokens') AS cached,
                       json_extract(turn.payload_json, '$.turnTokenUsage.outputTokens') AS output
                FROM orchestration_v2_projection_provider_turns AS turn
                JOIN orchestration_v2_projection_provider_threads AS provider
                     ON provider.provider_thread_id = turn.provider_thread_id
                LEFT JOIN orchestration_v2_projection_run_attempts AS attempt
                     ON attempt.attempt_id = turn.run_attempt_id
                LEFT JOIN orchestration_v2_projection_runs AS run ON run.run_id = attempt.run_id
                WHERE coalesce(provider.driver, provider.provider) IN ('antigravity', 'codex')
                  AND turn.status = 'completed'
                  AND turn.completed_at >= ?
                  AND json_extract(turn.payload_json, '$.turnTokenUsage.usageStatus') = 'complete'
            )
            SELECT day, driver, model, sum(input), sum(min(input, max(0, cached))), sum(output),
                   sum(CASE WHEN cached IS NOT NULL THEN input ELSE 0 END), count(*)
            FROM portions
            WHERE day IS NOT NULL AND input >= 0 AND output >= 0
            GROUP BY day, driver, model
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ReadError.schema
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        guard sqlite3_bind_text(statement, 1, since, -1, transient) == SQLITE_OK else {
            throw ReadError.database
        }
        var rows: [UsageRow] = []
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            if let day = sqlite3_column_text(statement, 0),
               let driver = sqlite3_column_text(statement, 1),
               let provider = Provider(rawValue: String(cString: driver)),
               let model = sqlite3_column_text(statement, 2) {
                rows.append(UsageRow(
                    day: String(cString: day), provider: provider, model: String(cString: model),
                    tokens: Tokens(
                        input: sqlite3_column_int64(statement, 3),
                        cached: sqlite3_column_int64(statement, 4),
                        output: sqlite3_column_int64(statement, 5),
                        measuredInput: sqlite3_column_int64(statement, 6),
                        turns: sqlite3_column_int64(statement, 7)
                    )
                ))
            }
            step = sqlite3_step(statement)
        }
        guard step == SQLITE_DONE else { throw ReadError.database }
        return rows
    }
}

enum ReadError: LocalizedError {
    case database, schema
    var errorDescription: String? {
        switch self {
        case .database: "暂时无法读取 T3 用量记录"
        case .schema: "当前 T3 版本的用量记录格式无法读取"
        }
    }
}

func compact(_ number: Int64) -> String {
    if number >= 100_000_000 { return String(format: "%.2f 亿", Double(number) / 100_000_000) }
    if number >= 10_000 { return String(format: "%.1f 万", Double(number) / 10_000) }
    return number.formatted()
}

func parsedDate(_ text: String?) -> Date? {
    guard let text else { return nil }
    let format = ISO8601DateFormatter()
    format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = format.date(from: text) { return date }
    format.formatOptions = [.withInternetDateTime]
    return format.date(from: text)
}

@main
struct T3UsageBar {
    @MainActor
    static func main() {
        if CommandLine.arguments.dropFirst().first == "--snapshot" {
            do {
                let report = try Report.read()
                for provider in Provider.allCases {
                    for period in Period.allCases {
                        let value = report.summary(period, provider: provider)
                        print("\(provider.rawValue) \(period.rawValue) turns=\(value.tokens.turns) input=\(value.tokens.input) cached=\(value.tokens.cached) output=\(value.tokens.output)")
                        for model in value.models { print("  \(model.id) \(model.tokens.total)") }
                    }
                    for window in report.quota(for: provider)?.windows ?? [] {
                        print("  \(window.id) used=\(window.usedPercent ?? -1) reset=\(window.resetsAt ?? "—")")
                    }
                }
                return
            } catch {
                FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
                exit(1)
            }
        }

        let app = NSApplication.shared
        let delegate = MenuBarApp()
        app.setActivationPolicy(.accessory)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
