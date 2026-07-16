import re
import tempfile
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

import xcstrings_to_compose as generator


class FormatSpecifierTests(unittest.TestCase):
    def test_numbers_unpositioned_object_arguments(self) -> None:
        self.assertEqual(
            "%1$s invited %2$s",
            generator.convert_format_specifiers("%@ invited %@"),
        )

    def test_preserves_explicit_argument_positions(self) -> None:
        self.assertEqual(
            "%2$s then %1$s",
            generator.convert_format_specifiers("%2$@ then %1$@"),
        )

    def test_unpositioned_arguments_do_not_collide_with_explicit_ones(self) -> None:
        self.assertEqual(
            "%2$s then %1$s",
            generator.convert_format_specifiers("%2$@ then %@"),
        )

    def test_does_not_convert_escaped_percent(self) -> None:
        self.assertEqual("%%@", generator.convert_format_specifiers("%%@"))


class ComposeEscapingTests(unittest.TestCase):
    def test_keeps_quotes_and_resource_like_prefixes_literal(self) -> None:
        self.assertEqual("friend's", generator.escape_compose_value("friend's"))
        self.assertEqual("@nickname", generator.escape_compose_value("@nickname"))
        self.assertEqual("?question", generator.escape_compose_value("?question"))

    def test_keeps_edge_whitespace_without_adding_quotes(self) -> None:
        self.assertEqual(" key ", generator.escape_compose_value(" key "))

    def test_protects_literal_backslashes_and_encodes_control_characters(self) -> None:
        self.assertEqual(r"\\n", generator.escape_compose_value(r"\n"))
        self.assertEqual(
            r"first\nsecond\tvalue",
            generator.escape_compose_value("first\nsecond\tvalue"),
        )

    def test_escapes_xml_text_characters(self) -> None:
        self.assertEqual(
            "one &amp; two &lt; three &gt; zero",
            generator.escape_compose_value("one & two < three > zero"),
        )


class LocaleQualifierTests(unittest.TestCase):
    def test_chinese_catalog_entries_expand_to_supported_regions(self) -> None:
        strings = {
            "hello": {
                "localizations": {
                    "en": {"stringUnit": {"value": "hello"}},
                    "zh-Hans": {"stringUnit": {"value": "你好"}},
                    "zh-Hant": {"stringUnit": {"value": "您好"}},
                }
            }
        }

        by_qualifier = generator.collect_by_locale(strings, {"hello": "hello"})

        for qualifier in ("zh", "zh-rCN", "zh-rSG"):
            self.assertEqual([("hello", "你好")], by_qualifier[qualifier])
        for qualifier in ("zh-rTW", "zh-rHK", "zh-rMO"):
            self.assertEqual([("hello", "您好")], by_qualifier[qualifier])


class GeneratedCatalogTests(unittest.TestCase):
    def test_catalog_has_only_numbered_compose_templates_and_literal_text(self) -> None:
        with tempfile.TemporaryDirectory(prefix="xcstrings_unit_") as tmp:
            tmp_path = Path(tmp)
            out_root = tmp_path / "composeResources"
            id_map_path = tmp_path / "string_id_map.json"
            generator.generate(out_root, id_map_path)

            for path in out_root.glob("values*/strings.xml"):
                for item in ET.parse(path).getroot():
                    value = item.text or ""
                    self.assertIsNone(
                        re.search(r"%(?!\d+\$[ds]|%)", value),
                        f"unsupported template in {path}: {item.attrib['name']}={value!r}",
                    )
                    self.assertNotIn(r"\'", value)
                    self.assertFalse(value.startswith(r"\@"))


if __name__ == "__main__":
    unittest.main()
