#!/usr/bin/env python3
"""检查 lib/l10n 下的 ARB：键齐全、占位符一致、en 不混入中文、zh_Hant 不混入简体写法、不使用术语表禁用写法。

用法：python3 tool/check_l10n.py（有问题时退出码为 1）。术语表见 docs/i18n-glossary.md。
"""
import json
import re
import sys
from pathlib import Path

ARB = Path(__file__).resolve().parent.parent / 'lib' / 'l10n'
LANGS = ['zh', 'zh_Hant', 'en', 'ja']
CJK = re.compile(r'[一-鿿]')
# 语言自称（本来就是中文 / 日文）
SELF_NAMES = {'settingsLanguageZh', 'settingsLanguageZhHant', 'settingsLanguageJa'}
# zh_Hant 里不该出现的简体写法（与繁体不同形的常见字）
SIMPLIFIED = set('后么标简实质较认证设应该给这个库码单号选项错载频过连线务网络显备储据现带听书视图览译语间击开关闭启动态变换检测刷数组话输账户宾众发经运进还从与为会说请让买卖红蓝绿颜铃响')
# 术语表里明令不用的写法：语言 -> {禁用词: 应改用}。依据 open.spotify.com 前端各语言的官方用词。
BANNED = {
    'zh': {'账号': '帐号', '媒体库': '音乐库', '资料库': '音乐库', '小部件': '小组件'},
    'zh_Hant': {
        '歌單': '播放清單', '點贊': '按讚', '添加': '新增', '搜索': '搜尋', '保存': '儲存', '主頁': '首頁',
        '播客': 'Podcast', '創建': '建立', '新建': '建立', '帳號': '帳戶', '隊列': '佇列', '媒體庫': '音樂庫',
        '任務欄': '工作列', '退出登入': '登出', '服務器': '伺服器', '音頻': '音訊', '默認': '預設', '信息': '資訊',
    },
    'en': {'Your library': 'Your Library', 'Sign in': 'Log in', 'sign in': 'log in', 'Sign out': 'Log out', 'sign out': 'log out', 'sign-in': 'login', 'Sign-in': 'Login'},
}


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
    for l, words in BANNED.items():
        for k, v in text[l].items():
            for bad, good in words.items():
                if bad in v:
                    errors.append(f'{l}: {k} 使用了术语表禁用的「{bad}」，应为「{good}」')
    for e in errors:
        print(e)
    print(f'l10n 检查：{len(base)} 个 key，{len(errors)} 个问题')
    return 1 if errors else 0


if __name__ == '__main__':
    sys.exit(main())
