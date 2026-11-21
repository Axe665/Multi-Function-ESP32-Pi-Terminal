#!/usr/bin/env python3
"""Create and validate host modules without loading native code.

This is intentionally a thin developer-facing wrapper around the repository's
existing C ABI and package_tool.py. It never flashes hardware or installs a
module into a running terminal.
"""
import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import platform
from pathlib import Path

KIT = Path(__file__).resolve().parent
ROOT = KIT.parent
TEMPLATE = KIT / "template"
DEFAULT_AARCH64_TOOLCHAIN = KIT / "toolchain" / "module-aarch64.cmake"


def sdk_artifacts_root():
    """定位 dist/sdk 三件套（qt653-arm64 / host-qt / pi-sysroot）。

    devkit 有三种落点，不能只看 KIT.parent：
      <仓库根>/module-devkit                    主 devkit
      旧 SDK 快照里的 module-devkit         兼容探测
      <任意目录>/module-devkit                  独立 SDK
    三件套也可能被使用者放在 devkit 旁边（<devkit>/dist/sdk）。与 toolchain 的
    探测顺序保持一致，两处都改才对得上。
    """
    for base in (KIT, KIT.parent, KIT.parent.parent, KIT.parent.parent.parent):
        candidate = base / "dist" / "sdk"
        if (candidate / "qt653-arm64").exists() or (candidate / "pi-sysroot").exists():
            return candidate
    return KIT.parent / "dist" / "sdk"
REQUIRED = ("id", "name", "version", "module_id", "package_id", "package_version",
            "host_arch", "library", "qml_page", "abi_version", "min_host_api",
            "qt_major", "unload_contract",
            # A-2：宿主 ModuleManager::verifyManifest 强制这四项，devkit 少校验
            # 会让「devkit 全绿、宿主拒载」。
            "control_protocol", "data_protocol", "max_payload", "capabilities")

# A-1：与宿主 DataSchema.cpp::parseManifest 等价的校验规则。
# 改这里必须同步：pi_terminal/src/core/DataSchema.cpp、两份 package_tool.py。
RECORD_NAME_RE = re.compile(r"^[a-z][a-z0-9_]*\.[a-z][a-z0-9_]*$")
FIELD_NAME_RE = re.compile(r"^[a-z][a-z0-9_]*$")
KINDS = ("sample", "measurement", "reading", "event")
FIELD_TYPES = ("int", "double", "bool", "string", "enum")
# A-3：保留字段名。宿主 append()/appendBatch() 会把这些键当元数据剥离，
# 声明成业务字段只会静默丢数据，解析期直接拒载。
RESERVED_FIELDS = ("valid", "recorded_at", "source", "invalid_reason")
SCHEMA_TOP_KEYS = ("version", "records", "kv_keys", "attachments")
RECORD_KEYS = ("kind", "label", "retention_days", "fields")
FIELD_KEYS = ("type", "unit", "min", "max", "required", "enum", "label", "description")


def _is_int(value):
    return isinstance(value, int) and not isinstance(value, bool)


def _enum_value_matches(field_type, value):
    if field_type == "int":
        return _is_int(value)
    if field_type == "double":
        return isinstance(value, (int, float)) and not isinstance(value, bool)
    if field_type == "bool":
        return isinstance(value, bool)
    if field_type == "string":
        return isinstance(value, str)
    return isinstance(value, (str, int, float, bool))


def validate_data_schema(schema):
    """宿主 data_schema 校验规则的 Python 移植；返回错误串，None = 通过。

    规则以 pi_terminal/src/core/DataSchema.cpp::parseManifest 为准，覆盖
    契约 contracts/manifest/data-schema.v1.json 的约束（含 A-3 保留名）。
    """
    if not isinstance(schema, dict):
        return "MANIFEST_SCHEMA_MISSING: data_schema 必须是对象"
    for key in schema:
        if key not in SCHEMA_TOP_KEYS:
            return f"data_schema 未定义键: {key}"
    if not _is_int(schema.get("version")) or schema.get("version") != 1:
        return "UNSUPPORTED_VERSION: 宿主仅支持 data_schema.version=1"
    attachments = schema.get("attachments")
    if attachments is not None and not isinstance(attachments, bool):
        return "data_schema.attachments 必须是 bool"
    records = schema.get("records")
    if not isinstance(records, dict) or not records:
        return "data_schema.records 必须是非空对象"
    if len(records) > 128:
        return "data_schema.records 超过 128 条"
    for name, record in records.items():
        if not isinstance(name, str) or not RECORD_NAME_RE.fullmatch(name):
            return f"记录名不合法: {name}（必须 kind.semantic，小写字母/数字/下划线）"
        if not isinstance(record, dict):
            return f"{name}: record 必须是对象"
        for key in record:
            if key not in RECORD_KEYS:
                return f"{name}: 未定义键 {key}"
        kind = record.get("kind")
        if kind not in KINDS:
            return f"{name}: kind 必须是 {'/'.join(KINDS)}"
        if name.split(".", 1)[0] != kind:
            return f"{name}: kind 必须与记录名前缀一致"
        if "label" in record:
            label = record["label"]
            if not isinstance(label, str) or not label or len(label) > 64:
                return f"{name}: label 必须是非空字符串且 ≤64 字符"
        if "retention_days" in record:
            retention = record["retention_days"]
            if not _is_int(retention) or not 1 <= retention <= 3650:
                return f"{name}: retention_days 必须是 1..3650 的整数"
        fields = record.get("fields")
        if not isinstance(fields, dict) or not fields:
            return f"{name}: fields 必须是非空对象"
        if len(fields) > 64:
            return f"{name}: 字段数超过 64"
        for field_name, field in fields.items():
            prefix = f"{name}.{field_name}"
            if not isinstance(field_name, str) or len(field_name) > 64 \
                    or not FIELD_NAME_RE.fullmatch(field_name):
                return f"{prefix}: 字段名不合法（小写字母/数字/下划线，≤64）"
            if field_name in RESERVED_FIELDS:
                return (f"SCHEMA_RESERVED_FIELD: {prefix}"
                        f"（{'/'.join(RESERVED_FIELDS)} 由宿主占用，不能声明为业务字段）")
            if not isinstance(field, dict):
                return f"{prefix}: field 必须是对象"
            for key in field:
                if key not in FIELD_KEYS:
                    return f"{prefix}: 未定义键 {key}"
            field_type = field.get("type")
            if field_type not in FIELD_TYPES:
                return f"{prefix}: type 必须是 {'/'.join(FIELD_TYPES)}"
            if "required" in field and not isinstance(field["required"], bool):
                return f"{prefix}: required 必须是 bool"
            if "unit" in field:
                unit = field["unit"]
                if not isinstance(unit, str) or not unit or len(unit) > 32:
                    return f"{prefix}: unit 必须是非空字符串且 ≤32 字符"
            has_min, has_max = "min" in field, "max" in field
            for edge in ("min", "max"):
                if edge in field:
                    edge_value = field[edge]
                    if not isinstance(edge_value, (int, float)) or isinstance(edge_value, bool):
                        return f"{prefix}: {edge} 必须是数值"
            if has_min and has_max and field["min"] > field["max"]:
                return f"{prefix}: min > max"
            if field_type in ("bool", "string", "enum") and (has_min or has_max):
                return f"{prefix}: min/max 只适用于 int/double"
            enum_values = field.get("enum")
            if enum_values is not None:
                if not isinstance(enum_values, list) or not 1 <= len(enum_values) <= 64:
                    return f"{prefix}: enum 必须是 1..64 项的数组"
                seen = set()
                for item in enum_values:
                    if not _enum_value_matches(field_type, item):
                        return f"{prefix}: enum 值类型与 type 不符"
                    marker = json.dumps(item, ensure_ascii=False, sort_keys=True)
                    if marker in seen:
                        return f"{prefix}: enum 值重复"
                    seen.add(marker)
            elif field_type == "enum":
                return f"{prefix}: type=enum 必须提供 enum"
    if "kv_keys" in schema:
        kv_keys = schema["kv_keys"]
        if not isinstance(kv_keys, list) or len(kv_keys) > 64:
            return "kv_keys 必须是 ≤64 项的数组"
        seen = set()
        for item in kv_keys:
            if not isinstance(item, str) or len(item) > 64 or not FIELD_NAME_RE.fullmatch(item):
                return "kv_keys 项必须是小写字母/数字/下划线且 ≤64"
            if item in seen:
                return f"kv_keys 重复: {item}"
            seen.add(item)
    return None


