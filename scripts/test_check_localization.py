"""Tests for the plural part of check-localization.py.

Usage: python3 -m unittest discover -s scripts -p 'test_*.py'
"""
import importlib.util
import pathlib
import plistlib
import shutil
import tempfile
import unittest

SCRIPT = pathlib.Path(__file__).resolve().parent / "check-localization.py"
spec = importlib.util.spec_from_file_location("check_localization", SCRIPT)
check = importlib.util.module_from_spec(spec)
spec.loader.exec_module(check)


class PluralTablesTest(unittest.TestCase):
    def setUp(self):
        self.app = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.app)
        for language in check.PLURAL_CATEGORIES:
            source = check.APP / f"{language}.lproj" / "Localizable.stringsdict"
            (self.app / f"{language}.lproj").mkdir()
            shutil.copy(source, self.app / f"{language}.lproj" / "Localizable.stringsdict")

    def errors(self):
        return check.check_plural_tables(self.app)

    def edit(self, language, change):
        path = self.app / f"{language}.lproj" / "Localizable.stringsdict"
        table = plistlib.loads(path.read_bytes())
        change(table)
        path.write_bytes(plistlib.dumps(table))

    def test_the_shipped_tables_pass(self):
        self.assertEqual(self.errors(), [])

    def test_a_deleted_table_fails(self):
        for language in check.PLURAL_CATEGORIES:
            with self.subTest(language=language):
                path = self.app / f"{language}.lproj" / "Localizable.stringsdict"
                kept = path.read_bytes()
                path.unlink()
                self.assertTrue(any(f"{language}.lproj/Localizable.stringsdict: missing" in e for e in self.errors()))
                path.write_bytes(kept)

    def test_a_rule_without_its_type_fails(self):
        def drop_type(table):
            entry = next(iter(table.values()))
            name = check.PLURAL_VARIABLE.search(entry["NSStringLocalizedFormatKey"]).group(2)
            del entry[name]["NSStringFormatSpecTypeKey"]

        self.edit("ar", drop_type)
        self.assertTrue(any("not an NSStringPluralRuleType rule" in e for e in self.errors()))

    def test_a_count_pointing_at_the_wrong_argument_fails(self):
        def point_elsewhere(table):
            table["%lld items in %@"] = {
                "NSStringLocalizedFormatKey": "%2$#@count@ in %2$@",
                "count": {
                    "NSStringFormatSpecTypeKey": "NSStringPluralRuleType",
                    "NSStringFormatValueTypeKey": "lld",
                    **{category: "%1$lld" for category in check.PLURAL_CATEGORIES["en"]},
                },
            }

        self.edit("en", point_elsewhere)
        self.assertTrue(any("points at an argument of another type" in e for e in self.errors()))

    def test_an_unnumbered_count_reads_the_argument_at_its_place(self):
        def object_first(table):
            table["%@ has %lld items"] = {
                "NSStringLocalizedFormatKey": "%#@count@",
                "count": {
                    "NSStringFormatSpecTypeKey": "NSStringPluralRuleType",
                    "NSStringFormatValueTypeKey": "lld",
                    **{category: "%@ has %lld items" for category in check.PLURAL_CATEGORIES["en"]},
                },
            }

        self.edit("en", object_first)
        self.assertTrue(any("'%@ has %lld items' %#@count@ points at an argument" in e for e in self.errors()))

    def test_an_unnumbered_count_after_another_argument_passes(self):
        def count_second(table):
            table["%@ has %lld items"] = {
                "NSStringLocalizedFormatKey": "%@ has %#@count@",
                "count": {
                    "NSStringFormatSpecTypeKey": "NSStringPluralRuleType",
                    "NSStringFormatValueTypeKey": "lld",
                    **{category: "%lld items" for category in check.PLURAL_CATEGORIES["en"]},
                },
            }

        self.edit("en", count_second)
        self.assertFalse(any("en.lproj" in e and "'%@ has %lld items'" in e for e in self.errors()))

    def test_a_value_type_with_trailing_text_fails(self):
        def trail(table):
            entry = next(iter(table.values()))
            name = check.PLURAL_VARIABLE.search(entry["NSStringLocalizedFormatKey"]).group(2)
            entry[name]["NSStringFormatValueTypeKey"] += " trailing"

        self.edit("ar", trail)
        self.assertTrue(any("trailing" in e and "which the key doesn't use" in e for e in self.errors()))


if __name__ == "__main__":
    unittest.main()
