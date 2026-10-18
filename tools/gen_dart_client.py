#!/usr/bin/env python3
"""Generate the app's Dart API client from api/openapi.yaml.

Writes app/lib/api/hive_api.g.dart: a model class per object schema and a
`HiveApi` method per operation (binary endpoints get a URL builder instead).

Usage:
  python3 tools/gen_dart_client.py           write the file
  python3 tools/gen_dart_client.py --check   fail if it is out of date (used in CI)

Needs PyYAML (installed with the server's dev dependencies).
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
SPEC = ROOT / "api" / "openapi.yaml"
OUT = ROOT / "app" / "lib" / "api" / "hive_api.g.dart"
METHODS = ("get", "post", "put", "patch", "delete")


def ref_name(ref: str) -> str:
    return ref.rsplit("/", 1)[-1]


def is_map_schema(schema: dict) -> bool:
    return schema.get("type") == "object" and not schema.get("properties")


class Gen:
    def __init__(self, spec: dict) -> None:
        self.spec = spec
        self.schemas: dict = spec["components"]["schemas"]

    # ------------------------------------------------------------- resolving
    def resolve(self, node: dict) -> dict:
        while "$ref" in node:
            parts = node["$ref"].lstrip("#/").split("/")
            target = self.spec
            for p in parts:
                target = target[p]
            node = target
        return node

    def dart_type(self, schema: dict) -> str:
        if "$ref" in schema:
            name = ref_name(schema["$ref"])
            return "Map<String, dynamic>" if is_map_schema(self.schemas[name]) else name
        t = schema.get("type")
        if t == "string":
            return "DateTime" if schema.get("format") == "date-time" else "String"
        if t == "integer":
            return "int"
        if t == "number":
            return "double"
        if t == "boolean":
            return "bool"
        if t == "array":
            return f"List<{self.dart_type(schema['items'])}>"
        return "Map<String, dynamic>"

    def from_json(self, schema: dict, expr: str) -> str:
        t = self.dart_type(schema)
        if t == "DateTime":
            return f"DateTime.parse({expr} as String)"
        if t == "double":
            return f"({expr} as num).toDouble()"
        if t.startswith("List<"):
            inner = self.from_json(schema["items"], "e")
            return f"({expr} as List<dynamic>).map((e) => {inner}).toList()"
        if t == "Map<String, dynamic>":
            return f"({expr} as Map).cast<String, dynamic>()"
        if t in ("String", "int", "bool"):
            return f"{expr} as {t}"
        return f"{t}.fromJson(({expr} as Map).cast<String, dynamic>())"

    def to_json(self, schema: dict, expr: str) -> str:
        t = self.dart_type(schema)
        if t == "DateTime":
            return f"{expr}.toUtc().toIso8601String()"
        if t.startswith("List<"):
            return f"{expr}.map((e) => {self.to_json(schema['items'], 'e')}).toList()"
        if t in ("String", "int", "bool", "double", "Map<String, dynamic>"):
            return expr
        return f"{expr}.toJson()"

    # ------------------------------------------------------------- models
    def model(self, name: str, schema: dict) -> str:
        props: dict = schema.get("properties", {})
        required = set(schema.get("required", []))
        lines = []
        if schema.get("description"):
            lines.append(f"/// {' '.join(schema['description'].split())}")
        lines.append(f"class {name} {{")
        ctor = [
            f"    {'required ' if p in required else ''}this.{p},"
            for p in props
        ]
        lines += [f"  const {name}({{", *ctor, "  });", ""]
        for p, s in props.items():
            described = self.resolve(s) if "$ref" in s else s
            if described.get("description"):
                lines.append(f"  /// {' '.join(described['description'].split())}")
            opt = "" if p in required else "?"
            lines.append(f"  final {self.dart_type(s)}{opt} {p};")
        lines.append("")
        lines.append(f"  factory {name}.fromJson(Map<String, dynamic> json) => {name}(")
        for p, s in props.items():
            conv = self.from_json(s, f"json['{p}']")
            if p in required:
                lines.append(f"        {p}: {conv},")
            else:
                lines.append(f"        {p}: json['{p}'] == null ? null : {conv},")
        lines.append("      );")
        lines.append("")
        lines.append("  Map<String, dynamic> toJson() => {")
        for p, s in props.items():
            if p in required:
                lines.append(f"        '{p}': {self.to_json(s, p)},")
            else:
                # Dart's null-aware element: the key is left out when the value is null.
                conv = self.to_json(s, p + "?")
                if conv == p + "?":  # plain value: no conversion to chain
                    conv = p
                lines.append(f"        '{p}': ?{conv},")
        lines.append("      };")
        lines.append("}")
        return "\n".join(lines)

    # ------------------------------------------------------------- operations
    def response_kind(self, op: dict) -> tuple[str, str | None]:
        """('json', DartType) | ('void', None) | ('binary', None)."""
        for code in ("200", "201", "206", "204"):
            if code not in op["responses"]:
                continue
            resp = self.resolve(op["responses"][code])
            content = resp.get("content")
            if not content:
                return ("void", None)
            if "application/json" in content:
                return ("json", self.dart_type(content["application/json"]["schema"]))
            return ("binary", None)
        return ("void", None)

    def query_arg(self, p: dict) -> tuple[str, str]:
        """(Dart parameter, map entry) for an optional query parameter."""
        schema = p.get("schema", {})
        t = {"integer": "int", "number": "double", "boolean": "bool"}.get(schema.get("type"), "String")
        name = p["name"]
        if p.get("required"):
            return f"required {t} {name}", f"'{name}': {name}"
        return f"{t}? {name}", f"'{name}': ?{name}"

    def body_type(self, op: dict) -> str | None:
        """The Dart type of a JSON request body, or None when there is none."""
        body = op.get("requestBody")
        if not body:
            return None
        content = self.resolve(body).get("content", {})
        if "application/json" not in content:
            return None
        schema = content["application/json"]["schema"]
        t = self.dart_type(schema)
        return t

    def operations(self) -> list[str]:
        out = []
        for path, item in self.spec["paths"].items():
            shared = item.get("parameters", [])
            for method in METHODS:
                if method not in item:
                    continue
                op = item[method]
                # The app never calls Hive Admin; the admin panel has its own client.
                if "admin" in op.get("tags", []):
                    continue
                params = [self.resolve(p) for p in shared + op.get("parameters", [])]
                path_params = [p["name"] for p in params if p["in"] == "path"]
                query = [self.query_arg(p) for p in params if p["in"] == "query"]
                body_t = self.body_type(op)
                kind, rtype = self.response_kind(op)
                dart_path = re.sub(r"\{(\w+)\}", r"${Uri.encodeComponent(\1)}", path)
                summary = op.get("summary", "").strip()
                doc = [f"  /// {summary}", "  ///", f"  /// `{method.upper()} {path}` · built in {op.get('x-milestone')}."]
                args = [f"required String {p}" for p in path_params]
                args += [a for a, _ in query]
                qmap = "{" + ", ".join(e for _, e in query) + "}" if query else None
                if kind == "binary":
                    sig = f"{{{', '.join(args)}}}" if args else ""
                    base = f"Uri.parse(_dio.options.baseUrl).resolve('{dart_path}')"
                    expr = f"_withQuery({base}, {qmap})" if qmap else base
                    out += doc + [
                        f"  Uri {op['operationId']}Uri({sig}) =>",
                        f"      {expr};",
                        "",
                    ]
                    continue
                if body_t:
                    args.insert(len(path_params), f"required {body_t} body")
                sig = f"{{{', '.join(args)}}}" if args else ""
                ret = "void" if kind == "void" else rtype
                call = f"'{method.upper()}', '{dart_path}'"
                if body_t:
                    call += ", data: body" if body_t.startswith("Map<") else ", data: body.toJson()"
                if qmap:
                    call += f", query: {qmap}"
                out += doc + [f"  Future<{ret}> {op['operationId']}({sig}) async {{"]
                if kind == "void":
                    out += [f"    await _send({call});", "  }", ""]
                else:
                    out += [f"    final data = await _send({call});"]
                    out += [f"    return {self.from_json(self._schema_of(op), 'data')};", "  }", ""]
        return out

    def _schema_of(self, op: dict) -> dict:
        for code in ("200", "201"):
            if code in op["responses"]:
                resp = self.resolve(op["responses"][code])
                return resp["content"]["application/json"]["schema"]
        raise KeyError(op["operationId"])

    # ------------------------------------------------------------- file
    def render(self) -> str:
        info = self.spec["info"]
        parts = [
            "// GENERATED by tools/gen_dart_client.py from api/openapi.yaml. Do not edit by hand.",
            "// ignore_for_file: unnecessary_cast, unnecessary_brace_in_string_interps, prefer_interpolation_to_compose_strings",
            "",
            "import 'package:dio/dio.dart';",
            "",
            f"/// Version of api/openapi.yaml this client was generated from.",
            f"const String hiveApiVersion = '{info['version']}';",
            "",
            "/// Thrown for any non-success response; carries the server's Problem body when present.",
            "class HiveApiException implements Exception {",
            "  HiveApiException(this.status, this.problem, [this.cause]);",
            "",
            "  /// HTTP status, or null when the server could not be reached at all.",
            "  final int? status;",
            "  final Problem? problem;",
            "  final Object? cause;",
            "",
            "  bool get unreachable => status == null;",
            "",
            "  @override",
            "  String toString() => 'HiveApiException(${status ?? 'unreachable'}: ${problem?.title ?? cause})';",
            "}",
            "",
        ]
        for name, schema in self.schemas.items():
            if is_map_schema(schema):
                continue
            parts += [self.model(name, schema), ""]
        parts += [
            "/// Every operation in the Hive API. Unbuilt ones answer 501 with their milestone.",
            "class HiveApi {",
            "  HiveApi(this._dio);",
            "",
            "  final Dio _dio;",
            "",
            "  Future<dynamic> _send(String method, String path, {Object? data, Map<String, Object?>? query}) async {",
            "    try {",
            "      final response = await _dio.request<dynamic>(",
            "        path,",
            "        data: data,",
            "        queryParameters: query == null ? null : {for (final e in query.entries) if (e.value != null) e.key: e.value},",
            "        options: Options(method: method),",
            "      );",
            "      return response.data;",
            "    } on DioException catch (e) {",
            "      final body = e.response?.data;",
            "      final problem = body is Map ? Problem.fromJson(body.cast<String, dynamic>()) : null;",
            "      throw HiveApiException(e.response?.statusCode, problem, e);",
            "    }",
            "  }",
            "",
            "  static Uri _withQuery(Uri uri, Map<String, Object?> query) {",
            "    final present = {for (final e in query.entries) if (e.value != null) e.key: '${e.value}'};",
            "    return present.isEmpty ? uri : uri.replace(queryParameters: present);",
            "  }",
            "",
            *self.operations(),
            "}",
            "",
        ]
        return "\n".join(parts)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    args = ap.parse_args()
    spec = yaml.safe_load(SPEC.read_text(encoding="utf-8"))
    content = Gen(spec).render()
    current = OUT.read_text(encoding="utf-8") if OUT.exists() else None
    if current == content:
        return 0
    if args.check:
        print(f"{OUT.relative_to(ROOT)} is out of date: run python3 tools/gen_dart_client.py")
        return 1
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(content, encoding="utf-8")
    print(f"wrote {OUT.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
