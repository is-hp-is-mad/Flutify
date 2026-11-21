#!/usr/bin/env python3
"""检查 lib/l10n 下的 ARB：键齐全、占位符一致、en 不混入中文、zh_Hant 不混入常见简体写法。

用法：python3 tool/check_l10n.py（有问题时退出码为 1）。
"""
import json
import re
import sys
from pathlib import Path

ARB = Path(__file__).resolve().parent.parent / 'lib' / 'l10n'
LANGS = ['zh', 'zh_Hant', 'en', 'ja']
CJK = re.compile(r'[一-鿿]')
KANA = re.compile(r'[぀-ヿ]')
# 语言自称（本来就是中文 / 日文）
SELF_NAMES = {'settingsLanguageZh', 'settingsLanguageZhHant', 'settingsLanguageJa'}
# zh_Hant 里不该出现的简体写法（与繁体写法不同形的常见字）
SIMPLIFIED = set('后于么标简实质较认证设应该给这个库码单号选项错载频过连线务网络显备储据现带听书视图览译语间击开关闭启动态变换检测刷数组话输账户宾众发经运进还从与为会说请让买卖红蓝绿颜铃响')
# 与简体同形、繁体也这样写的字不放进上面的集合；「于」只在“关于”里算错
SIMPLIFIED.discard('于')


def placeholders(value):
    """取出占位符名；{count, plural, ...} 取 count，嵌套的 {count} 同名只算一次。"""
    return set(re.findall(r'\{([A-Za-z_][A-Za-z0-9_]*)(?:,|\})', value))


def main():
    data = {l: json.loads((ARB / f'app_{l}.arb').read_text(encoding='utf-8')) for l in LANGS}
    text = {l: {k: v for k, v in d.items() if not k.startswith('@') and isinstance(v, str)} for l, d in data.items()}
    errors = []
    base = text['zh']
    for l in LANGS[1:]:
        for k in sorted(set(base) - set(text[l])):
            errors.append(f'{l}: 缺少 {k}')
        for k in sorted(set(text[l]) - set(base)):
            errors.append(f'{l}: 多出 {k}（zh 模板里没有）')
        for k, v in text[l].items():
            if k in base and placeholders(v) != placeholders(base[k]):
                errors.append(f'{l}: {k} 占位符与 zh 不一致 {sorted(placeholders(v))} != {sorted(placeholders(base[k]))}')
    for k, v in text['en'].items():
        if k not in SELF_NAMES and CJK.search(v):
            errors.append(f'en: {k} 含中文')
    for k, v in text['zh_Hant'].items():
        if k in SELF_NAMES:
            continue
        bad = sorted({c for c in v if c in SIMPLIFIED})
        if bad:
            errors.append(f'zh_Hant: {k} 含简体字 {"".join(bad)}')
        if '關于' in v:
            errors.append(f'zh_Hant: {k} 「關于」应为「關於」')
    for e in errors:
        print(e)
    print(f'l10n 检查：{len(base)} 个 key，{len(errors)} 个问题')
    return 1 if errors else 0


if __name__ == '__main__':
    sys.exit(main())
