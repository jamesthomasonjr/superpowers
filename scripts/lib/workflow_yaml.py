"""Minimal YAML subset loader for workflow configuration files."""

from __future__ import annotations

import re
from typing import Any


class YAMLError(ValueError):
    """Raised when YAML text cannot be parsed."""


def load_yaml(text: str) -> Any:
    """Parse a YAML subset into Python objects."""
    lines = _strip_comments(text)
    if not lines:
        return None
    value, index = _parse_node(lines, 0, 0)
    _skip_blank(lines, index)
    if index < len(lines):
        raise YAMLError(f"unexpected content at line {lines[index][0] + 1}")
    return value


def dump_yaml(obj: Any) -> str:
    """Serialize supported Python objects to YAML text."""
    return _dump_value(obj, 0).rstrip() + "\n"


def _strip_comments(text: str) -> list[tuple[int, str]]:
    lines: list[tuple[int, str]] = []
    for line_no, raw in enumerate(text.splitlines()):
        stripped = _remove_comment(raw).rstrip()
        if stripped.strip():
            lines.append((line_no, stripped))
    return lines


def _remove_comment(line: str) -> str:
    in_single = False
    in_double = False
    for index, char in enumerate(line):
        if char == "'" and not in_double:
            in_single = not in_single
        elif char == '"' and not in_single:
            in_double = not in_double
        elif char == "#" and not in_single and not in_double:
            return line[:index]
    return line


def _indent_of(line: str) -> int:
    count = 0
    for char in line:
        if char == " ":
            count += 1
        else:
            break
    if count < len(line) and line[count] == "\t":
        raise YAMLError("tabs are not allowed for indentation")
    return count


def _content(line: str) -> str:
    return line[_indent_of(line) :].strip()


def _skip_blank(lines: list[tuple[int, str]], index: int) -> int:
    while index < len(lines) and not _content(lines[index][1]):
        index += 1
    return index


def _parse_node(lines: list[tuple[int, str]], index: int, indent: int) -> tuple[Any, int]:
    index = _skip_blank(lines, index)
    if index >= len(lines):
        return None, index

    line = lines[index][1]
    current_indent = _indent_of(line)
    if current_indent < indent:
        return None, index
    if current_indent > indent:
        raise YAMLError(f"unexpected indent at line {lines[index][0] + 1}")

    content = _content(line)
    if content.startswith("- "):
        return _parse_sequence(lines, index, indent)
    if content == "-":
        return _parse_sequence(lines, index, indent)
    if ":" in content:
        return _parse_mapping(lines, index, indent)
    raise YAMLError(f"expected mapping or sequence at line {lines[index][0] + 1}")


def _parse_mapping(lines: list[tuple[int, str]], index: int, indent: int) -> tuple[dict[str, Any], int]:
    mapping: dict[str, Any] = {}
    while index < len(lines):
        index = _skip_blank(lines, index)
        if index >= len(lines):
            break

        line_no, line = lines[index]
        current_indent = _indent_of(line)
        if current_indent < indent:
            break
        if current_indent > indent:
            break

        content = _content(line)
        if not content or content.startswith("- "):
            break

        key, separator, remainder = content.partition(":")
        if not separator:
            raise YAMLError(f"expected ':' after key at line {line_no + 1}")
        key = key.strip()
        if not key:
            raise YAMLError(f"empty mapping key at line {line_no + 1}")

        remainder = remainder.strip()
        if remainder == "":
            index += 1
            index = _skip_blank(lines, index)
            if index >= len(lines) or _indent_of(lines[index][1]) <= indent:
                mapping[key] = None
                continue
            if _content(lines[index][1]).startswith("- "):
                value, index = _parse_sequence(lines, index, indent + 2)
            else:
                value, index = _parse_mapping(lines, index, indent + 2)
            mapping[key] = value
            continue

        if remainder == "{}":
            mapping[key] = {}
            index += 1
            continue
        if remainder == "[]":
            mapping[key] = []
            index += 1
            continue

        mapping[key] = _parse_scalar(remainder)
        index += 1

    return mapping, index


