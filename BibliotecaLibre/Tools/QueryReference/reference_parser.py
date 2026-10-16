"""Independent bounded parser reference for observed Libronix query contracts.

This is research code, not the product parser or a claim of complete grammar.
It consumes query strings, never original JavaScript, decompiled code or books.
The `natural` node has deliberately unspecified search evaluation semantics.
"""

from dataclasses import dataclass


class ParseFailure(ValueError):
    pass


def utf16_count(text):
    return len(text.encode("utf-16-le")) // 2


@dataclass
class Token:
    text: str
    start: int
    end: int
    quoted: bool = False


def scan(query):
    if utf16_count(query) > 16384:
        raise ParseFailure("source_budget")
    tokens, i = [], 0
    while i < len(query):
        if query[i].isspace():
            i += 1
            continue
        start = i
        if query[i] in "():":
            i += 1
            tokens.append(Token(query[start:i], start, i))
        elif query[i] == '"':
            i += 1
            while i < len(query):
                if query[i] == '"':
                    backslashes, j = 0, i - 1
                    while j >= start and query[j] == "\\":
                        backslashes += 1
                        j -= 1
                    if backslashes % 2 == 0:
                        break
                i += 1
            if i == len(query):
                raise ParseFailure("unterminated_quote")
            i += 1
            # Preserve literal escaped text as observed, rather than unescaping it.
            tokens.append(Token(query[start + 1:i - 1], start, i, True))
        else:
            while i < len(query) and not query[i].isspace() and query[i] not in '():"':
                i += 1
            tokens.append(Token(query[start:i], start, i))
        if len(tokens) > 512:
            raise ParseFailure("token_budget")
    return tokens


class RecordedContractParser:
    MODES = {"QueryParser", "AdvancedQueryParser"}

    def __init__(self, query, mode):
        if mode not in self.MODES:
            raise ValueError("Unknown parser mode")
        self.query, self.mode, self.cursor = query, mode, 0
        self.tokens = scan(query)
        self.advanced = mode == "AdvancedQueryParser"
        self.operators = {"OR": (1, "or"), "AND": (2, "and"), "NOT": (2, "and-not"),
                          "NEAR": (3 if self.advanced else 2, "near"),
                          "BEFORE": (3 if self.advanced else 2, "before"),
                          "WITHIN": (3, "within")}

    def range_attributes(self, token):
        if not self.advanced:
            return {}
        return {"offset": str(utf16_count(self.query[:token.start])),
                "length": str(utf16_count(self.query[token.start:token.end]))}

    def leaf(self, token, fields=None):
        if token.text in ["(", ")", ":"] or not token.quoted and token.text.upper() in ["XOR", "AND", "OR", "NEAR", "BEFORE", "WITHIN"]:
            raise ParseFailure("expected_term")
        attributes = self.range_attributes(token)
        if fields:
            attributes.update(fields="1", field1=fields)
        return dict(tag="term", attributes=attributes, text=token.text, children=[])

    def take(self):
        if self.cursor >= len(self.tokens):
            raise ParseFailure("missing_operand")
        result = self.tokens[self.cursor]
        self.cursor += 1
        return result

    def atom(self, depth):
        if depth > 32:
            raise ParseFailure("nesting_budget")
        token = self.take()
        if token.text == "(":
            value = self.expression(1, depth + 1)
            if self.take().text != ")":
                raise ParseFailure("missing_close")
            return value
        if self.advanced and not token.quoted and token.text.upper() == "NOT":
            return dict(tag="not", attributes=self.range_attributes(token), text="", children=[self.atom(depth + 1)])
        if self.cursor < len(self.tokens) and self.tokens[self.cursor].text == ":":
            if not self.advanced or token.quoted:
                raise ParseFailure("fields_unavailable")
            self.take()
            return self.leaf(self.take(), fields=token.text)
        return self.leaf(token)

    def expression(self, minimum, depth=0):
        left = self.atom(depth)
        while self.cursor < len(self.tokens):
            operator = self.tokens[self.cursor]
            name = operator.text.upper() if not operator.quoted else ""
            if name not in self.operators:
                break
            priority, tag = self.operators[name]
            if name == "NOT" and not self.advanced:
                break
            if name == "WITHIN" and not self.advanced:
                raise ParseFailure("within_unavailable")
            if priority < minimum:
                break
            self.take()
            if not self.advanced and name == "AND" and self.cursor < len(self.tokens) and self.tokens[self.cursor].text.upper() == "NOT":
                # Basic AND NOT is a binary operator, unlike its literal bare NOT.
                self.take()
                tag = "and-not"
            attributes = self.range_attributes(operator)
            if name == "WITHIN":
                maximum, unit = self.take(), self.take()
                if not maximum.text.isdecimal() or unit.text not in ["WORDS", "CHARS"]:
                    raise ParseFailure("within_parameters_outside_verified_subset")
                operator.end = unit.end
                attributes = self.range_attributes(operator)
                attributes.update(max=maximum.text, unit=unit.text)
            right = self.expression(priority + 1, depth + 1)
            left = dict(tag=tag, attributes=attributes, text="", children=[left, right])
        return left

    def parse(self):
        if not self.tokens:
            raise ParseFailure("empty")
        explicit = any(not t.quoted and t.text.upper() in ["AND", "OR", "NEAR", "BEFORE", "WITHIN"] or t.text in ["(", ")", ":"] for t in self.tokens)
        if not explicit and not (self.advanced and any(not t.quoted and t.text.upper() == "NOT" for t in self.tokens)):
            values = [self.leaf(t) for t in self.tokens]
            if len(values) == 1:
                expression = values[0]
            elif self.advanced:
                expression = dict(tag="natural", attributes={}, text="", children=values)
            else:
                expression = values[0]
                for value in values[1:]:
                    expression = dict(tag="or", attributes={}, text="", children=[expression, value])
        else:
            expression = self.expression(1)
            if self.cursor != len(self.tokens):
                raise ParseFailure("unexpected_token")
        return dict(tag="query", attributes={} if self.advanced else {"type": "lbx-xml"}, text="", children=[expression])


