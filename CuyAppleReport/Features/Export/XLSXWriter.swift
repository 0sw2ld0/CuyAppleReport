import Foundation

/// Writes a small, standards-compliant Open XML workbook using ZIP's STORE method.
/// This keeps exporting available in sandboxed/offline builds without downloading a C library.
enum XLSXWriter {
    private enum Cell {
        case text(String)
        case number(Int)
    }
    private struct Sheet {
        let name: String
        let rows: [[Cell]]
        let widths: [Int]
        let filter: Bool
    }
    private struct ZipEntry {
        let name: String
        let bytes: Data
        let crc: UInt32
        let offset: UInt32
    }

    static func make(feedback: [Feedback], anonymizeEmails: Bool) throws -> Data {
        let comments = feedback.filter { $0.kind == "Comentario" }
        let crashes = feedback.filter { $0.kind == "Error" }
        let generated = Date.now.formatted(date: .complete, time: .shortened)
        var summaryRows: [[Cell]] = [
            [.text("CuyAppleReport · Resumen"), .text("")],
            [.text("Fecha de generación"), .text(generated)],
            [.text("Total feedback"), .number(feedback.count)],
            [.text("Comentarios"), .number(comments.count)],
            [.text("Errores"), .number(crashes.count)],
            [.text("Nuevos"), .number(feedback.filter { $0.status == "Nuevo" }.count)]
        ]
        if summaryRows.isEmpty { summaryRows = [[]] }

        let columns = ["ID", "Fecha", "App", "Versión", "Build", "Tester", "Dispositivo", "SO", "Idioma", "Comentario", "Estado", "Notas", "Capturas"]
        func feedbackRows(_ items: [Feedback]) -> [[Cell]] {
            let header: [Cell] = columns.map(Cell.text)
            let rows: [[Cell]] = items.map { feedbackRow($0, anonymizeEmails: anonymizeEmails) }
            return [header] + rows
        }
        let crashColumns = ["ID", "Fecha", "App", "Build", "Tester", "Dispositivo", "SO", "Comentario",
                            "Crash log (primeros 500 caracteres)", "Ruta completa", "Estado"]
        let crashHeader: [Cell] = crashColumns.map(Cell.text)
        let crashBody: [[Cell]] = crashes.map { crashRow($0, anonymizeEmails: anonymizeEmails) }
        let crashRows: [[Cell]] = [crashHeader] + crashBody
        func aggregates(_ key: (Feedback) -> String) -> [[Cell]] {
            let grouped = Dictionary(grouping: feedback, by: key)
            return [[.text("Categoría"), .text("Comentarios"), .text("Errores"), .text("Total")]] +
                grouped.map { name, values in
                    let commentCount = values.filter { $0.kind == "Comentario" }.count
                    let crashCount = values.filter { $0.kind == "Error" }.count
                    return [.text(name), .number(commentCount), .number(crashCount), .number(values.count)]
                }.sorted { cellText($0[0]) < cellText($1[0]) }
        }
        let sheets = [
            Sheet(name: "Resumen", rows: summaryRows, widths: [28, 36], filter: false),
            Sheet(name: "Comentarios", rows: feedbackRows(comments), widths: [28, 22, 24, 14, 14, 28, 22, 12, 14, 56, 18, 44, 48], filter: true),
            Sheet(name: "Errores", rows: crashRows, widths: [28, 22, 24, 14, 28, 22, 12, 40, 64, 52, 18], filter: true),
            Sheet(name: "Por dispositivo", rows: aggregates { $0.deviceModel ?? "Desconocido" }, widths: [28, 16, 16, 16], filter: true),
            Sheet(name: "Por build", rows: aggregates { $0.buildNumber ?? "Desconocido" }, widths: [28, 16, 16, 16], filter: true)
        ]

        var files: [(String, Data)] = [
            ("[Content_Types].xml", Data(contentTypes(sheets.count).utf8)),
            ("_rels/.rels", Data(rootRelationships.utf8)),
            ("xl/workbook.xml", Data(workbookXML(sheets).utf8)),
            ("xl/_rels/workbook.xml.rels", Data(workbookRelationships(sheets.count).utf8)),
            ("xl/styles.xml", Data(stylesXML.utf8))
        ]
        for (index, sheet) in sheets.enumerated() {
            files.append(("xl/worksheets/sheet\(index + 1).xml", Data(sheetXML(sheet).utf8)))
        }
        return zip(files)
    }

    // Cada fila se arma en su propia función con tipos explícitos: un único literal con
    // muchos `.text(... ?? "")` dentro de `map` y `+` puede exceder el tiempo de type-check.
    private static func feedbackRow(_ item: Feedback, anonymizeEmails: Bool) -> [Cell] {
        let values: [String] = [
            item.appleId,
            item.createdDate.formatted(date: .numeric, time: .shortened),
            item.app?.name ?? "",
            item.appVersion ?? "",
            item.buildNumber ?? "",
            anonymous(item.testerEmail, enabled: anonymizeEmails),
            item.deviceModel ?? "",
            item.osVersion ?? "",
            item.locale ?? "",
            item.comment ?? "",
            item.status,
            item.notes,
            item.screenshotPaths.joined(separator: " | ")
        ]
        return values.map(Cell.text)
    }

