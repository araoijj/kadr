#!/usr/bin/env python3
"""Wraps Russian UI strings in tr("…") and exports templates for translation.

  python3 tools/i18n.py wrap      — wrap strings (safe to re-run)
  python3 tools/i18n.py extract   — tools/i18n/templates.json: Russian templates ({} in place of \\(…))
  python3 tools/i18n.py build     — Sources/Kadr/Translations.swift from tools/i18n/all.json
New UI string: wrap → extract → add the translation to all.json → build.
"""
import json, os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, 'Sources', 'Kadr')
OUT = os.path.join(ROOT, 'tools', 'i18n')
SKIP_FILES = {'Translations.swift', 'I18n.swift'}
CYR = re.compile(r'[А-Яа-яЁё]')
# Do not translate: file names, internal collection keys, keyboard layout letters.
KEEP = {'_Отклонённые', 'Documents/Фотосессии', 'Мои стили|Базовые', 'Мои стили', 'Базовые', 'Портрет', 'Пейзаж', 'Кино', 'Чёрно-белые', 'Плёнка'}

def literals(code):
    """String literals "…" (not triple-quoted), including nested \\( … "…" … ). Returns (start, end, body)."""
    i, n, out = 0, len(code), []
    while i < n:
        c = code[i]
        if code.startswith('//', i):            # comment until end of line
            j = code.find('\n', i); i = n if j < 0 else j; continue
        if code.startswith('"""', i):           # multi-line literal: skip
            j = code.find('"""', i + 3); i = n if j < 0 else j + 3; continue
        if c == '#' and code.startswith('#"', i):  # raw literal
            j = code.find('"#', i + 2); i = n if j < 0 else j + 2; continue
        if c == '"':
            j = i + 1
            while j < n and code[j] != '"':
                if code[j] == '\\' and j + 1 < n and code[j + 1] == '(':
                    depth, j = 1, j + 2
                    while j < n and depth:
                        if code[j] == '"':        # nested string inside an interpolation
                            j += 1
                            while j < n and code[j] != '"':
                                j += 2 if code[j] == '\\' else 1
                        elif code[j] == '(': depth += 1
                        elif code[j] == ')': depth -= 1
                        j += 1
                    continue
                j += 2 if code[j] == '\\' else 1
            out.append((i, j + 1, code[i + 1:j]))
            i = j + 1; continue
        i += 1
    return out

def wanted(body, code, start):
    if not CYR.search(body) or body in KEEP: return False
    if len(body) <= 2: return False                         # keys: "ч", "я"…
    if code[max(0, start - 3):start] == 'tr(': return False  # already wrapped
    return True

def runtime(body):
    """Swift literal → runtime string, interpolations → {}."""
    out, i = [], 0
    while i < len(body):
        if body.startswith('\\(', i):
            depth, j = 1, i + 2
            while j < len(body) and depth:
                if body[j] == '"':
                    j += 1
                    while j < len(body) and body[j] != '"': j += 2 if body[j] == '\\' else 1
                elif body[j] == '(': depth += 1
                elif body[j] == ')': depth -= 1
                j += 1
            out.append('{}'); i = j; continue
        if body[i] == '\\' and i + 1 < len(body):
            out.append({'n': '\n', 't': '\t', '"': '"', '\\': '\\'}.get(body[i + 1], body[i + 1])); i += 2; continue
        out.append(body[i]); i += 1
    return ''.join(out)

def files():
    return [os.path.join(SRC, f) for f in sorted(os.listdir(SRC)) if f.endswith('.swift') and f not in SKIP_FILES]

def wrap():
    total = 0
    for f in files():
        code = open(f).read()
        lits = [l for l in literals(code) if wanted(l[2], code, l[0])]
        for s, e, _ in reversed(lits):
            code = code[:s] + 'tr(' + code[s:e] + ')' + code[e:]
        if lits: open(f, 'w').write(code)
        total += len(lits)
    print('обёрнуто строк:', total)

def extract():
    os.makedirs(OUT, exist_ok=True)
    seen = []
    for f in files():
        code = open(f).read()
        for s, e, body in literals(code):
            if code[max(0, s - 3):s] == 'tr(' and CYR.search(body):
                t = runtime(body)
                if t not in seen: seen.append(t)
    # Internal keys shown via tr(variable): style collection names.
    for k in ['Мои стили', 'Базовые', 'Портрет', 'Пейзаж', 'Кино', 'Чёрно-белые', 'Плёнка']:
        if k not in seen: seen.append(k)
    json.dump(seen, open(os.path.join(OUT, 'templates.json'), 'w'), ensure_ascii=False, indent=1)
    print('шаблонов:', len(seen))

def swift_str(s):
    return '"' + s.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n').replace('\t', '\\t') + '"'

def build():
    """Translations.swift from tools/i18n/all.json: {Russian template: [en, es, it]}."""
    tpl = json.load(open(os.path.join(OUT, 'templates.json')))
    allt = json.load(open(os.path.join(OUT, 'all.json')))
    missing = [t for t in tpl if t not in allt]
    if missing: print(f'нет перевода для {len(missing)}:', missing[:10])
    lines = ['// Generated by tools/i18n.py build — do not edit by hand; translations live in tools/i18n/all.json.', '',
             'enum Translations {']
    for li, lang in enumerate(['en', 'es', 'it']):
        lines.append(f'    static let {lang}: [String: String] = [')
        for k in tpl:
            if k not in allt: continue
            v = allt[k][li]
            if k.count('{}') != v.count('{}') + sum(v.count('{%d}' % i) for i in range(1, 6)) or k.count('%') != v.count('%'):
                print(f'{lang}: подстановки не совпадают: {k!r} → {v!r}')
            lines.append(f'        {swift_str(k)}: {swift_str(v)},')
        lines.append('    ]')
    lines.append('}')
    open(os.path.join(SRC, 'Translations.swift'), 'w').write('\n'.join(lines) + '\n')
    print('Translations.swift готов:', len(tpl), 'шаблонов')

{'wrap': wrap, 'extract': extract, 'build': build}[sys.argv[1]]()
