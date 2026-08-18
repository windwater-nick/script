#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import os
import shutil
import time
import logging
import requests
import yaml
from datetime import datetime


CONFIG_FILE = "config.yaml"
LIST_FILE = "soft-list.yaml"


# -----------------------
# HTTP 錯誤碼中文對照表
# -----------------------

HTTP_STATUS_MESSAGES = {
    401: "API Key / Token 無效或已過期",
    403: "已達 API 存取次數限制 (Rate Limit)",
    404: "專案不存在 (Repository 不存在) 或設為私有",
    422: "請求資源無法處理 (可能無 Release 發布記錄)",
    500: "GitHub 伺服器內部錯誤",
    502: "GitHub 閘道器錯誤 (Bad Gateway)",
    503: "GitHub 服務暫時不可用"
}


# -----------------------
# 設定 Logging 格式 (供 Warning/Error 除錯使用)
# -----------------------

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%H:%M:%S"
)


# -----------------------
# 讀取 YAML 設定
# -----------------------

def load_config():
    default_config = {
        "download": {
            "dir": "./download",
            "timeout": 30,
            "show_progress": True,
            "retry": {
                "count": 3,
                "delay": 5
            }
        },
        "github": {
            "api_key": None,
            "timeout": 15
        }
    }

    if not os.path.exists(CONFIG_FILE):
        print(f"[提示] 找不到 {CONFIG_FILE}，將使用預設設定。")
        return default_config

    try:
        with open(CONFIG_FILE, "r", encoding="utf-8") as f:
            user_config = yaml.safe_load(f) or {}

        dl_user = user_config.get("download", {})
        retry_user = dl_user.get("retry", {})
        gh_user = user_config.get("github", {})

        return {
            "download": {
                "dir": dl_user.get("dir", default_config["download"]["dir"]),
                "timeout": dl_user.get("timeout", default_config["download"]["timeout"]),
                "show_progress": dl_user.get("show_progress", default_config["download"]["show_progress"]),
                "retry": {
                    "count": retry_user.get("count", default_config["download"]["retry"]["count"]),
                    "delay": retry_user.get("delay", default_config["download"]["retry"]["delay"])
                }
            },
            "github": {
                "api_key": gh_user.get("api_key", default_config["github"]["api_key"]),
                "timeout": gh_user.get("timeout", default_config["github"]["timeout"])
            }
        }
    except Exception as e:
        logging.warning(f"解析 {CONFIG_FILE} 失敗: {e}，將使用預設設定。")
        return default_config


# -----------------------
# 初始化 requests.Session
# -----------------------

def create_session(github_token=None):
    session = requests.Session()
    session.headers.update({
        "User-Agent": "Soft-Downloader/1.0",
        "Accept": "application/vnd.github.v3+json"
    })
    
    if github_token:
        session.headers["Authorization"] = f"Bearer {github_token}"
        
    return session


# -----------------------
# 驗證 GitHub API KEY 狀態 (保持原 UI 面板樣式)
# -----------------------