def load_manifest(folder, require_binary=True, require_v3=True, require_data_schema=True):
    path = Path(folder) / "manifest.json"
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise SystemExit(f"invalid manifest.json: {exc}")
    missing = [key for key in REQUIRED if key not in value]
    if missing: raise SystemExit("manifest missing: " + ", ".join(missing))
    if not re.fullmatch(r"[a-z0-9][a-z0-9._-]*", value["id"]):
        raise SystemExit("manifest id must contain lowercase letters, digits, '.', '_' or '-'")
    if not isinstance(value["module_id"], int) or not 1 <= value["module_id"] <= 255:
        raise SystemExit("module_id must be an integer from 1 to 255")
    if value["abi_version"] != 1 or not 1 <= value["min_host_api"] <= 3:
        raise SystemExit("only ABI 1 and host API 1..3 are supported")
    if value["qt_major"] != 6 or value["unload_contract"] != "synchronous-stop-v1":
        raise SystemExit("module must target Qt 6 and synchronous-stop-v1")
    if require_v3:
        if value.get("platform_api") != 2:
            raise SystemExit("platform_api must be 2 (v3 host)")
        if value.get("network_api") not in ("broker", "none"):
            raise SystemExit("network_api must be broker or none")
        if value.get("file_api", "none") not in ("none", "home-read"):
            raise SystemExit("file_api must be none or home-read")
        # 宿主接受 min_host_api 1..3；v3 模块推荐 3，但不再强制 —— 强制会让
        # devkit 比宿主更严，造成反向不同构（A-1/A-2）。
    if require_data_schema:
        schema = value.get("data_schema")
        if not isinstance(schema, dict):
            raise SystemExit("MANIFEST_SCHEMA_MISSING: data_schema.version=1 and records are required")
        error = validate_data_schema(schema)
        if error:
            raise SystemExit(error)
    # A-2：与宿主 ModuleManager::verifyManifest 对齐的四项校验（缺了就是
    # 「devkit 通过、宿主拒载」）。
    control_protocol = value.get("control_protocol")
    data_protocol = value.get("data_protocol")
    if not isinstance(control_protocol, str) or not control_protocol.strip() \
            or len(control_protocol) > 64 \
            or not isinstance(data_protocol, str) or not data_protocol.strip() \
            or len(data_protocol) > 64:
        raise SystemExit("MANIFEST_PROTOCOL_MISSING: control_protocol/data_protocol 必须非空且 ≤64 字符")
    max_payload = value.get("max_payload")
    if not _is_int(max_payload) or not 1 <= max_payload <= 65536:
        raise SystemExit("MANIFEST_MAX_PAYLOAD_INVALID: max_payload 必须是 1..65536 的整数")
    capabilities = value.get("capabilities")
    if not isinstance(capabilities, list) or len(capabilities) > 32:
        raise SystemExit("MANIFEST_CAPABILITIES_INVALID: capabilities 必须是 ≤32 项的数组")
    for capability in capabilities:
        if not isinstance(capability, str) or not capability.strip() or len(capability) > 64:
            raise SystemExit("MANIFEST_CAPABILITIES_INVALID: capabilities 项必须是非空字符串且 ≤64 字符")
    for key in ("library", "qml_page"):
        relative = Path(value[key])
        if relative.is_absolute() or ".." in relative.parts:
            raise SystemExit(f"manifest path escapes package: {value[key]}")
        if key == "library" and not require_binary:
            continue
        path = Path(folder) / relative
        candidates = [path]
        if key == "library":
            candidates.extend((Path(folder) / "build" / relative,
                               Path(folder) / "build" / ("lib" + relative.name
                               if not relative.name.startswith("lib") else relative.name)))
        if not any(candidate.is_file() for candidate in candidates):
            raise SystemExit(f"manifest entry does not exist: {value[key]}")
    return value

LEGACY_RECORDS = {
    "Sample": ("sample.environment", "sample"),
    "Measurement": ("measurement.blood_pressure", "measurement"),
    "Reading": ("reading.generic", "reading"),
}
# A-8：宿主内置 legacy 字段表（pi_terminal/src/core/ModuleDataApi.cpp 的
# legacyFieldsFor()）。schema init 以它为最小骨架，而不是「全库扫描猜类型」；
# 改这里必须同步宿主 legacyFieldsFor()。
LEGACY_SCHEMA = {
    "sample.environment": ("sample", {
        "temperature_c": "double", "humidity_rh": "double", "pressure_hpa": "double",
        "light_lux": "double", "battery_v": "double", "battery_pct": "int"}),
    "measurement.blood_pressure": ("measurement", {
        "systolic": "int", "diastolic": "int", "pulse": "int",
        "unit": "string", "device_model": "string", "measured_at": "int"}),
    "reading.generic": ("reading", {
        "metric": "string", "value": "double", "unit": "string",
        "device_model": "string", "measured_at": "int"}),
}
LEGACY_METADATA = {"source", "valid", "invalid_reason", "device_id", "device_model",
                   "sample_seq", "measured_at", "unit", "metric"}
# appData.append/appendBatch 在宿主侧会把这几项从 payload 里拿走，不参与 schema 校验。
APPEND_METADATA = {"source", "valid", "invalid_reason", "recorded_at"}

APPEND_CALL_RE = re.compile(
    r'\b(?:appData|moduleData)\s*\.\s*'
    r'(appendBatch|append|appendSample|appendMeasurement|appendReading)\s*\(')
VAR_DECL_RE = re.compile(r'\b(?:const|let|var)\s+([A-Za-z_$][A-Za-z0-9_$]*)\s*=\s*')
FUNC_DECL_RE = re.compile(r'\bfunction\s+([A-Za-z_$][A-Za-z0-9_$]*)\s*\(')
FUNC_EXPR_RE = re.compile(
    r'\b(?:const|let|var)\s+([A-Za-z_$][A-Za-z0-9_$]*)\s*=\s*'
    r'(?:async\s*)?function\s*\(')
ARROW_RE = re.compile(
    r'\b(?:const|let|var)\s+([A-Za-z_$][A-Za-z0-9_$]*)\s*=\s*'
    r'(?:async\s*)?(?:\([^()]*\)|[A-Za-z_$][A-Za-z0-9_$]*)\s*=>\s*')
FIELD_ASSIGN_RE = re.compile(
    r'\b([A-Za-z_$][A-Za-z0-9_$]*)\s*\.\s*([A-Za-z_$][A-Za-z0-9_$]*)\s*=\s*')
BRACKET_ASSIGN_RE = re.compile(
    r'\b([A-Za-z_$][A-Za-z0-9_$]*)\s*\[\s*([^\]]+)\s*\]\s*=\s*')
PROPERTY_DECL_RE = re.compile(
    r'\b(?:readonly\s+)?property\s+(var|string|int|double|real|bool)\s+'
    r'([A-Za-z_$][A-Za-z0-9_$]*)')
PROPERTY_INIT_RE = re.compile(
    r'\b(?:readonly\s+)?property\s+(?:var|string|int|double|real|bool)\s+'
    r'([A-Za-z_$][A-Za-z0-9_$]*)\s*:\s*')
QML_TYPE = {"string": "string", "int": "int", "double": "double",
            "real": "double", "bool": "bool", "var": None}