def _parse_sequence(lines: list[tuple[int, str]], index: int, indent: int) -> tuple[list[Any], int]:
    sequence: list[Any] = []
    while index < len(lines):
        index = _skip_blank(lines, index)
        if index >= len(lines):
            break

        line_no, line = lines[index]
        current_indent = _indent_of(line)
        if current_indent < indent:
            break

        content = _content(line)
        if not content.startswith("-") or (content != "-" and not content.startswith("- ")):
            break
        if current_indent != indent:
            break

        item_text = content[1:].strip()
        if item_text == "":
            index += 1
            index = _skip_blank(lines, index)
            if index >= len(lines) or _indent_of(lines[index][1]) <= indent:
                sequence.append(None)
                continue
            if _content(lines[index][1]).startswith("- "):
                value, index = _parse_sequence(lines, index, indent + 2)
            else:
                value, index = _parse_mapping(lines, index, indent + 2)
            sequence.append(value)
            continue

        if ":" in item_text:
            key, separator, remainder = item_text.partition(":")
            if separator:
                if remainder.strip() == "":
                    index += 1
                    item: dict[str, Any] = {key.strip(): None}
                    index = _skip_blank(lines, index)
                    if index < len(lines) and _indent_of(lines[index][1]) > indent:
                        nested, index = _parse_mapping(lines, index, indent + 2)
                        item.update(nested)
                    sequence.append(item)
                    continue
                item = {key.strip(): _parse_scalar(remainder.strip())}
                index += 1
                index = _skip_blank(lines, index)
                while index < len(lines) and _indent_of(lines[index][1]) > indent:
                    nested_line_no, nested_raw = lines[index]
                    nested_indent = _indent_of(nested_raw)
                    nested_line = _content(nested_raw)
                    if nested_line.startswith("- "):
                        break
                    nested_key, nested_sep, nested_remainder = nested_line.partition(":")
                    if not nested_sep:
                        break
                    nested_key = nested_key.strip()
                    nested_remainder = nested_remainder.strip()
                    if nested_remainder == "":
                        index += 1
                        index = _skip_blank(lines, index)
                        if index >= len(lines) or _indent_of(lines[index][1]) <= nested_indent:
                            item[nested_key] = None
                            continue
                        child_indent = nested_indent + 2
                        if _content(lines[index][1]).startswith("- "):
                            nested, index = _parse_sequence(lines, index, child_indent)
                        else:
                            nested, index = _parse_mapping(lines, index, child_indent)
                        item[nested_key] = nested
                    elif nested_remainder == "{}":
                        item[nested_key] = {}
                        index += 1
                    elif nested_remainder == "[]":
                        item[nested_key] = []
                        index += 1
                    else:
                        item[nested_key] = _parse_scalar(nested_remainder)
                        index += 1
                sequence.append(item)
                continue

        sequence.append(_parse_scalar(item_text))
        index += 1

    if not sequence:
        raise YAMLError(f"expected sequence item at line {line_no + 1}")
    return sequence, index


def _parse_scalar(text: str) -> Any:
    if not text:
        return ""

    if len(text) >= 2 and text[0] == text[-1] and text[0] in ("'", '"'):
        quote = text[0]
        inner = text[1:-1]
        if quote == "'":
            return inner.replace("''", "'")
        return _unescape_double_quoted(inner)

    lowered = text.lower()
    if lowered in ("null", "~"):
        return None
    if lowered == "true":
        return True
    if lowered == "false":
        return False
    if re.fullmatch(r"-?\d+", text):
        return int(text)

    return text


