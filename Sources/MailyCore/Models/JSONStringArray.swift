import Foundation

enum JSONStringArray {
    static func encode(_ values: [String]) -> String {
        guard let data = try? JSONEncoder().encode(values),
              let s = String(data: data, encoding: .utf8) else { return "[]" }
        return s
    }

    static func decode(_ json: String) -> [String] {
        guard let data = json.data(using: .utf8),
              let values = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return values
    }
}