# C++ 侧的 append* 调用。emit_event 的载荷是线上遥测，不是 data_schema；
# 这里只认带明确 record 名的 append*，避免把 history_*/power_*/segments 误报。
CPP_MAP_PREFIX_RE = re.compile(r'\b(?:QVariantMap|QJsonObject|QMap\s*<\s*QString\s*,\s*QVariant\s*>)\s*\{')
CPP_OBJECT_DECL_RE = re.compile(
    r'\b(?:QVariantMap|QJsonObject|QMap\s*<\s*QString\s*,\s*QVariant\s*>)\s+'
    r'([A-Za-z_$][A-Za-z0-9_$]*)\s*(\{|\=)')
CPP_INSERT_RE = re.compile(
    r'\b([A-Za-z_$][A-Za-z0-9_$]*)\s*(?:\.|->)\s*insert\s*\(\s*'
    r'(?:QStringLiteral|QString|QLatin1String)\s*\(\s*["\']([^"\']+)["\']\s*\)')
CPP_LEGACY_CALL_RE = re.compile(
    r'(?<![\w.])(appendSample|appendMeasurement|appendReading)\s*\(')


class ScanIssue:
    def __init__(self, path, line, message):
        self.path = path
        self.line = line
        self.message = message


class ScanResult:
    """静态扫描结果：可推断的记录字段 + 无法静态验证的位置。"""

    def __init__(self):
        self.records = {}
        self.issues = []
        self.calls = 0
        self._issue_keys = set()

    def add_issue(self, path, line, message):
        key = (str(path), line, message)
        if key in self._issue_keys:
            return
        self._issue_keys.add(key)
        self.issues.append(ScanIssue(str(path), line, message))

def _line_of(text, offset):
    return text.count("\n", 0, max(0, offset)) + 1


def _skip_string(text, index):
    quote = text[index]
    index += 1
    while index < len(text):
        if text[index] == "\\":
            index += 2
        elif text[index] == quote:
            return index + 1
        else:
            index += 1
    return index


def _strip_comments(text):
    """去掉注释但保留字符串内容；字符串里的 // 不是注释。"""
    out = list(text)
    index = 0
    while index < len(text):
        char = text[index]
        if char in "\"'`":
            index = _skip_string(text, index)
            continue
        if char == "/" and index + 1 < len(text) and text[index + 1] == "/":
            end = text.find("\n", index)
            if end < 0:
                end = len(text)
            for pos in range(index, end):
                out[pos] = " "
            index = end
            continue
        if char == "/" and index + 1 < len(text) and text[index + 1] == "*":
            end = text.find("*/", index + 2)
            end = len(text) if end < 0 else end + 2
            for pos in range(index, end):
                if out[pos] != "\n":
                    out[pos] = " "
            index = end
            continue
        index += 1
    return "".join(out)


def _find_matching(text, start):
    """start 指向 ( [ { 之一，返回匹配的闭括号下标；失败返回 -1。"""
    pairs = {"(": ")", "[": "]", "{": "}"}
    stack = []
    index = start
    while index < len(text):
        char = text[index]
        if char in "\"'`":
            index = _skip_string(text, index)
            continue
        if char in pairs:
            stack.append(pairs[char])
        elif char in ")]}":
            if not stack or stack[-1] != char:
                return -1
            stack.pop()
            if not stack:
                return index
        index += 1
    return -1


def _split_top_level(body):
    parts = []
    depth = 0
    start = 0
    index = 0
    while index < len(body):
        char = body[index]
        if char in "\"'`":
            index = _skip_string(body, index)
            continue
        if char in "([{":
            depth += 1
        elif char in ")]}":
            depth -= 1
        elif char == "," and depth == 0:
            part = body[start:index].strip()
            if part:
                parts.append(part)
            start = index + 1
        index += 1
    part = body[start:].strip()
    if part:
        parts.append(part)
    return parts


def _read_expression(text, start):
    index = start
    while index < len(text) and text[index].isspace():
        index += 1
    begin = index
    depth = 0
    while index < len(text):
        char = text[index]
        if char in "\"'`":
            index = _skip_string(text, index)
            continue
        if char in "([{":
            depth += 1
        elif char in ")]}":
            if depth == 0:
                break
            depth -= 1
        elif depth == 0 and (char in ";\n" or char == ","):
            break
        index += 1
    return text[begin:index].strip()


def _infer_literal_type(value):
    value = value.strip()
    if value.startswith(('"', "'", "`")):
        return "string"
    if value in ("true", "false"):
        return "bool"
    if value in ("null", "undefined"):
        return None
    if re.fullmatch(r"-?\d+", value):
        return "int"
    if re.fullmatch(r"-?\d+\.\d+(?:[eE][+-]?\d+)?", value):
        return "double"
    return None


def _resolve_type(expr, env, functions, result, path, line, depth=0):
    """尽力推断一个表达式的标量类型；推断不了返回 None（不猜）。"""
    expr = expr.strip()
    if not expr:
        return None
    literal = _infer_literal_type(expr)
    if literal:
        return literal
    if expr.startswith("("):
        close = _find_matching(expr, 0)
        if close == len(expr) - 1:
            return _resolve_type(expr[1:close], env, functions, result, path, line, depth + 1)
    if expr.startswith("!"):
        return "bool"
    if re.match(r"Boolean\s*\(", expr):
        return "bool"
    if re.match(r"parseInt\s*\(", expr):
        return "int"
    if re.match(r"(?:String|JSON\.stringify)\s*\(", expr):
        return "string"
    if re.match(r"(?:Date\.now|performance\.now)\s*\(", expr):
        return "int"
    member = re.fullmatch(
        r"([A-Za-z_$][A-Za-z0-9_$]*)\s*\.\s*([A-Za-z_$][A-Za-z0-9_$]*)", expr)
    if member:
        target = env.get(member.group(1))
        return target.get(member.group(2)) if isinstance(target, dict) else None
    if re.fullmatch(r"[A-Za-z_$][A-Za-z0-9_$]*", expr):
        value = env.get(expr)
        return value if isinstance(value, str) else None
    return None


def _cpp_key(expr):
    """从 C++ 的 QStringLiteral("x") / "x" / QString("x") 里取字段名。"""
    expr = expr.strip()
    match = re.fullmatch(r"([\"'])(.*?)\1", expr, re.S)
    if match:
        return match.group(2)
    match = re.fullmatch(
        r"(?:QStringLiteral|QString|QLatin1String|QString::fromLatin1)\s*\(\s*"
        r"([\"'])(.*?)\1\s*\)", expr, re.S)
    if match:
        return match.group(2)
    return None


def _parse_cpp_map(body, result, path, line, report):
    """QVariantMap{{"k", v}, ...} / QJsonObject{{QStringLiteral("k"), v}, ...}。

    C++ 只认字段名，不猜类型：schema check 只回答“字段有没有声明”，
    schema init 也不会拿 C++ 表达式伪造类型。
    """
    fields = {}
    for part in _split_top_level(body):
        entry = part.strip()
        if not entry:
            continue
        if entry.startswith("{") and _find_matching(entry, 0) == len(entry) - 1:
            pieces = _split_top_level(entry[1:-1])
            if not pieces:
                continue
            key = _cpp_key(pieces[0])
            if key:
                fields[key] = None
            else:
                fields["__dynamic__"] = True
                if report:
                    result.add_issue(path, line,
                                     f"dynamic C++ key cannot be verified: {pieces[0][:48]}")
            continue
        key = _cpp_key(entry)
        if key:
            fields[key] = None
    return fields


