import Foundation

/// 极简 XML 树，用于解析 epub 的 container.xml 与 OPF。
/// 关闭命名空间处理，元素名保留前缀，查询时按本地名匹配。
final class XMLTree {
    final class Node {
        let name: String
        var attributes: [String: String] = [:]
        var children: [Node] = []
        var text: String = ""

        init(name: String) {
            self.name = name
        }

        var localName: String {
            if let dot = name.lastIndex(of: ":") {
                return String(name[name.index(after: dot)...])
            }
            return name
        }

        func firstChild(named localName: String) -> Node? {
            children.first { $0.localName == localName }
        }

        func descendants(named localName: String) -> [Node] {
            var result: [Node] = []
            if self.localName == localName { result.append(self) }
            for child in children {
                result.append(contentsOf: child.descendants(named: localName))
            }
            return result
        }
    }

    static func parse(_ data: Data) -> Node? {
        let builder = Builder()
        let parser = XMLParser(data: data)
        parser.delegate = builder
        guard parser.parse() else { return builder.root }
        return builder.root
    }

    private final class Builder: NSObject, XMLParserDelegate {
        var root: Node?
        private var stack: [Node] = []

        func parser(_ parser: XMLParser, didStartElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?,
                    attributes attributeDict: [String: String] = [:]) {
            let node = Node(name: elementName)
            node.attributes = attributeDict
            if let parent = stack.last {
                parent.children.append(node)
            } else {
                root = node
            }
            stack.append(node)
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            stack.last?.text += string
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?) {
            if !stack.isEmpty { stack.removeLast() }
        }
    }
}
