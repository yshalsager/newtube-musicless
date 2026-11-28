#!/usr/bin/env python3
"""Post a published NewTube Musicless release to a Telegram channel, in Arabic.

One message: the version, its Arabic changelog (musicless.json's changelog_ar, else the English
one) and a download link per APK, like the landing page's buttons. Files are linked, not attached:
the Bot API uploads at most 50 MB and the APKs are bigger. musicless-release.yml runs this when a
release is published, with TELEGRAM_BOT_TOKEN (secret) and TELEGRAM_CHAT_ID (@channel or -100...).
Locally:

    tools/musicless_telegram.py v1.17.1-musicless.5 --dry-run    # print the message, post nothing
    TELEGRAM_BOT_TOKEN=... TELEGRAM_CHAT_ID=@channel tools/musicless_telegram.py v1.17.1-musicless.5
"""
import argparse
import html
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request

REPO = "yshalsager/newtube-musicless"
MAX_TEXT = 4096  # Telegram's limit for a message
# Same order and words as the landing page (site/index.html).
ABIS = [("arm64-v8a", "الهواتف الحديثة (موصى به)"),
        ("armeabi-v7a", "الهواتف الأقدم (32 بت)"),
        ("universal", "كل الأجهزة"),
        ("x86", "أجهزة Intel")]


def changelog(manifest, name):
    entry = manifest.get(name, {})
    return entry.get("changelog_ar") or entry.get("changelog") or []


def message(release, notes, repo=REPO):
    name = release["tagName"].lstrip("v")
    owner, project = repo.split("/")
    links = []
    for abi, label in ABIS:
        asset = next((a for a in release["assets"] if a["name"].endswith(f"_{abi}.apk")), None)
        if asset:
            links.append(f'• <a href="{html.escape(asset["url"])}">{label}</a> · {round(asset["size"] / 1048576)} MB')
    tail = ("\n\n<b>التنزيل:</b>\n" + "\n".join(links) +
            "\n\nإن كان التطبيق مثبّتًا فسيُبلغك بالتحديث من داخله.\n"
            f'<a href="https://{owner}.github.io/{project}/">الموقع</a> · '
            f'<a href="{html.escape(release["url"])}">صفحة الإصدار</a>')
    head = f"<b>NewTube Musicless {html.escape(name)}</b>"
    lines = [f"• {html.escape(n)}" for n in notes]
    news = "\n\n<b>الجديد:</b>\n" + "\n".join(lines) if lines else ""
    while lines and len(head + news + tail) > MAX_TEXT:  # drop whole lines so no tag is cut
        lines.pop()
        news = "\n\n<b>الجديد:</b>\n" + "\n".join(lines + ["• …"])
    return head + news + tail


def gh(*args):
    return subprocess.run(["gh", *args, "-R", os.environ.get("GH_REPO", REPO)],
                          check=True, capture_output=True, text=True).stdout


def post(token, chat, text):
    data = json.dumps({"chat_id": chat, "text": text, "parse_mode": "HTML",
                       "link_preview_options": {"is_disabled": True}}).encode()
    req = urllib.request.Request(f"https://api.telegram.org/bot{token}/sendMessage", data=data,
                                 headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return json.load(r)["result"]["message_id"]
    except urllib.error.HTTPError as e:
        # Telegram explains the refusal ("chat not found", "not enough rights") in the body.
        sys.exit(f"Telegram refused the message: {json.load(e).get('description', e)}")


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("tag", help="published release tag, e.g. v1.17.1-musicless.5")
    ap.add_argument("--dry-run", action="store_true", help="print the message instead of posting")
    args = ap.parse_args()
    if not re.fullmatch(r"v[\d.]+-musicless\.\d+", args.tag):
        sys.exit(f"{args.tag} is not a Musicless release tag.")
    release = json.loads(gh("release", "view", args.tag, "--json", "tagName,url,isDraft,isPrerelease,assets"))
    if release["isDraft"] or release["isPrerelease"]:
        sys.exit(f"{args.tag} is a draft or a pre-release; only published releases are announced.")
    manifest = json.loads(gh("release", "download", args.tag, "-p", "musicless.json", "-O", "-"))
    text = message(release, changelog(manifest, args.tag.lstrip("v")), os.environ.get("GH_REPO", REPO))
    if args.dry_run:
        print(text)
        return
    token = os.environ.get("TELEGRAM_BOT_TOKEN", "").strip()
    chat = os.environ.get("TELEGRAM_CHAT_ID", "").strip()
    if not token or not chat:
        sys.exit("TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID must both be set.")
    print(f"Posted {args.tag} to {chat} (message {post(token, chat, text)}).")


if __name__ == "__main__":
    main()