def _resolve_object(expr, env, functions, result, path, line, depth=0, report=False):
    """把一个表达式解析成 {field: type-or-None}；无法确定返回 None。

    report=False 用于探索变量（不产生警告）；只有 append 的参数才 report=True，
    避免把文件里每个普通对象/函数调用都报成 schema 问题。
    """
    expr = expr.strip()
    if not expr:
        return None
    if depth > 8:
        if report:
            result.add_issue(path, line, "payload nesting too deep; static resolution stopped")
        return None
    cpp_map = CPP_MAP_PREFIX_RE.match(expr)
    if cpp_map:
        open_pos = expr.find("{", cpp_map.start())
        close = _find_matching(expr, open_pos)
        if close > open_pos:
            return _parse_cpp_map(expr[open_pos + 1:close], result, path, line, report)
    if expr.startswith("{"):
        close = _find_matching(expr, 0)
        if close == len(expr) - 1:
            return _parse_object(expr[1:close], env, functions, result, path, line,
                                 depth, report)
    if expr.startswith("("):
        close = _find_matching(expr, 0)
        if close == len(expr) - 1:
            return _resolve_object(expr[1:close], env, functions, result, path, line,
                                   depth + 1, report)
    assign = re.match(r"Object\.(assign|freeze)\s*\(", expr)
    if assign:
        open_pos = expr.find("(", assign.start())
        close = _find_matching(expr, open_pos)
        if close < 0:
            return None
        args = _split_top_level(expr[open_pos + 1:close])
        if assign.group(1) == "freeze":
            return (_resolve_object(args[0], env, functions, result, path, line,
                                    depth + 1, report) if args else None)
        merged = {}
        for arg in args:
            if arg.strip() == "{}":
                continue
            obj = _resolve_object(arg, env, functions, result, path, line,
                                  depth + 1, report)
            if obj is None:
                if report:
                    result.add_issue(path, line,
                                     "Object.assign() argument cannot be resolved statically")
                continue
            merged.update(obj)
        return merged
    if re.fullmatch(r"[A-Za-z_$][A-Za-z0-9_$]*", expr):
        value = env.get(expr)
        if not isinstance(value, dict):
            return None
        if report and value.get("__dynamic__"):
            result.add_issue(path, line,
                             f"{expr} contains a computed key; cannot verify statically")
        return {name: kind for name, kind in value.items() if not name.startswith("__")}
    call = re.fullmatch(r"([A-Za-z_$][A-Za-z0-9_$]*)\s*\(.*\)", expr, re.S)
    if call:
        return _resolve_function(call.group(1), env, functions, result, path, line,
                                 depth + 1, report)
    return None


def _parse_object(body, env, functions, result, path, line, depth, report):
    fields = {}
    for part in _split_top_level(body):
        if part.startswith("..."):
            spread = _resolve_object(part[3:], env, functions, result, path, line,
                                     depth + 1, report)
            if spread is None:
                if report:
                    result.add_issue(path, line,
                                     f"spread source cannot be resolved: {part[:48]}")
            else:
                fields.update(spread)
            continue
        if part.startswith("["):
            # 变量里遇到动态键时先打标记；等这个变量真的被 append 用到再告警。
            fields["__dynamic__"] = True
            if report:
                result.add_issue(path, line,
                                 f"computed key cannot be verified statically: {part[:48]}")
            continue
        match = (re.match(r'^"([^"]+)"\s*:\s*(.*)$', part, re.S)
                 or re.match(r"^'([^']+)'\s*:\s*(.*)$", part, re.S)
                 or re.match(r'^([A-Za-z_$][A-Za-z0-9_$]*)\s*:\s*(.*)$', part, re.S))
        if match:
            fields[match.group(1)] = _resolve_type(
                match.group(2), env, functions, result, path, line, depth + 1)
            continue
        shorthand = re.fullmatch(r"[A-Za-z_$][A-Za-z0-9_$]*", part)
        if shorthand:
            fields[part] = None
            continue
        if re.match(r"^[A-Za-z_$][A-Za-z0-9_$]*\s*\(", part):
            continue
        if report:
            result.add_issue(path, line, f"object entry cannot be parsed: {part[:48]}")
    return fields


def _extract_returns(body):
    returns = []
    depth = 0
    index = 0
    while index < len(body):
        char = body[index]
        if char in "\"'`":
            index = _skip_string(body, index)
            continue
        if char == "{":
            depth += 1
            index += 1
            continue
        if char == "}":
            depth = max(0, depth - 1)
            index += 1
            continue
        if depth == 0 and body.startswith("return", index):
            before = body[index - 1] if index else ""
            after = body[index + 6] if index + 6 < len(body) else ""
            if ((not before or not (before.isalnum() or before in "_$"))
                    and (not after or not (after.isalnum() or after in "_$"))):
                expr = _read_expression(body, index + 6)
                if expr:
                    returns.append(expr)
                index += 6
                continue
        index += 1
    return returns


def _collect_functions(text, path, result):
    functions = {}

    def add(name, body, expr, line):
        functions.setdefault(name, {"body": body, "expr": expr,
                                    "path": path, "line": line})

    for match in FUNC_DECL_RE.finditer(text):
        close = _find_matching(text, match.end() - 1)
        if close < 0:
            continue
        brace = text.find("{", close + 1)
        if brace < 0 or text[close + 1:brace].strip():
            continue
        end = _find_matching(text, brace)
        if end > brace:
            add(match.group(1), text[brace + 1:end], None, _line_of(text, match.start()))

    for match in FUNC_EXPR_RE.finditer(text):
        close = _find_matching(text, match.end() - 1)
        if close < 0:
            continue
        brace = text.find("{", close + 1)
        if brace < 0:
            continue
        end = _find_matching(text, brace)
        if end > brace:
            add(match.group(1), text[brace + 1:end], None, _line_of(text, match.start()))

    for match in ARROW_RE.finditer(text):
        pos = match.end()
        while pos < len(text) and text[pos].isspace():
            pos += 1
        if pos >= len(text):
            continue
        if text[pos] == "{":
            end = _find_matching(text, pos)
            if end > pos:
                add(match.group(1), text[pos + 1:end], None,
                    _line_of(text, match.start()))
        elif text[pos] == "(":
            end = _find_matching(text, pos)
            if end > pos:
                add(match.group(1), "", text[pos:end + 1],
                    _line_of(text, match.start()))
    return functions


def _collect_variables(text, functions, result, path, base_env=None):
    env = dict(base_env or {})
    for match in PROPERTY_DECL_RE.finditer(text):
        env[match.group(2)] = QML_TYPE[match.group(1)]
    for match in PROPERTY_INIT_RE.finditer(text):
        name = match.group(1)
        expr = _read_expression(text, match.end())
        if not expr or expr.startswith("{"):
            # `property string x: { ... }` 是 QML 绑定块，不是对象字面量；
            # 对象字面量在 QML 里必须写成 `({ ... })`。
            continue
        obj = _resolve_object(expr, env, functions, result, path,
                              _line_of(text, match.start()))
        if obj is not None:
            env[name] = obj
        else:
            kind = _resolve_type(expr, env, functions, result, path,
                                 _line_of(text, match.start()))
            if kind:
                env[name] = kind
    for match in VAR_DECL_RE.finditer(text):
        name = match.group(1)
        expr = _read_expression(text, match.end())
        if not expr:
            continue
        line = _line_of(text, match.start())
        obj = _resolve_object(expr, env, functions, result, path, line)
        if obj is not None:
            env[name] = obj
            continue
        kind = _resolve_type(expr, env, functions, result, path, line)
        if kind:
            env[name] = kind
    for match in CPP_OBJECT_DECL_RE.finditer(text):
        name = match.group(1)
        start = match.end() - 1 if match.group(2) == "{" else match.end()
        expr = _read_expression(text, start)
        if not expr.startswith("{"):
            continue
        close = _find_matching(expr, 0)
        if close == len(expr) - 1:
            env[name] = _parse_cpp_map(expr[1:close], result, path,
                                       _line_of(text, match.start()), report=False)
    for match in FIELD_ASSIGN_RE.finditer(text):
        target, field = match.group(1), match.group(2)
        current = env.get(target)
        if not isinstance(current, dict):
            continue
        expr = _read_expression(text, match.end())
        if not expr:
            continue
        current[field] = _resolve_type(expr, env, functions, result, path,
                                       _line_of(text, match.start()))
    for match in BRACKET_ASSIGN_RE.finditer(text):
        target, key = match.group(1), match.group(2).strip()
        current = env.get(target)
        if not isinstance(current, dict):
            continue
        literal = _cpp_key(key)
        if not literal:
            # 先标记；等这个对象真的被 append 用到再告警，避免误报普通 UI 字典。
            current["__dynamic__"] = True
            continue
        expr = _read_expression(text, match.end())
        current[literal] = _resolve_type(
            expr, env, functions, result, path, _line_of(text, match.start()))
    for match in CPP_INSERT_RE.finditer(text):
        target, key = match.group(1), match.group(2)
        current = env.get(target)
        if not isinstance(current, dict):
            current = {}
            env[target] = current
        current[key] = None
    return env


