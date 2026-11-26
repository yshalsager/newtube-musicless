#!/usr/bin/env python3
"""Build ios/App/Resources/Localizable.xcstrings from the Android app's strings (US-025).

The keys are the iOS app's own: the compiler lists them in `.stringsdata` files when
SWIFT_EMIT_LOC_STRINGS is on (build the app first). Each key is matched by its English text to an
Android string, first in the phone's files the PRD names (values/strings_mobile.xml,
strings_settings.xml, the musicless fork's strings_fork.xml), then in the shared common module's
strings.xml; the Arabic comes from the same key in values-ar, and the Android key becomes the
entry's comment. Keys without an Android match take their Arabic from
ios/tools/strings_ios_only_ar.json (reviewed by hand; comment "iOS only").

usage: ios/tools/import_android_strings.py [--build <derived data dir>] [--check]
  --check: exit 1 if a key has no Arabic (CI-friendly), without writing.

Never edits the Android files.
"""
import argparse
import glob
import json
import os
import re
import sys
import xml.etree.ElementTree as ET

HERE = os.path.dirname(os.path.abspath(__file__))
IOS = os.path.dirname(HERE)
ROOT = os.path.dirname(IOS)
CATALOG = os.path.join(IOS, 'App', 'Resources', 'Localizable.xcstrings')
IOS_ONLY = os.path.join(HERE, 'strings_ios_only_ar.json')

# (English file, Arabic file) in priority order.
SOURCES = [
    ('smarttubetv/src/stmobile/res/values/strings_mobile.xml', 'smarttubetv/src/stmobile/res/values-ar/strings_mobile.xml'),
    ('smarttubetv/src/stmobile/res/values/strings_settings.xml', 'smarttubetv/src/stmobile/res/values-ar/strings_settings.xml'),
    ('smarttubetv/src/musicless/res-text/values/strings_fork.xml', 'smarttubetv/src/musicless/res-text/values-ar/strings_fork.xml'),
    ('common/src/main/res/values/strings.xml', 'common/src/main/res/values-ar/strings.xml'),
]


def load(path):
    """name -> text of the translatable <string>s of an Android resource file."""
    try:
        root = ET.parse(os.path.join(ROOT, path)).getroot()
    except (OSError, ET.ParseError):
        return {}
    return {s.get('name'): ''.join(s.itertext()) for s in root.iter('string') if s.get('translatable') != 'false'}


def load_plurals(path):
    """name -> {quantity: text} of the <plurals> of an Android resource file."""
    try:
        root = ET.parse(os.path.join(ROOT, path)).getroot()
    except (OSError, ET.ParseError):
        return {}
    return {p.get('name'): {item.get('quantity'): ''.join(item.itertext()) for item in p.iter('item')}
            for p in root.iter('plurals')}


def plural_units(forms, key):
    """{quantity: stringUnit} with Android's placeholders as the key's specifiers."""
    return {quantity: {'stringUnit': {'state': 'translated', 'value': ios_placeholders(android_text(text), key)}}
            for quantity, text in forms.items()}


def android_text(text):
    """Android escapes out, placeholders as iOS's."""
    text = text.replace("\\'", "'").replace('\\"', '"').replace('\\n', '\n').replace('\\@', '@').strip()
    if len(text) >= 2 and text[0] == text[-1] == '"':
        text = text[1:-1]
    return text


def normalize(text):
    """For matching: placeholders unified, ellipses and final dots ignored, case-insensitive."""
    text = re.sub(r'%(\d+\$)?[sd@]|%lld', '%@', text)
    text = text.replace('...', '…').strip().rstrip('.').rstrip('…').strip()
    return text.lower()


def ios_placeholders(arabic, key):
    """Android's %1$s/%s/%d in the Arabic, as the key's iOS specifiers in order."""
    specs = re.findall(r'%lld|%@|%%', key)
    specs = [s for s in specs if s != '%%']
    out, index = [], 0

    def replace(match):
        nonlocal index
        spec = specs[index] if index < len(specs) else '%@'
        index += 1
        return spec
    arabic = re.sub(r'%(\d+\$)?[sd]', replace, arabic)
    return arabic


def keys_from_build(build):
    keys = {}
    for path in glob.glob(os.path.join(build, '**', 'Musicless.build', '**', '*.stringsdata'), recursive=True):
        with open(path) as handle:
            data = json.load(handle)
        for item in data.get('tables', {}).get('Localizable', []):
            keys.setdefault(item['key'], item.get('comment', ''))
    return keys


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--build', default=os.path.join(IOS, 'build', 'Build', 'Intermediates.noindex'))
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()

    keys = keys_from_build(args.build)
    if not keys:
        sys.exit('no .stringsdata under %s: build the app first' % args.build)

    index, plurals = {}, {}
    for english_file, arabic_file in SOURCES:
        english, arabic = load(english_file), load(arabic_file)
        for name, text in english.items():
            if name in arabic:
                index.setdefault(normalize(android_text(text)), (name, android_text(arabic[name])))
        # <plurals>, matched by their English "other" form: both languages' forms become variations.
        english_plurals, arabic_plurals = load_plurals(english_file), load_plurals(arabic_file)
        for name, forms in english_plurals.items():
            if name in arabic_plurals and 'other' in forms:
                plurals.setdefault(normalize(android_text(forms['other'])), (name, forms, arabic_plurals[name]))
    with open(IOS_ONLY, encoding='utf-8') as handle:
        ios_only = json.load(handle)

    strings, missing, from_android = {}, [], 0
    for key in sorted(keys, key=str.lower):
        plural = plurals.get(normalize(key))
        if plural:
            name, english_forms, arabic_forms = plural
            strings[key] = {'comment': 'Android: %s (plurals)' % name, 'localizations': {
                'en': {'variations': {'plural': plural_units(english_forms, key)}},
                'ar': {'variations': {'plural': plural_units(arabic_forms, key)}}}}
            from_android += 1
            continue
        match = index.get(normalize(key))
        if match:
            name, arabic = match
            comment = 'Android: %s' % name
            arabic = ios_placeholders(arabic, key)
            from_android += 1
        elif key in ios_only:
            comment, arabic = 'iOS only', ios_only[key]
        else:
            missing.append(key)
            strings[key] = {'comment': 'untranslated'}
            continue
        strings[key] = {'comment': comment,
                        'localizations': {'ar': {'stringUnit': {'state': 'translated', 'value': arabic}}}}

    print('keys %d: from Android %d, iOS only %d, untranslated %d'
          % (len(keys), from_android, len(keys) - from_android - len(missing), len(missing)))
    for key in missing:
        print('  untranslated: %r' % key)
    unused = sorted(set(ios_only) - set(keys))
    for key in unused:
        print('  unused in %s: %r' % (os.path.basename(IOS_ONLY), key))
    if args.check:
        sys.exit(1 if missing else 0)
    catalog = {'sourceLanguage': 'en', 'strings': strings, 'version': '1.0'}
    with open(CATALOG, 'w', encoding='utf-8') as handle:
        json.dump(catalog, handle, ensure_ascii=False, indent=2, sort_keys=True)
        handle.write('\n')
    print('wrote', os.path.relpath(CATALOG, ROOT))


if __name__ == '__main__':
    main()
