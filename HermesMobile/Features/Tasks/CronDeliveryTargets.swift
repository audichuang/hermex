import Foundation

enum CronDeliveryTargets {
    struct Row: Equatable, Identifiable {
        let id: String
        let label: String
        let isSelected: Bool
        let needsHomeChannel: Bool
    }

    static func parse(_ value: String) -> [String] {
        var seen = Set<String>()
        let tokens = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        return tokens.isEmpty ? ["local"] : tokens
    }

    static func toggle(_ value: String, target: String, on: Bool) -> String {
        let current = parse(value)
        if on {
            return (current.contains(target) ? current : current + [target]).joined(separator: ",")
        }
        guard current.contains(target), current.count > 1 else { return current.joined(separator: ",") }
        return current.filter { $0 != target }.joined(separator: ",")
    }

    static func rows(serverOptions: [CronDeliveryOption], current: String) -> [Row] {
        let selected = Set(parse(current))
        var seen = Set<String>()
        var rows: [Row] = serverOptions.compactMap { option in
            guard let id = option.value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !id.isEmpty, seen.insert(id).inserted else { return nil }
            let name = option.label?.trimmingCharacters(in: .whitespacesAndNewlines)
            return Row(id: id, label: (name?.isEmpty == false ? name : nil) ?? id, isSelected: selected.contains(id),
                       needsHomeChannel: id != "local" && option.homeTargetSet != true)
        }
        for token in parse(current) where !seen.contains(token) {
            rows.append(Row(id: token, label: token, isSelected: true, needsHomeChannel: false))
        }
        return rows
    }
}