def _resolve_function(name, caller_env, functions, result, path, line, depth=0, report=False):
    function = functions.get(name)
    if not function:
        if report:
            result.add_issue(path, line, f"cannot resolve function {name}()")
        return None
    if depth > 8:
        return None
    local = _collect_variables(function["body"], functions, result,
                               function["path"], caller_env)
    if function["expr"] is not None:
        obj = _resolve_object(function["expr"], local, functions, result,
                              function["path"], function["line"], depth + 1, report)
        if obj is None and report:
            result.add_issue(function["path"], function["line"],
                             f"function {name}() return value cannot be resolved statically")
        return obj
    merged = {}
    resolved = False
    for expr in _extract_returns(function["body"]):
        obj = _resolve_object(expr, local, functions, result,
                              function["path"], function["line"], depth + 1, report)
        if obj is None:
            if report:
                result.add_issue(function["path"], function["line"],
                                 f"function {name}() return value cannot be resolved statically")
            continue
        merged.update(obj)
        resolved = True
    return merged if resolved else None


def _merge_fields(result, record, fields, path, line):
    target = result.records.setdefault(record, {})
    for name, kind in fields.items():
        if name.startswith("__") or name in APPEND_METADATA:
            continue
        if name not in target:
            target[name] = kind
        elif target[name] is None and kind is not None:
            target[name] = kind
        elif kind is not None and target[name] is not None and target[name] != kind:
            result.add_issue(path, line,
                             f"{record}.{name}: inferred type {kind} conflicts with {target[name]}")


def _record_name(arg, result, path, line):
    arg = arg.strip()
    key = _cpp_key(arg)
    if key:
        return key
    result.add_issue(path, line, f"dynamic record name cannot be verified: {arg[:48]}")
    return None


def _scan_payload(result, record, expr, env, functions, path, line, legacy=False):
    obj = _resolve_object(expr, env, functions, result, path, line, report=True)
    if obj is None:
        result.add_issue(path, line, f"payload for {record} cannot be resolved statically")
        return
    if legacy:
        obj = {name: kind for name, kind in obj.items() if name not in LEGACY_METADATA}
    _merge_fields(result, record, obj, path, line)


def _scan_file(path, text, functions, result):
    env = _collect_variables(text, functions, result, path)
    for match in APPEND_CALL_RE.finditer(text):
        method = match.group(1)
        line = _line_of(text, match.start())
        open_pos = match.end() - 1
        close = _find_matching(text, open_pos)
        if close < 0:
            result.add_issue(path, line, f"{method}() call is not closed")
            continue
        args = _split_top_level(text[open_pos + 1:close])
        result.calls += 1
        if method == "appendBatch":
            if len(args) < 2:
                result.add_issue(path, line, "appendBatch() needs record and rows")
                continue
            record = _record_name(args[0], result, path, line)
            if not record:
                continue
            rows = args[1].strip()
            if not (rows.startswith("[") and _find_matching(rows, 0) == len(rows) - 1):
                result.add_issue(path, line,
                                 f"appendBatch() rows for {record} are not an array literal")
                continue
            for row in _split_top_level(rows[1:-1]):
                _scan_payload(result, record, row, env, functions, path, line)
        elif method == "append":
            if len(args) < 2:
                result.add_issue(path, line, "append() needs record and payload")
                continue
            record = _record_name(args[0], result, path, line)
            if not record:
                continue
            _scan_payload(result, record, args[1], env, functions, path, line)
        else:
            legacy = method[len("append"):]
            if legacy not in LEGACY_RECORDS:
                continue
            if not args:
                result.add_issue(path, line, f"{method}() needs a payload")
                continue
            _scan_payload(result, LEGACY_RECORDS[legacy][0], args[0], env,
                          functions, path, line, legacy=True)

    # C++ 模块可能直接调用 appendSample/appendMeasurement/appendReading；
    # 带 receiver 的 moduleData.appendSample 已由上面的 APPEND_CALL_RE 处理。
    # 只在 C/C++ 文件里扫：QML 里的 `function appendSample()` 是声明，不是调用。
    if path.suffix not in (".cpp", ".cc", ".cxx", ".h", ".hpp"):
        return
    for match in CPP_LEGACY_CALL_RE.finditer(text):
        method = match.group(1)
        line = _line_of(text, match.start())
        open_pos = match.end() - 1
        close = _find_matching(text, open_pos)
        if close < 0:
            result.add_issue(path, line, f"{method}() call is not closed")
            continue
        args = _split_top_level(text[open_pos + 1:close])
        result.calls += 1
        legacy = method[len("append"):]
        if legacy not in LEGACY_RECORDS:
            continue
        if not args:
            result.add_issue(path, line, f"{method}() needs a payload")
            continue
        _scan_payload(result, LEGACY_RECORDS[legacy][0], args[0], env,
                      functions, path, line, legacy=True)


def scan_sources(project):
    """静态扫描 append 调用，返回 ScanResult。

    能解析：对象字面量、变量、字段赋值、展开、Object.assign、同文件/跨文件
    函数返回值。无法静态确定的动态键、函数返回值会进入 issues，由
    schema check 打印 [WARN]；--strict 下按失败处理。宿主运行时
    DataSchema::validateRecord 仍是最终防线。
    """
    result = ScanResult()
    sources = []
    root = Path(project)
    for path in sorted(root.rglob("*")):
        if path.suffix not in (".cpp", ".cc", ".cxx", ".h", ".hpp", ".qml"):
            continue
        if "build" in path.parts or "node_modules" in path.parts:
            continue
        try:
            text = path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        sources.append((path, _strip_comments(text)))
    functions = {}
    for path, text in sources:
        functions.update(_collect_functions(text, path, result))
    for path, text in sources:
        _scan_file(path, text, functions, result)
    return result

def schema_draft(project):
    """生成 data_schema 草稿（A-8）。

    行为与文档 §3.6 对齐：以宿主 legacy 字段表为主推导最小 schema；
    源码里出现的自定义 record 仍按扫描结果补齐（类型推断不出时用 string）。
    生成的草稿必定通过 validate_data_schema（否则抛 SystemExit）。
    """
    result = scan_sources(project)
    records = {}
    for record, fields in sorted(result.records.items()):
        if not fields:
            continue
        if record in LEGACY_SCHEMA:
            kind, legacy_types = LEGACY_SCHEMA[record]
            # 只保留扫描到且属于 legacy 表的字段；扫不到字段时用整张表。
            names = [name for name in sorted(fields) if name in legacy_types]
            typed = {name: legacy_types[name] for name in names}
            if not typed:
                typed = dict(legacy_types)
        else:
            kind = record.split(".", 1)[0]
            if kind not in KINDS:
                raise SystemExit(
                    f"record {record} 的前缀不是合法 kind（{'/'.join(KINDS)}）；"
                    " 请在源码里改成 kind.semantic 形式")
            typed = {name: (typ or "string") for name, typ in sorted(fields.items())
                     if name not in RESERVED_FIELDS}
        if not typed:
            continue
        records[record] = {
            "kind": kind,
            "label": record,
            "retention_days": 365,
            "fields": {name: {"type": typ, "required": False}
                       for name, typ in sorted(typed.items())},
        }
    draft = {"version": 1, "records": records, "kv_keys": []}
    error = validate_data_schema(draft)
    if error:
        raise SystemExit(f"generated data_schema is invalid: {error}")
    return draft