def verify_github_token(session, timeout=15):
    print("=" * 60)
    print("正在檢查 GitHub API KEY 狀態與剩餘額度...")

    try:
        response = session.get("https://api.github.com/rate_limit", timeout=timeout)
    except Exception as e:
        logging.warning(f"網路連線失敗，無法驗證 API KEY: {e}")
        print("=" * 60)
        return

    if response.status_code != 200:
        has_token = "Authorization" in session.headers
        if has_token:
            print(f"[警告] API KEY 無效或無權限 (HTTP {response.status_code})！將降級為匿名存取。")
            session.headers.pop("Authorization", None)
        else:
            print("[提示] 未設定 API KEY，目前使用匿名存取模式。")

        try:
            anon_resp = session.get("https://api.github.com/rate_limit", timeout=timeout)
            if anon_resp.status_code == 200:
                core_info = anon_resp.json().get("resources", {}).get("core", {})
                remaining = core_info.get("remaining", 0)
                limit = core_info.get("limit", 60)
                reset_ts = core_info.get("reset", 0)
                reset_time = datetime.fromtimestamp(reset_ts).strftime('%H:%M:%S')

                print(f"       剩餘存取次數: {remaining} / {limit} (重置時間: {reset_time})")
        except Exception:
            pass
        print("=" * 60)
        return

    data = response.json()
    core_info = data.get("resources", {}).get("core", {})
    limit = core_info.get("limit", 5000)
    remaining = core_info.get("remaining", 0)
    reset_ts = core_info.get("reset", 0)
    reset_time = datetime.fromtimestamp(reset_ts).strftime('%H:%M:%S')

    username = "已驗證用戶"
    try:
        user_resp = session.get("https://api.github.com/user", timeout=timeout)
        if user_resp.status_code == 200:
            username = user_resp.json().get("login", username)
    except Exception:
        pass

    print(f"[成功] API KEY 正確可用！ (使用者: {username})")
    print(f"       剩餘存取次數: {remaining} / {limit}")
    print(f"       配額重置時間: {reset_time}")
    print("=" * 60)


# -----------------------
# 解析與 GitHub API 呼叫
# -----------------------

def parse_repo_name(link_or_repo):
    text = link_or_repo.strip()
    if "github.com/" in text:
        text = text.split("github.com/")[-1]

    parts = [p for p in text.strip("/").split("/") if p]
    if len(parts) >= 2:
        return f"{parts[0]}/{parts[1]}"
    return text


def fetch_latest_release(session, repo_identifier, timeout=15, retry_count=3, retry_delay=5):
    repo = parse_repo_name(repo_identifier)
    api_url = f"https://api.github.com/repos/{repo}/releases/latest"

    for attempt in range(1, retry_count + 1):
        try:
            r = session.get(api_url, timeout=timeout)
            if r.status_code == 200:
                return r.json()
            else:
                msg = HTTP_STATUS_MESSAGES.get(r.status_code, f"HTTP {r.status_code}")
                logging.warning(f"[{repo}] API 錯誤 ({r.status_code}): {msg} (嘗試 {attempt}/{retry_count})")
        except requests.RequestException as e:
            logging.warning(f"[{repo}] 網路連線失敗: {e} (嘗試 {attempt}/{retry_count})")

        if attempt < retry_count:
            time.sleep(retry_delay)

    return None


# -----------------------
# 篩選與檢查 Asset
# -----------------------

def match_asset(asset_name, item):
    name = asset_name.lower()
    include = [x.lower() for x in item.get("include", [])]
    exclude = [x.lower() for x in item.get("exclude", [])]

    for keyword in exclude:
        if keyword in name:
            return False

    if include:
        for keyword in include:
            if keyword in name:
                return True
        return False

    return True


def select_assets(release, item):
    assets = release.get("assets", [])
    return [asset for asset in assets if match_asset(asset["name"], item)]


def check_need_download(folder, filenames):
    for filename in filenames:
        if not os.path.exists(os.path.join(folder, filename)):
            return True
    return False


# -----------------------
# 歸檔舊檔案
# -----------------------

def archive_old(folder, keep_files):
    old_dir = os.path.join(folder, "old")
    os.makedirs(old_dir, exist_ok=True)

    for filename in os.listdir(folder):
        path = os.path.join(folder, filename)

        if not os.path.isfile(path):
            continue

        if filename in keep_files:
            continue

        shutil.move(path, os.path.join(old_dir, filename))


# -----------------------
# 下載執行核心
# -----------------------

