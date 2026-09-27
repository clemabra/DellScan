import Foundation

/// Minimaler XML-Baum (lokale Namen ohne Namespace-Präfix).
final class XNode {
    let name: String
    let attributes: [String: String]
    var children: [XNode] = []
    var text = ""

    init(name: String, attributes: [String: String]) {
        self.name = name
        self.attributes = attributes
    }

    var value: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    func child(_ name: String) -> XNode? { children.first { $0.name == name } }

    /// Erster Nachfahre (Tiefensuche) mit passendem Namen.
    func first(_ name: String) -> XNode? { first { $0.name == name } }

    func first(where predicate: (XNode) -> Bool) -> XNode? {
        for c in children {
            if predicate(c) { return c }
            if let f = c.first(where: predicate) { return f }
        }
        return nil
    }

    /// Alle Nachfahren mit passendem Namen.
    func all(_ name: String) -> [XNode] {
        var result: [XNode] = []
        for c in children {
            if c.name == name { result.append(c) }
            result += c.all(name)
        }
        return result
    }

    static func parse(_ data: Data) -> XNode? {
        let builder = Builder()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = builder
        guard parser.parse() else { return nil }
        return builder.root
    }

    private final class Builder: NSObject, XMLParserDelegate {
        var root: XNode?
        var stack: [XNode] = []

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            let node = XNode(name: elementName, attributes: attributeDict)
            if let top = stack.last { top.children.append(node) } else { root = node }
            stack.append(node)
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            stack.removeLast()
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            stack.last?.text += string
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            stack.last?.text += String(decoding: CDATABlock, as: UTF8.self)
        }
    }
}

func xmlEscape(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
}
