import Foundation

/// Lines up the columns of a Markdown table (Format → Align Table).
enum MarkdownTable {
    /// The cells of one row, trimmed. A pipe written as `\|` stays inside its cell.
    static func cells(_ line: String) -> [String] {
        var cells: [String] = []
        var cell = ""
        var escaped = false
        for character in line.trimmingCharacters(in: .whitespaces) {
            if character == "|" && !escaped {
                cells.append(cell)
                cell = ""
            } else {
                cell.append(character)
            }
            escaped = character == "\\" && !escaped
        }
        cells.append(cell)
        // The pipes at the start and end of the row aren't cell borders.
        if cells.count > 1, cells.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { cells.removeFirst() }
        if cells.count > 1, cells.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { cells.removeLast() }
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// The row under the header: `---`, `:--`, `--:` or `:-:` in every cell.
    static func isDelimiter(_ line: String) -> Bool {
        guard line.contains("-") else { return false }
        return cells(line).allSatisfy { $0.range(of: "^:?-+:?$", options: .regularExpression) != nil }
    }

    /// Columns a string takes in a monospaced font: CJK and emoji count as two.
    static func width(_ text: String) -> Int {
        text.reduce(0) { total, character in
            guard let scalar = character.unicodeScalars.first else { return total }
            let wide: Bool
            switch scalar.value {
            case 0x1100...0x115F, 0x2E80...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F,
                0xFF00...0xFF60, 0xFFE0...0xFFE6, 0x1F300...0x1FAFF, 0x20000...0x3FFFD:
                wide = true
            default:
                wide = false
            }
            return total + (wide ? 2 : 1)
        }
    }

    /// `lines` (header, delimiter, rows) with every column padded to the same width. Nil when the
    /// second line isn't a delimiter row.
    static func aligned(_ lines: [String]) -> [String]? {
        guard lines.count >= 2, isDelimiter(lines[1]) else { return nil }
        let rows = lines.map(cells)
        let columns = rows[0].count
        guard rows[1].count == columns else { return nil }
        var widths = [Int](repeating: 3, count: columns)
        for (index, row) in rows.enumerated() where index != 1 {
            for (column, cell) in row.prefix(columns).enumerated() { widths[column] = max(widths[column], width(cell)) }
        }
        let indent = String(lines[0].prefix { $0 == " " || $0 == "\t" })
        return rows.enumerated().map { index, row in
            var out: [String] = []
            for column in 0..<columns {
                let mark = rows[1][column]
                let left = mark.hasPrefix(":"), right = mark.hasSuffix(":")
                let w = widths[column]
                if index == 1 {
                    out.append((left ? ":" : "-") + String(repeating: "-", count: w - 2) + (right ? ":" : "-"))
                    continue
                }
                let cell = column < row.count ? row[column] : ""
                let space = w - width(cell)
                let before = right ? (left ? space / 2 : space) : 0
                out.append(String(repeating: " ", count: before) + cell + String(repeating: " ", count: space - before))
            }
            // Cells beyond the header's columns aren't shown; they're kept as written.
            out += row.dropFirst(columns)
            return indent + "| " + out.joined(separator: " | ") + " |"
        }
    }
}