    private static func crashRow(_ item: Feedback, anonymizeEmails: Bool) -> [Cell] {
        let log: String = item.crashLogPath.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) } ?? ""
        let values: [String] = [
            item.appleId,
            item.createdDate.formatted(date: .numeric, time: .shortened),
            item.app?.name ?? "",
            item.buildNumber ?? "",
            anonymous(item.testerEmail, enabled: anonymizeEmails),
            item.deviceModel ?? "",
            item.osVersion ?? "",
            item.comment ?? "",
            String(log.prefix(500)),
            item.crashLogPath ?? "",
            item.status
        ]
        return values.map(Cell.text)
    }

    private static func contentTypes(_ count: Int) -> String {
        let sheets = (1...count).map { "<Override PartName=\"/xl/worksheets/sheet\($0).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>" }.joined()
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>\(sheets)</Types>
        """
    }

    private static let rootRelationships = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>
    """

    private static func workbookXML(_ sheets: [Sheet]) -> String {
        let definitions = sheets.enumerated().map { index, sheet in
            "<sheet name=\"\(xml(sheet.name))\" sheetId=\"\(index + 1)\" r:id=\"rId\(index + 1)\"/>"
        }.joined()
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>\(definitions)</sheets></workbook>
        """
    }

    private static func workbookRelationships(_ count: Int) -> String {
        let sheets = (1...count).map { "<Relationship Id=\"rId\($0)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet\($0).xml\"/>" }.joined()
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\(sheets)<Relationship Id="rId\(count + 1)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>
        """
    }

    private static let stylesXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><fonts count="2"><font><sz val="11"/><name val="Arial"/></font><font><b/><sz val="11"/><name val="Arial"/></font></fonts><fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills><borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders><cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs><cellXfs count="2"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/><xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/></cellXfs><cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles></styleSheet>
    """

    private static func sheetXML(_ sheet: Sheet) -> String {
        let columns = sheet.widths.enumerated().map { index, width in
            "<col min=\"\(index + 1)\" max=\"\(index + 1)\" width=\"\(width)\" customWidth=\"1\"/>"
        }.joined()
        let rows = sheet.rows.enumerated().map { rowIndex, row in
            let cells = row.enumerated().map { columnIndex, cell -> String in
                let ref = "\(columnName(columnIndex + 1))\(rowIndex + 1)"
                let style = rowIndex == 0 && sheet.filter ? " s=\"1\"" : ""
                switch cell {
                case .text(let value): return "<c r=\"\(ref)\" t=\"inlineStr\"\(style)><is><t xml:space=\"preserve\">\(xml(value))</t></is></c>"
                case .number(let value): return "<c r=\"\(ref)\"\(style)><v>\(value)</v></c>"
                }
            }.joined()
            return "<row r=\"\(rowIndex + 1)\">\(cells)</row>"
        }.joined()
        let lastColumn = columnName(max(sheet.rows.map(\.count).max() ?? 1, 1))
        let lastRow = max(sheet.rows.count, 1)
        let autoFilter = sheet.filter ? "<autoFilter ref=\"A1:\(lastColumn)\(lastRow)\"/>" : ""
        let views = sheet.filter ? "<sheetViews><sheetView workbookViewId=\"0\"><pane ySplit=\"1\" topLeftCell=\"A2\" activePane=\"bottomLeft\" state=\"frozen\"/></sheetView></sheetViews>" : ""
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">\(views)<cols>\(columns)</cols><sheetData>\(rows)</sheetData>\(autoFilter)</worksheet>
        """
    }

    private static func columnName(_ number: Int) -> String {
        var n = number
        var result = ""
        while n > 0 {
            let remainder = (n - 1) % 26
            result = String(UnicodeScalar(65 + remainder)!) + result
            n = (n - 1) / 26
        }
        return result
    }

    private static func xml(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private static func anonymous(_ value: String?, enabled: Bool) -> String {
        guard enabled, let value, let at = value.firstIndex(of: "@") else { return value ?? "" }
        return "tester\(value[at...])"
    }

    private static func cellText(_ cell: Cell) -> String {
        if case .text(let value) = cell { value } else { "" }
    }

    private static func zip(_ files: [(String, Data)]) -> Data {
        var output = Data()
        var entries: [ZipEntry] = []
        for (name, bytes) in files {
            let filename = Data(name.utf8)
            let offset = UInt32(output.count)
            let crc = crc32(bytes)
            output.appendLE(UInt32(0x04034B50))
            output.appendLE(UInt16(20)); output.appendLE(UInt16(0)); output.appendLE(UInt16(0))
            output.appendLE(UInt16(0)); output.appendLE(UInt16(33))
            output.appendLE(crc); output.appendLE(UInt32(bytes.count)); output.appendLE(UInt32(bytes.count))
            output.appendLE(UInt16(filename.count)); output.appendLE(UInt16(0))
            output.append(filename); output.append(bytes)
            entries.append(ZipEntry(name: name, bytes: bytes, crc: crc, offset: offset))
        }
        let centralOffset = UInt32(output.count)
        for entry in entries {
            let filename = Data(entry.name.utf8)
            output.appendLE(UInt32(0x02014B50))
            output.appendLE(UInt16(20)); output.appendLE(UInt16(20)); output.appendLE(UInt16(0)); output.appendLE(UInt16(0))
            output.appendLE(UInt16(0)); output.appendLE(UInt16(33))
            output.appendLE(entry.crc); output.appendLE(UInt32(entry.bytes.count)); output.appendLE(UInt32(entry.bytes.count))
            output.appendLE(UInt16(filename.count)); output.appendLE(UInt16(0)); output.appendLE(UInt16(0))
            output.appendLE(UInt16(0)); output.appendLE(UInt16(0)); output.appendLE(UInt32(0)); output.appendLE(entry.offset)
            output.append(filename)
        }
        let centralSize = UInt32(output.count) - centralOffset
        output.appendLE(UInt32(0x06054B50)); output.appendLE(UInt16(0)); output.appendLE(UInt16(0))
        output.appendLE(UInt16(entries.count)); output.appendLE(UInt16(entries.count))
        output.appendLE(centralSize); output.appendLE(centralOffset); output.appendLE(UInt16(0))
        return output
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
        }
        return crc ^ 0xFFFF_FFFF
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