def _unescape_double_quoted(text: str) -> str:
    result: list[str] = []
    index = 0
    while index < len(text):
        char = text[index]
        if char != "\\":
            result.append(char)
            index += 1
            continue
        index += 1
        if index >= len(text):
            raise YAMLError("trailing backslash in double-quoted string")
        escape = text[index]
        mapping = {
            "n": "\n",
            "r": "\r",
            "t": "\t",
            "\\": "\\",
            '"': '"',
        }
        if escape not in mapping:
            raise YAMLError(f"unsupported escape sequence \\{escape}")
        result.append(mapping[escape])
        index += 1
    return "".join(result)


def _dump_value(value: Any, indent: int) -> str:
    prefix = " " * indent
    if value is None:
        return f"{prefix}null\n"
    if isinstance(value, bool):
        return f"{prefix}{str(value).lower()}\n"
    if isinstance(value, int):
        return f"{prefix}{value}\n"
    if isinstance(value, str):
        if _needs_quotes(value):
            escaped = value.replace("\\", "\\\\").replace('"', '\\"')
            return f'{prefix}"{escaped}"\n'
        return f"{prefix}{value}\n"
    if isinstance(value, list):
        if not value:
            return f"{prefix}[]\n"
        lines: list[str] = []
        for item in value:
            if isinstance(item, dict):
                lines.append(f"{prefix}-")
                lines.append(_dump_mapping(item, indent + 2, inline_root=True))
            else:
                rendered = _dump_inline(item).strip()
                lines.append(f"{prefix}- {rendered}\n")
        return "".join(lines)
    if isinstance(value, dict):
        return _dump_mapping(value, indent, inline_root=False)
    raise YAMLError(f"unsupported type for dump: {type(value)!r}")


def _dump_mapping(mapping: dict[str, Any], indent: int, *, inline_root: bool) -> str:
    if not mapping:
        return f"{' ' * indent}{{}}\n"
    lines: list[str] = []
    for key, value in mapping.items():
        prefix = " " * indent
        if value is None:
            lines.append(f"{prefix}{key}: null\n")
        elif isinstance(value, bool):
            lines.append(f"{prefix}{key}: {str(value).lower()}\n")
        elif isinstance(value, int):
            lines.append(f"{prefix}{key}: {value}\n")
        elif isinstance(value, str):
            if _needs_quotes(value):
                escaped = value.replace("\\", "\\\\").replace('"', '\\"')
                lines.append(f'{prefix}{key}: "{escaped}"\n')
            else:
                lines.append(f"{prefix}{key}: {value}\n")
        elif isinstance(value, dict):
            if not value:
                lines.append(f"{prefix}{key}: {{}}\n")
            else:
                lines.append(f"{prefix}{key}:\n")
                lines.append(_dump_mapping(value, indent + 2, inline_root=False))
        elif isinstance(value, list):
            if not value:
                lines.append(f"{prefix}{key}: []\n")
            else:
                lines.append(f"{prefix}{key}:\n")
                lines.append(_dump_value(value, indent + 2))
        else:
            raise YAMLError(f"unsupported type for dump: {type(value)!r}")
    return "".join(lines)


def _dump_inline(value: Any) -> str:
    if value is None:
        return "null\n"
    if isinstance(value, bool):
        return f"{str(value).lower()}\n"
    if isinstance(value, int):
        return f"{value}\n"
    if isinstance(value, str):
        if _needs_quotes(value):
            escaped = value.replace("\\", "\\\\").replace('"', '\\"')
            return f'"{escaped}"\n'
        return f"{value}\n"
    raise YAMLError(f"unsupported inline type: {type(value)!r}")


def _needs_quotes(text: str) -> bool:
    if not text:
        return True
    if text[0] in ("'", '"', "#", "-", ":", "@", "`"):
        return True
    lowered = text.lower()
    if lowered in ("null", "~", "true", "false", "yes", "no", "on", "off"):
        return True
    if re.fullmatch(r"-?\d+", text):
        return True
    if set(text) & {":", "{", "}", "[", "]", ",", "#", "&", "*", "!", "|", ">", "'", '"', "%", "@", "`"}:
        return True
    return False