def parse(query, mode):
    return RecordedContractParser(query, mode).parse()


def translate_advanced(tree):
    """Independent projection matching the bounded observed translation cases.

    The emitted distance/field constraints remain serialized contracts; this
    function does not invent tokenization, indexing or search-engine semantics.
    """
    term_counter, aliases, constraints = 0, [], []

    def node(tag, attributes=None, text="", children=None):
        return dict(tag=tag, attributes=attributes or {}, text=text, children=children or [])

    def walk(source):
        nonlocal term_counter
        tag = source["tag"]
        if tag == "term":
            term_counter += 1
            identity = "auto" + str(term_counter)
            field = source["attributes"].get("field1")
            if field:
                alias = "alias" + str(len(aliases) + 1)
                aliases.append(node("alias", {"name": alias}, field))
                constraints.append(node("field", {"term": identity, "name": alias}))
            return node("term", {"id": identity}, source["text"]), [identity]
        children, identities = [], []
        for child in source["children"]:
            value, ids = walk(child)
            children.append(value)
            identities.extend(ids)
        if tag == "not":
            return node("and-not", children=[node("term", {"match": "any"}), children[0]]), identities
        if tag in ["near", "before", "within"]:
            attributes = {"terms": " ".join(identities)}
            if tag == "near":
                attributes["max"] = "48"
            elif tag == "before":
                attributes["type"] = "before"
            else:
                attributes["unit"] = {"WORDS": "word", "CHARS": "character"}[source["attributes"]["unit"]]
                attributes["max"] = source["attributes"]["max"]
            constraints.append(node("within", attributes))
            tag = "and"
        elif tag == "natural":
            tag = "and"
        if tag == "and" and len(children) == 2 and children[1]["tag"] == "and-not" and children[1]["children"][0]["attributes"] == {"match": "any"}:
            return node("and-not", children=[children[0], children[1]["children"][1]]), identities
        if tag == "and":
            flattened = []
            for child in children:
                flattened.extend(child["children"] if child["tag"] == "and" else [child])
            children = flattened
        return node(tag, children=children), identities

    if tree["tag"] != "query" or tree["attributes"]:
        raise ParseFailure("advanced_tree_required")
    expression, _ = walk(tree["children"][0])
    children = ([node("aliases", children=aliases)] if aliases else []) + [expression]
    if constraints:
        children.append(node("constraints", children=constraints))
    return node("query", {"type": "libronix"}, children=children)