def schema_init(project):
    project = Path(project).resolve()
    manifest_path = project / "manifest.json"
    manifest = load_manifest(project, require_binary=False, require_v3=False, require_data_schema=False)
    if "data_schema" in manifest:
        raise SystemExit("manifest already has data_schema; refusing to overwrite")
    draft = schema_draft(project)
    if not draft["records"]:
        raise SystemExit("no appData.append/append* calls with literal fields found; add data_schema manually")
    manifest["data_schema"] = draft
    manifest.setdefault("platform_api", 2)
    manifest.setdefault("network_api", "none")
    manifest.setdefault("file_api", "none")
    if manifest.get("min_host_api", 0) < 3:
        manifest["min_host_api"] = 3
    manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"data_schema draft written: {len(draft['records'])} records"
          "（以宿主 legacy 字段表为骨架，字段名取自源码扫描）")

def schema_check(project, strict=False):
    project = Path(project).resolve()
    manifest = load_manifest(project, require_binary=False, require_v3=False, require_data_schema=False)
    schema = manifest.get("data_schema")
    if not isinstance(schema, dict):
        raise SystemExit("MANIFEST_SCHEMA_MISSING: manifest has no data_schema")
    # A-1：check 先跑与宿主同构的 schema 校验，再比对源码字段。
    error = validate_data_schema(schema)
    if error:
        raise SystemExit("schema invalid: " + error)
    result = scan_sources(project)
    problems = []
    for record, fields in sorted(result.records.items()):
        declared = schema.get("records", {}).get(record)
        if not declared:
            problems.append(f"record not declared: {record}")
            continue
        declared_fields = declared.get("fields", {})
        for field in sorted(fields):
            if field not in declared_fields:
                problems.append(f"field not declared: {record}.{field}")
    for issue in result.issues:
        print(f"[WARN] {issue.path}:{issue.line}: {issue.message}", file=sys.stderr)
    if problems:
        for problem in problems:
            print(f"[FAIL] {problem}", file=sys.stderr)
        raise SystemExit(1)
    if strict and result.issues:
        print(f"[FAIL] {len(result.issues)} dynamic site(s) cannot be verified statically;"
              " remove --strict or make them literal", file=sys.stderr)
        raise SystemExit(1)
    suffix = (f", {len(result.issues)} dynamic site(s) not statically verifiable"
              if result.issues else "")
    print(f"schema check ok: {len(result.records)} records, {result.calls} append calls{suffix}")

def schema_migrate(project, target, force=False):
    project = Path(project).resolve()
    manifest_path = project / "manifest.json"
    manifest = load_manifest(project, require_binary=False, require_v3=False, require_data_schema=False)
    schema = manifest.get("data_schema")
    if not isinstance(schema, dict):
        raise SystemExit("MANIFEST_SCHEMA_MISSING: run schema init first")
    error = validate_data_schema(schema)
    if error:
        raise SystemExit("schema invalid before migrate: " + error)
    current = schema.get("version", 0)
    # 方案 §3.2：version 是"只增不改"的 schema 版本，但宿主当前只支持 1；
    # migrate 只做加字段/加记录，不能把 version 顶到宿主读不了的 2。
    if target > 1:
        raise SystemExit("--to > 1 is not supported by the host yet; keep data_schema.version=1")
    if target < current:
        raise SystemExit(f"--to {target} would downgrade schema version {current}")
    result = scan_sources(project)
    found = result.records
    for issue in result.issues:
        print(f"[WARN] {issue.path}:{issue.line}: {issue.message}", file=sys.stderr)
    added, removed, changed = [], [], []
    for record, fields in sorted(found.items()):
        if not fields:
            continue
        declared = schema.setdefault("records", {}).setdefault(record, {
            "kind": record.split(".", 1)[0], "label": record, "retention_days": 365, "fields": {}})
        declared_fields = declared.setdefault("fields", {})
        for field, kind in sorted(fields.items()):
            if kind is None:
                # 字段名能静态看到，但类型推断不了：保留已声明字段，不猜类型。
                continue
            if field not in declared_fields:
                declared_fields[field] = {"type": kind, "required": False}
                added.append(f"{record}.{field}")
            elif declared_fields[field].get("type") != kind:
                changed.append((record, field, declared_fields[field].get("type"), kind))
        # Only records actually seen in source are candidates for removal; a
        # record with no static append call may be populated dynamically.
        for field in sorted(set(declared_fields) - set(fields)):
            removed.append(f"{record}.{field}")

    if (removed or changed) and not force:
        print("[FAIL] schema migrate would change/remove declared fields:", file=sys.stderr)
        for item in removed:
            print(f"  - {item}", file=sys.stderr)
        for record, field, old, new in changed:
            print(f"  ~ {record}.{field}: {old} -> {new}", file=sys.stderr)
        print("re-run with --force after reviewing the impact list", file=sys.stderr)
        raise SystemExit(1)

    if force:
        # 方案 §3.6「删改字段要求显式 --force 并打印影响面」：--force 是执行前的
        # 显式确认，打印影响面后继续应用删除/修改（影响面写 stdout，便于 CI 留档）。
        print("[impact] --force 已确认，开始应用以下删改：")
        for item in removed:
            print(f"  - {item}")
        for record, field, old, new in changed:
            print(f"  ~ {record}.{field}: {old} -> {new}")
        records = schema.setdefault("records", {})
        # record 名本身带点（measurement.blood_pressure），必须从右侧切分。
        for item in removed:
            record_name, _, field_name = item.rpartition(".")
            declared = records.get(record_name)
            if isinstance(declared, dict):
                fields = declared.get("fields")
                if isinstance(fields, dict):
                    fields.pop(field_name, None)
        for record, field, _old, new in changed:
            declared = records.get(record)
            if isinstance(declared, dict):
                fields = declared.get("fields")
                if isinstance(fields, dict):
                    entry = fields.get(field)
                    if isinstance(entry, dict):
                        entry["type"] = new

    schema["version"] = 1
    error = validate_data_schema(schema)
    if error:
        raise SystemExit("schema invalid after migrate: " + error)
    manifest.setdefault("platform_api", 2)
    manifest.setdefault("network_api", "none")
    manifest.setdefault("file_api", "none")
    if manifest.get("min_host_api", 0) < 3:
        manifest["min_host_api"] = 3
    manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"schema migrated to v{target}; added {len(added)}, removed {len(removed)}, changed {len(changed)}")
    for item in added:
        print("  +", item)

