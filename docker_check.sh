#!/bin/bash

# 定義歷史紀錄檔案名稱
HISTORY_FILE=".docker_check_history"
TARGET_DIR=""

# 讀取上次紀錄的路徑
get_last_dir() {
    if [ -f "$HISTORY_FILE" ]; then
        cat "$HISTORY_FILE"
    else
        echo ""
    fi
}

# 儲存路徑供下次使用
save_dir() {
    echo "$1" > "$HISTORY_FILE"
}

# 核心比對邏輯功能
run_scan() {
    local scan_dir="$1"
    
    # 檢查目錄是否存在
    if [ ! -d "$scan_dir" ]; then
        echo -e "\n❌ 錯誤：找不到目錄 [$scan_dir]，請重新確認路徑。"
        return 1
    fi

    # 1. 取得當前正在運行的容器名稱清單
    local running_containers
    running_containers=$(docker ps --format "{{.Names}}")

    echo -e "\n=================================================="
    echo " 開始比對 Docker 容器與目錄狀態 (已啟用忽略大小寫)..."
    echo " 檢查目錄: $scan_dir"
    echo "=================================================="

    local unused_count=0
    shopt -s nullglob

    # 2. 僅遍歷第一層子目錄
    for dir_path in "$scan_dir"/*; do
        if [ -d "$dir_path" ]; then
            local dir_name
            dir_name=$(basename "$dir_path")
            local is_used=false
            local matched_container=""
            
            # 3. 比對運行的容器名稱
            while read -r container_name; do
                if [ -n "$container_name" ]; then
                    # 轉小寫比對
                    local container_lower="${container_name,,}"
                    local dir_lower="${dir_name,,}"
                    
                    if [[ "$container_lower" == *"$dir_lower"* ]] || [[ "$dir_lower" == *"$container_lower"* ]]; then
                        is_used=true
                        matched_container="$container_name"
                        break
                    fi
                fi
            done <<< "$running_containers"
            
            # 4. 輸出結果
            if [ "$is_used" = true ]; then
                echo "✅ [使用中] 目錄: $dir_name (匹配到容器: $matched_container)"
            else
                echo "❌ [未掛載] 目錄: $dir_name <-- ⚠️ 建議清理"
                ((unused_count++))
            fi
        fi
    done

    shopt -u nullglob

    echo "=================================================="
    echo "比對完成！共發現 $unused_count 個不再被掛載使用的目錄。"
    echo -e "==================================================\n"
}

# 主選單循環
while true; do
    LAST_DIR=$(get_last_dir)
    
    echo "=== Docker 孤兒目錄掃描工具 ==="
    if [ -n "$LAST_DIR" ]; then
        echo "1. 掃描上次目錄 ($LAST_DIR)"
    else
        echo "1. 掃描上次目錄 (目前無歷史紀錄)"
    fi
    echo "2. 指定目錄"
    echo "3. 掃描當前目錄 ($(pwd))"
    echo "4. 退出腳本"
    echo "=============================="
    read -p "請選擇操作選項 (1-4): " choice

    case $choice in
        1)
            if [ -z "$LAST_DIR" ]; then
                echo -e "\n⚠️ 目前沒有歷史紀錄，請先使用選項 2 指定目錄。\n"
            else
                run_scan "$LAST_DIR"
            fi
            ;;
        2)
            read -p "請輸入目標目錄路徑 (例如 /home/docker): " input_dir
            # 移除輸入路徑末尾的斜線（如果有填的話，保持路徑乾淨）
            TARGET_DIR="${input_dir%/}"
            
            if [ -n "$TARGET_DIR" ]; then
                # 先執行掃描，成功才儲存路徑
                if run_scan "$TARGET_DIR"; then
                    save_dir "$TARGET_DIR"
                fi
            else
                echo -e "\n⚠️ 輸入的路徑不可為空！\n"
            fi
            ;;
        3)
            # 當前目錄使用 $(pwd)
            run_scan "$(pwd)"
            ;;
        4)
            echo "謝謝使用，再見！"
            exit 0
            ;;
        *)
            echo -e "\n❌ 無效的選項，請輸入 1 到 4 之間的數字。\n"
            ;;
    esac
done