#!/usr/bin/swift
//
// spike.swift — throwaway validation script (design doc Next Step #2 / T1)
//
// Goal: confirm the Anthropic Cost API and OpenAI Costs API respond with the
// shapes documented, and print parsed spend. No SQLite, no Keychain, no app
// shell — this is meant to be deleted once T1's questions are answered.
//
// Usage:
//   export ANTHROPIC_ADMIN_KEY="sk-ant-admin01-..."   # optional
//   export OPENAI_ADMIN_KEY="sk-admin-..."            # optional
//   swift spike/spike.swift
//
// Set whichever key(s) you have. The script only calls providers whose key
// is present in the environment.

import Foundation

// MARK: - Anthropic Cost Report

struct AnthropicCostReport: Decodable {
    struct Bucket: Decodable {
        let startingAt: String
        let endingAt: String
        let results: [Result]

        enum CodingKeys: String, CodingKey {
            case startingAt = "starting_at"
            case endingAt = "ending_at"
            case results
        }
    }
    struct Result: Decodable {
        let amount: String
        let currency: String
        let workspaceId: String?
        let description: String?

        enum CodingKeys: String, CodingKey {
            case amount, currency, description
            case workspaceId = "workspace_id"
        }
    }
    let data: [Bucket]
    let hasMore: Bool

    enum CodingKeys: String, CodingKey {
        case data
        case hasMore = "has_more"
    }
}

func fetchAnthropicCost(adminKey: String) async {
    print("\n=== Anthropic Cost Report ===")

    let calendar = Calendar(identifier: .gregorian)
    let now = Date()
    guard let sevenDaysAgo = calendar.date(byAdding: .day, value: -7, to: now) else { return }

    let formatter = ISO8601DateFormatter()
    let startingAt = formatter.string(from: sevenDaysAgo)
    let endingAt = formatter.string(from: now)

    var components = URLComponents(string: "https://api.anthropic.com/v1/organizations/cost_report")!
    components.queryItems = [
        URLQueryItem(name: "starting_at", value: startingAt),
        URLQueryItem(name: "ending_at", value: endingAt),
        URLQueryItem(name: "group_by[]", value: "workspace_id"),
        URLQueryItem(name: "group_by[]", value: "description"),
    ]

    var request = URLRequest(url: components.url!)
    request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
    request.setValue(adminKey, forHTTPHeaderField: "x-api-key")

    do {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            print("No HTTP response.")
            return
        }
        print("HTTP \(http.statusCode)")
        if http.statusCode != 200 {
            print(String(data: data, encoding: .utf8) ?? "<unreadable body>")
            return
        }

        let report = try JSONDecoder().decode(AnthropicCostReport.self, from: data)
        var total: Double = 0
        var byWorkspace: [String: Double] = [:]

        for bucket in report.data {
            for result in bucket.results {
                let amount = Double(result.amount) ?? 0
                total += amount
                let key = result.workspaceId ?? "(default workspace)"
                byWorkspace[key, default: 0] += amount
            }
        }

        print("Total (last 7 days): $\(String(format: "%.4f", total))")
        for (workspace, amount) in byWorkspace.sorted(by: { $0.value > $1.value }) {
            print("  workspace \(workspace): $\(String(format: "%.4f", amount))")
        }
        print("Note: Anthropic's Cost API has NO per-API-key breakdown — workspace_id is the finest grouping available (confirmed via docs, see design doc Reviewer Concern #1).")
    } catch {
        print("Error: \(error)")
    }
}

// MARK: - OpenAI Costs

struct OpenAICostsResponse: Decodable {
    struct Bucket: Decodable {
        let startTime: Int
        let endTime: Int
        let results: [Result]

        enum CodingKeys: String, CodingKey {
            case startTime = "start_time"
            case endTime = "end_time"
            case results
        }
    }
    struct Result: Decodable {
        let amount: Amount
        let apiKeyId: String?
        let projectId: String?
        let lineItem: String?

        enum CodingKeys: String, CodingKey {
            case amount
            case apiKeyId = "api_key_id"
            case projectId = "project_id"
            case lineItem = "line_item"
        }
    }
    struct Amount: Decodable {
        let value: Double
        let currency: String
    }
    let data: [Bucket]
    let hasMore: Bool

    enum CodingKeys: String, CodingKey {
        case data
        case hasMore = "has_more"
    }
}

func fetchOpenAICost(adminKey: String) async {
    print("\n=== OpenAI Costs ===")

    let sevenDaysAgo = Date().addingTimeInterval(-7 * 24 * 60 * 60)
    let startTime = Int(sevenDaysAgo.timeIntervalSince1970)

    var components = URLComponents(string: "https://api.openai.com/v1/organization/costs")!
    components.queryItems = [
        URLQueryItem(name: "start_time", value: String(startTime)),
        URLQueryItem(name: "group_by", value: "api_key_id"),
        URLQueryItem(name: "limit", value: "7"),
    ]

    var request = URLRequest(url: components.url!)
    request.setValue("Bearer \(adminKey)", forHTTPHeaderField: "Authorization")

    do {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            print("No HTTP response.")
            return
        }
        print("HTTP \(http.statusCode)")
        if http.statusCode != 200 {
            print(String(data: data, encoding: .utf8) ?? "<unreadable body>")
            return
        }

        let report = try JSONDecoder().decode(OpenAICostsResponse.self, from: data)
        var total: Double = 0
        var byKey: [String: Double] = [:]

        for bucket in report.data {
            for result in bucket.results {
                total += result.amount.value
                let key = result.apiKeyId ?? "(no api_key_id — e.g. Workbench/UI usage)"
                byKey[key, default: 0] += result.amount.value
            }
        }

        print("Total (last 7 days): $\(String(format: "%.4f", total))")
        for (apiKey, amount) in byKey.sorted(by: { $0.value > $1.value }) {
            print("  api_key_id \(apiKey): $\(String(format: "%.4f", amount))")
        }
        print("Note: OpenAI DOES support real per-API-key attribution (unlike Anthropic).")
    } catch {
        print("Error: \(error)")
    }
}

// MARK: - Entry point

let semaphore = DispatchSemaphore(value: 0)

Task {
    var ranAny = false

    if let anthropicKey = ProcessInfo.processInfo.environment["ANTHROPIC_ADMIN_KEY"], !anthropicKey.isEmpty {
        await fetchAnthropicCost(adminKey: anthropicKey)
        ranAny = true
    }

    if let openaiKey = ProcessInfo.processInfo.environment["OPENAI_ADMIN_KEY"], !openaiKey.isEmpty {
        await fetchOpenAICost(adminKey: openaiKey)
        ranAny = true
    }

    if !ranAny {
        print("No admin keys found in environment.")
        print("Set ANTHROPIC_ADMIN_KEY and/or OPENAI_ADMIN_KEY, then re-run.")
    }

    semaphore.signal()
}

semaphore.wait()