def init_project(destination, module_id, name):
    destination = Path(destination)
    if destination.exists() and any(destination.iterdir()):
        raise SystemExit(f"destination is not empty: {destination}")
    destination.mkdir(parents=True, exist_ok=True)
    skip_parts = {"build", "build-test", "__pycache__", ".git"}
    for source in TEMPLATE.rglob("*"):
        if not source.is_file() or source.suffix == ".pyc" or skip_parts & set(source.parts):
            continue
        target = destination / source.relative_to(TEMPLATE)
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(source.read_text(encoding="utf-8").replace("@MODULE_ID@", str(module_id)).replace("@MODULE_NAME@", name), encoding="utf-8")
    # 占位嵌入包：只让 idf.py 能编译；签名后由 prepare-firmware 覆盖。
    firmware = destination / "firmware"
    firmware.mkdir(parents=True, exist_ok=True)
    (firmware / "embedded_package.json").write_text(json.dumps(
        {"placeholder": True, "note": "generated by module_devkit.py init; replace with a signed package"},
        ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    (firmware / "embedded_package.tar.zst").write_bytes(b"")
    print(f"created {destination}")

def stage_project(project, build, destination, arch):
    """Prepare an unsigned package; signing may stay on a separate machine."""
    project, build, destination = Path(project).resolve(), Path(build).resolve(), Path(destination).resolve()
    manifest = load_manifest(project, require_binary=False)
    arch = "aarch64" if arch == "arm64" else arch
    if arch not in ("aarch64", "x86_64") or arch not in manifest["host_arch"]:
        raise SystemExit("target architecture must be declared in host_arch")
    library = build / manifest["library"]
    if not library.is_file() or library.is_symlink(): raise SystemExit("missing/non-regular built library")
    elf = library.read_bytes()[:20]
    if elf[:6] != b'\x7fELF\x02\x01' or int.from_bytes(elf[18:20], 'little') != {"aarch64": 183, "x86_64": 62}[arch]:
        raise SystemExit("built ELF architecture differs from --arch; refusing to package")
    if destination.exists() and any(destination.iterdir()): raise SystemExit("staging directory must be empty")
    qml = project / "qml"
    if qml.is_symlink() or any(p.is_symlink() for p in qml.rglob("*")):
        raise SystemExit("symlink QML resources are not allowed")
    destination.mkdir(parents=True, exist_ok=True)
    target = destination / manifest["library"]; target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(library, target)
    shutil.copyfile(project / "manifest.json", destination / "manifest.json")
    shutil.copytree(qml, destination / "qml")
    load_manifest(destination)
    print(f"unsigned package ready: {destination}")

def _check_no_host_rpath(library, arch):
    """拒绝把开发机路径写进 RUNPATH 的产物。

    交叉编译时 CMake 默认会把链接到的 Qt 绝对路径写进 RUNPATH。模块最终跑在目标机上，
    那条路径不存在，加载会失败；而失败现场（宿主日志里的 dlopen 报错）离构建很远，
    很难联想到是构建产物的问题。所以在这里直接拦住。
    """
    if not Path(library).is_file():
        return
    library = Path(library)
    try:
        out = subprocess.run(["readelf", "-d", str(library)], capture_output=True, text=True)
    except OSError:
        return  # 没有 readelf 就跳过，不作为失败条件
    if out.returncode != 0:
        return
    for line in out.stdout.splitlines():
        if ("RPATH" not in line and "RUNPATH" not in line):
            continue
        entry = line.split("[", 1)[-1].rstrip("]").strip()
        for part in entry.split(":"):
            # $ORIGIN 之类的相对展开是安全的；绝对路径一定来自构建机。
            # 模块在目标机上由宿主进程加载，宿主自己的 RUNPATH/LD_LIBRARY_PATH
            # 决定 Qt 从哪来，模块不需要也不该带 RUNPATH。
            if part.startswith("/"):
                raise SystemExit(
                    f"{library.name} 的 RPATH/RUNPATH 含绝对路径：{part}\n"
                    "模块在目标机上按这条路径找不到 Qt。用 devkit 自带的 "
                    "<devkit>/toolchain/module-aarch64.cmake（它会关闭 RPATH），"
                    "或在你的 CMakeLists 里设置 INSTALL_RPATH \"\" / SKIP_BUILD_RPATH ON。")


def doctor():
    """检查开发机是否具备构建、签名、交叉编译模块的条件。"""
    failed = False
    for name, command in (("python3", ["python3", "--version"]),
                          ("cmake", ["cmake", "--version"]),
                          ("c++", ["c++", "--version"]),
                          ("zstd", ["zstd", "--version"]),
                          ("ctest", ["ctest", "--version"])):
        try:
            subprocess.run(command, stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL, check=True)
        except (OSError, subprocess.CalledProcessError):
            print(f"MISSING {name}")
            failed = True
        else:
            print(f"OK      {name}")
    try:
        import cryptography  # noqa: F401
    except ImportError:
        print("MISSING python package cryptography")
        failed = True
    else:
        print("OK      python package cryptography")

    qt = default_qt_prefix()
    if qt:
        print(f"OK      Qt6 host ({qt})")
    else:
        print("MISSING Qt6 host（宿主插件与离线测试需要 Qt 6.5.3 开发包）")
        failed = True

    try:
        subprocess.run(["idf.py", "--version"], stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL, check=True)
    except (OSError, subprocess.CalledProcessError):
        print("INFO    idf.py (required only for firmware builds)")
    else:
        print("OK      idf.py")

    # ---- 交叉编译 aarch64 模块所需的条件 ----
    print("-- aarch64 交叉编译（Qt 6.5.3）--")
    cross_ok = True
    compiler = None
    for candidate in ("aarch64-linux-gnu-g++-12", "aarch64-linux-gnu-g++"):
        found = shutil.which(candidate)
        if found:
            compiler = found
            break
    if compiler:
        print(f"OK      {Path(compiler).name}")
    else:
        print("MISSING aarch64-linux-gnu-g++（apt install g++-aarch64-linux-gnu）")
        cross_ok = False

    if DEFAULT_AARCH64_TOOLCHAIN.is_file():
        print(f"OK      devkit toolchain ({DEFAULT_AARCH64_TOOLCHAIN.relative_to(KIT)})")
    else:
        print(f"MISSING {DEFAULT_AARCH64_TOOLCHAIN}（devkit 自带文件缺失）")
        cross_ok = False

    # 三件套：环境变量优先，其次 dist/sdk（落点可能是仓库根，也可能是 SDK 副本）
    artifacts = sdk_artifacts_root()
    env = os.environ
    qt = env.get("ORPI_QT_PREFIX") or ""
    if not qt:
        for candidate in (artifacts / "qt653-arm64",
                          artifacts / "orpi-qt653-aarch64-dev"):
            if candidate.exists():
                qt = str(candidate)
                break
    if qt and Path(qt).exists():
        version = ""
        qconfig = Path(qt) / "mkspecs" / "qconfig.pri"
        if qconfig.is_file():
            for line in qconfig.read_text(encoding="utf-8", errors="replace").splitlines():
                if line.strip().startswith("QT_VERSION"):
                    version = line.split("=", 1)[-1].strip()
                    break
        if version and version.split(".")[:2] < ["6", "5"]:
            print(f"FAIL    aarch64 Qt 是 {version}，低于项目基线 6.5.x")
            cross_ok = False
        else:
            print(f"OK      aarch64 Qt {version or '(unknown)'} ({qt})")
    else:
        print("MISSING aarch64 Qt 6.5.3 开发树"
              "（把三件套放到 <devkit>/dist/sdk，或设置 ORPI_QT_PREFIX）")
        cross_ok = False

    sysroot = env.get("ORPI_SYSROOT") or ""
    if not sysroot and (artifacts / "pi-sysroot").exists():
        sysroot = str(artifacts / "pi-sysroot")
    if sysroot and Path(sysroot).is_dir():
        print(f"OK      aarch64 sysroot ({sysroot})")
    else:
        print("MISSING aarch64 sysroot"
              "（<devkit>/dist/sdk/pi-sysroot，或设置 ORPI_SYSROOT）")
        cross_ok = False

    if not cross_ok:
        print("INFO    交叉编译条件不全：只能构建 native 模块（--arch x86_64）")
    return failed


def release_project(project, output, key, arch, toolchain=None, firmware_mode=None, sdkconfig=None):
    project, output = Path(project).resolve(), Path(output).resolve()
    manifest = load_manifest(project, require_binary=False)
    if arch == "native":
        arch = "aarch64" if platform.machine() in ("aarch64", "arm64") else "x86_64"
    if arch not in ("aarch64", "x86_64"):
        raise SystemExit("--arch must be native, aarch64, or x86_64")
    if arch not in manifest["host_arch"] and not (arch == "aarch64" and "arm64" in manifest["host_arch"]):
        raise SystemExit(f"manifest host_arch does not allow {arch}")
    if arch == "aarch64" and not toolchain:
        # 默认用 devkit 自带的交叉工具链：它会自动探测 dist/sdk 三件套并校验 Qt >= 6.5。
        # 不默认化的话，作者很容易在板端用系统 Qt 编出「能跑但 ABI 不对」的模块。
        toolchain = DEFAULT_AARCH64_TOOLCHAIN
        if not Path(toolchain).is_file():
            raise SystemExit(
                f"ARM64 release requires a cross toolchain, and {toolchain} is missing.\n"
                "把 SDK 三件套（Qt 6.5.3 aarch64 / 宿主 Qt / sysroot）放到 <devkit>/dist/sdk，\n"
                "或设置 ORPI_QT_PREFIX 与 ORPI_SYSROOT，再或者显式传 --toolchain <file>。\n"
                "Refusing to package a native host library as a Pi artifact.")
    build = output / "host-build"
    command = ["cmake", "-S", str(project), "-B", str(build), "-DMODULE_SDK_DIR=" + str(KIT / "sdk")]
    if toolchain: command.append("-DCMAKE_TOOLCHAIN_FILE=" + str(Path(toolchain).resolve()))
    subprocess.run(command, check=True)
    subprocess.run(["cmake", "--build", str(build), "--parallel"], check=True)
    _check_no_host_rpath(build / manifest["library"], arch)
    package_folder = output / "package"
    stage_project(project, build, package_folder, arch)
    signed = output / "signed-package"
    subprocess.run(["python3", str(KIT / "tools" / "package_tool.py"), "build",
                    str(package_folder), str(signed), str(Path(key).resolve()), arch], check=True)
    firmware_package = output / "firmware-package"
    subprocess.run(["python3", str(KIT / "module_devkit.py"), "prepare-firmware",
                    str(signed), str(firmware_package)], check=True)
    if firmware_mode:
        if not sdkconfig: raise SystemExit("--sdkconfig is required with --firmware-mode")
        env = dict(__import__("os").environ, PI_MODULE_SDKCONFIG=str(Path(sdkconfig).resolve()),
                   PI_MODULE_PACKAGE_DIR=str(firmware_package))
        subprocess.run([str(KIT / "firmware-build.sh"), str(project), firmware_mode,
                        str(output / ("firmware-" + firmware_mode.lower())),], env=env, check=True)
    print(f"release ready: {output}")

def default_qt_prefix():
    """本机 Qt 安装：优先目标基线 6.5.3，再退到 ~/Qt 下最高版本。"""
    candidates = [Path.home() / ".local/share/orange-pi-terminal-sdk/qt/6.5.3/gcc_64",
                  Path.home() / "Qt/6.5.3/gcc_64"]
    candidates += sorted((Path.home() / "Qt").glob("*/gcc_64"),
                         key=lambda p: tuple(int(x) for x in re.findall(r"\d+", p.parent.name)) or (0,),
                         reverse=True)
    for candidate in candidates:
        if (candidate / "lib/cmake/Qt6/Qt6Config.cmake").is_file():
            return candidate
    return None


def test_project(project, qt_prefix=None):
    """离屏验收：主机插件构建 + ctest（ABI/manifest/data_schema + QML 加载）。"""
    project = Path(project).resolve()
    manifest = project / "manifest.json"
    if manifest.is_file() and "@MODULE_ID@" in manifest.read_text(encoding="utf-8"):
        raise SystemExit("template 还不能直接测试：先用 module_devkit.py init 生成模块工程")
    build = project / "build-test"
    prefix = Path(qt_prefix).expanduser().resolve() if qt_prefix else default_qt_prefix()
    command = ["cmake", "-S", str(project), "-B", str(build),
               "-DMODULE_SDK_DIR=" + str(KIT / "sdk"), "-DMODULE_TESTING=ON"]
    if prefix:
        command.append("-DCMAKE_PREFIX_PATH=" + str(prefix))
    subprocess.run(command, check=True)
    subprocess.run(["cmake", "--build", str(build), "--parallel"], check=True)
    subprocess.run(["ctest", "--test-dir", str(build), "--output-on-failure"], check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    init = sub.add_parser("init", help="create a minimal C++ module")
    init.add_argument("destination"); init.add_argument("--module-id", type=int, required=True); init.add_argument("--name", required=True)
    check = sub.add_parser("validate", help="validate manifest and referenced files")
    check.add_argument("folder")
    check.add_argument("--require-binary", action="store_true", help="also require the built shared library")
    pack = sub.add_parser("package", help="build a signed package using package_tool.py")
    pack.add_argument("folder"); pack.add_argument("output"); pack.add_argument("key"); pack.add_argument("--arch", default="aarch64")
    embed = sub.add_parser("prepare-firmware", help="copy a signed host package for ESP embedding")
    embed.add_argument("package"); embed.add_argument("firmware_dir")
    sub.add_parser("doctor", help="check host-side SDK tools")
    stage = sub.add_parser("stage", help="collect library + all QML resources for separate signing")
    stage.add_argument("project"); stage.add_argument("build"); stage.add_argument("output")
    stage.add_argument("--arch", choices=("aarch64", "x86_64", "arm64"), required=True)
    test = sub.add_parser("test", help="build and run a module's offline tests")
    test.add_argument("project"); test.add_argument("--qt-prefix")
    release = sub.add_parser("release", help="build host package and optionally ESP32 firmware")
    release.add_argument("project"); release.add_argument("output"); release.add_argument("key")
    release.add_argument("--arch", default="native"); release.add_argument("--toolchain")
    release.add_argument("--firmware-mode", choices=("BLE", "LAN")); release.add_argument("--sdkconfig")
    schema = sub.add_parser("schema", help="data_schema draft/check/migrate")
    schema_sub = schema.add_subparsers(dest="schema_command", required=True)
    schema_init_p = schema_sub.add_parser(
        "init", help="generate a minimal data_schema draft from the host legacy field table + source scan")
    schema_init_p.add_argument("folder")
    schema_check_p = schema_sub.add_parser(
        "check", help="validate manifest data_schema with the host rules, then compare against append calls")
    schema_check_p.add_argument("folder")
    schema_check_p.add_argument("--strict", action="store_true",
                                help="fail when a dynamic payload/key cannot be verified statically")
    schema_migrate_p = schema_sub.add_parser(
        "migrate", help="add missing records/fields only; --force prints the impact diff and writes nothing")
    schema_migrate_p.add_argument("folder")
    schema_migrate_p.add_argument("--to", type=int, required=True)
    schema_migrate_p.add_argument(
        "--force", action="store_true",
        help="print the impact diff of removed/changed fields without modifying manifest")
    args = parser.parse_args()
    if args.command == "schema":
        if args.schema_command == "init": schema_init(args.folder)
        elif args.schema_command == "check": schema_check(args.folder, args.strict)
        elif args.schema_command == "migrate": schema_migrate(args.folder, args.to, args.force)
        return
    if args.command == "stage":
        stage_project(args.project, args.build, args.output, args.arch)
        return
    if args.command == "test":
        test_project(args.project, args.qt_prefix)
        return
    if args.command == "doctor":
        raise SystemExit(1 if doctor() else 0)
    if args.command == "release":
        release_project(args.project, args.output, args.key, args.arch, args.toolchain,
                        args.firmware_mode, args.sdkconfig)
        return
    if args.command == "init": init_project(args.destination, args.module_id, args.name); return
    if args.command == "prepare-firmware":
        source, target = Path(args.package), Path(args.firmware_dir)
        target.mkdir(parents=True, exist_ok=True)
        for source_name, target_name in (("package.json", "embedded_package.json"), ("package.tar.zst", "embedded_package.tar.zst")):
            source_file = source / source_name
            if not source_file.is_file(): raise SystemExit(f"missing signed package file: {source_file}")
            shutil.copyfile(source_file, target / target_name)
        print(f"prepared firmware package in {target}")
        return
    manifest = load_manifest(args.folder, require_binary=getattr(args, "require_binary", False) or args.command == "package")
    if args.command == "validate": print(json.dumps(manifest, ensure_ascii=False, indent=2)); return
    tool = KIT / "tools" / "package_tool.py"
    subprocess.run(["python3", str(tool), "build", args.folder, args.output, args.key, args.arch], check=True)

if __name__ == "__main__": main()
