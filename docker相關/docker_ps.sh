#!/bin/bash

# 定義藍色粗體樣式
BLUE_BOLD='\033[1;34m'
NC='\033[0m' # 重設顏色

# 1. 產生資料內容 (包含排序與 Ports 清洗)
BODY_DATA=$(
    docker ps --format "{{.ID}}\t{{.Names}}\t{{.Status}}\t{{.Ports}}" | while IFS=$'\t' read -r id name status ports; do
        # 移除 0.0.0.0: 和 [::]: 的冗餘字串
        clean_ports=$(echo "$ports" | sed -E 's/(0\.0\.0\.0:|\[::\]:)//g' | sed 's/, /,/g' | awk -F, '
            {
                out = ""
                for(i=1; i<=NF; i++) {
                    if (!seen[$i]++) {
                        out = (out == "" ? $i : out "," $i)
                    }
                }
                print out
            }
        ')
        
        if [ -z "$clean_ports" ]; then
            clean_ports="-"
        fi
        
        printf "%s\t%s\t%s\t%s\n" "$id" "$name" "$status" "$clean_ports"
    done | sort -k2,2
)

# 2. 先將純文字的標頭與資料用 column 進行完美對齊，再單獨幫第一行上色
(
    printf "容器 ID\t容器名稱\t運行時間\t使用端口\n"
    echo "$BODY_DATA"
) | column -t -s $'\t' | while IFS= read -r line; do
    if [ -z "$header_printed" ]; then
        # 第一行（標頭）加上藍色粗體
        echo -e "${BLUE_BOLD}${line}${NC}"
        header_printed=1
    else
        # 其餘資料正常輸出
        echo "$line"
    fi
done