def download_file(session, url, target, timeout=30, retry_count=3, retry_delay=5, show_progress=True):
    filename = os.path.basename(target)
    print(f"下載: {filename}")

    for attempt in range(1, retry_count + 1):
        try:
            r = session.get(url, stream=True, timeout=timeout)
            r.raise_for_status()

            total_size = int(r.headers.get('content-length', 0))
            block_size = 1024 * 64
            downloaded = 0

            with open(target, "wb") as f:
                for chunk in r.iter_content(chunk_size=block_size):
                    if chunk:
                        f.write(chunk)
                        downloaded += len(chunk)

                        if show_progress:
                            if total_size > 0:
                                percent = (downloaded / total_size) * 100
                                bar_length = 20
                                filled_length = int(bar_length * downloaded // total_size)
                                bar = '█' * filled_length + '-' * (bar_length - filled_length)
                                downloaded_mb = downloaded / (1024 * 1024)
                                total_mb = total_size / (1024 * 1024)
                                print(f"\r  └─ [{bar}] {percent:5.1f}% ({downloaded_mb:.1f}MB / {total_mb:.1f}MB)", end='', flush=True)
                            else:
                                downloaded_mb = downloaded / (1024 * 1024)
                                print(f"\r  └─ 下載中: {downloaded_mb:.1f} MB", end='', flush=True)

            if show_progress:
                print()
            return True

        except requests.RequestException as e:
            if show_progress and downloaded > 0:
                print()
            logging.error(f"下載失敗 ({filename}): {e} (嘗試 {attempt}/{retry_count})")

            if os.path.exists(target):
                try:
                    os.remove(target)
                except OSError:
                    pass

            if attempt < retry_count:
                time.sleep(retry_delay)

    return False


def download_assets(session, selected_assets, folder, config):
    dl_cfg = config["download"]
    retry_cfg = dl_cfg["retry"]

    for asset in selected_assets:
        target = os.path.join(folder, asset["name"])

        if os.path.exists(target):
            continue

        download_file(
            session,
            asset["browser_download_url"],
            target,
            timeout=dl_cfg["timeout"],
            retry_count=retry_cfg["count"],
            retry_delay=retry_cfg["delay"],
            show_progress=dl_cfg["show_progress"]
        )


# -----------------------
# 主排程 process() (維持原 UI 輸出結構)
# -----------------------

def process(session, item, download_root, config):
    name = item["name"]
    repo_target = item.get("repo") or item.get("link")
    
    if not repo_target:
        print(f"\n== {name} ==")
        logging.error("未找到 repo 或 link 欄位")
        return

    print(f"\n== {name} ({parse_repo_name(repo_target)}) ==")
    folder = os.path.join(download_root, name)
    os.makedirs(folder, exist_ok=True)

    # 1. API 取得最新版 Release
    gh_cfg = config["github"]
    retry_cfg = config["download"]["retry"]
    
    release = fetch_latest_release(
        session, repo_target,
        timeout=gh_cfg["timeout"],
        retry_count=retry_cfg["count"],
        retry_delay=retry_cfg["delay"]
    )
    if not release:
        print("取得 Release 失敗")
        return

    # 2. Select Assets
    selected = select_assets(release, item)
    if not selected:
        print("沒有符合版本")
        return

    # 3. Check Need Download
    filenames = [x["name"] for x in selected]
    if not check_need_download(folder, filenames):
        print("已是最新版本")
        return

    # 4. Archive
    archive_old(folder, filenames)

    # 5. Download Assets
    download_assets(session, selected, folder, config)


# -----------------------
# 主程式
# -----------------------

def main():
    config = load_config()
    download_root = config["download"]["dir"]

    session = create_session(github_token=config["github"]["api_key"])
    verify_github_token(session, timeout=config["github"]["timeout"])

    os.makedirs(download_root, exist_ok=True)

    if not os.path.exists(LIST_FILE):
        logging.error(f"找不到軟體清單檔案 {LIST_FILE}")
        return

    try:
        with open(LIST_FILE, "r", encoding="utf-8") as f:
            software_list = yaml.safe_load(f)
    except yaml.YAMLError as exc:
        logging.error(f"YAML 語法錯誤！{LIST_FILE} 格式不正確: {exc}")
        return

    if not software_list:
        print("軟體清單為空。")
        return

    for item in software_list:
        process(session, item, download_root, config=config)


if __name__ == "__main__":
    main()
