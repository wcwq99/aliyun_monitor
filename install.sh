#!/bin/bash

# 检测是否通过 bash 执行，否则重新用 bash 执行
if [ -z "${BASH_VERSION:-}" ]; then
    echo "此脚本需要 bash 运行，正在重新以 bash 执行..."
    exec bash -c "$(wget -qO- https://raw.githubusercontent.com/wcwq99/aliyun_monitor/main/install.sh || curl -sS https://raw.githubusercontent.com/wcwq99/aliyun_monitor/main/install.sh)" bash
fi

# 不允许管道执行，提示用户先下载再运行
if [ ! -t 0 ]; then
    echo "请勿使用管道方式执行 (wget ... | bash)。正确用法:" >&2
    echo "  wget -qO install.sh https://raw.githubusercontent.com/wcwq99/aliyun_monitor/main/install.sh && bash install.sh" >&2
    exit 1
fi

# 定义颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# GitHub 仓库 raw 地址
REPO_URL="https://raw.githubusercontent.com/wcwq99/aliyun_monitor/main/src"
TARGET_DIR="/opt/scripts"
VENV_DIR="${TARGET_DIR}/venv"
CONFIG_FILE="${TARGET_DIR}/config.json"

# 全局变量，用于在函数间传递生成的 JSON 数据
CURRENT_USER_JSON=""

json_escape() {
    python3 -c 'import json, sys; print(json.dumps(sys.argv[1]))' "$1"
}

build_user_json() {
    local escaped_name escaped_ak escaped_sk escaped_region escaped_instance escaped_bill_endpoint escaped_currency
    escaped_name=$(json_escape "$NAME")
    escaped_ak=$(json_escape "$AK")
    escaped_sk=$(json_escape "$SK")
    escaped_region=$(json_escape "$REGION")
    escaped_instance=$(json_escape "$INSTANCE")
    escaped_bill_endpoint=$(json_escape "$BILL_ENDPOINT")
    escaped_currency=$(json_escape "$CURRENCY")

    CURRENT_USER_JSON=$(cat <<EOF
{"name": ${escaped_name}, "ak": ${escaped_ak}, "sk": ${escaped_sk}, "region": ${escaped_region}, "instance_id": ${escaped_instance}, "traffic_limit": ${LIMIT}, "quota": 200, "bill_endpoint": ${escaped_bill_endpoint}, "currency": ${escaped_currency}, "paused": false}
EOF
)
}

echo -e "${BLUE}=============================================================${NC}"
echo -e "${BLUE}    阿里云 CDT 流量监控 & 日报 一键部署/管理脚本 (修复增强版)  ${NC}"
echo -e "${BLUE}=============================================================${NC}"

if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}请使用 root 权限运行 (sudo -i)${NC}"
  exit 1
fi

# ================= 核心功能函数 =================

# 收集单个用户信息的函数
get_single_user_json() {
    local AK="" SK="" REGION="" INSTANCE="" NAME="" LIMIT="" BILL_ENDPOINT="" CURRENCY=""

    echo -e "\n${BLUE}>> 配置阿里云账号/实例信息${NC}"
    read -r -p "请输入备注名 (例如 HK-Server): " NAME

    echo -e "${CYAN}提示: AccessKey 在 RAM 用户详情页 -> 创建 AccessKey${NC}"
    read -r -p "AccessKey ID: " AK
    read -r -p "AccessKey Secret: " SK

    # --- 按实例区分国内外账单体系 ---
    echo -e "\n${CYAN}提示: 请选择该账号所属的阿里云类型 (决定账单查询节点与货币单位)${NC}"
    echo "  1) 国内区 (阿里云中国站，人民币 ￥ 结算)"
    echo "  2) 国际区 (阿里云国际站，美元 $ 结算)"
    read -r -p "请选择 (1-2, 默认 1): " ACC_TYPE_OPT
    if [ "$ACC_TYPE_OPT" = "2" ]; then
        BILL_ENDPOINT="business.ap-southeast-1.aliyuncs.com"
        CURRENCY="\$"
    else
        BILL_ENDPOINT="business.aliyuncs.com"
        CURRENCY="¥"
    fi
    echo -e "${GREEN}已设置为: 账单节点=$BILL_ENDPOINT | 货币=$CURRENCY${NC}\n"
    # --------------------------------------

    echo -e "${CYAN}提示: 请选择 ECS 实例所在的区域 (输入数字)${NC}"
    echo "  1) 香港 (cn-hongkong)"
    echo "  2) 新加坡 (ap-southeast-1)"
    echo "  3) 日本-东京 (ap-northeast-1)"
    echo "  4) 美国-硅谷 (us-west-1)"
    echo "  5) 美国-弗吉尼亚 (us-east-1)"
    echo "  6) 德国-法兰克福 (eu-central-1)"
    echo "  7) 英国-伦敦 (eu-west-1)"
    echo "  8) 手动输入其他区域代码"
    read -r -p "请选择 (1-8): " REGION_OPT

    case $REGION_OPT in
        1) REGION="cn-hongkong" ;;
        2) REGION="ap-southeast-1" ;;
        3) REGION="ap-northeast-1" ;;
        4) REGION="us-west-1" ;;
        5) REGION="us-east-1" ;;
        6) REGION="eu-central-1" ;;
        7) REGION="eu-west-1" ;;
        *) read -r -p "请输入 Region ID (如 cn-shanghai): " REGION ;;
    esac

    echo -e "${CYAN}提示: 请前往 ECS 控制台 -> 实例列表 -> 实例 ID 列 (以 i- 开头)${NC}"
    read -r -p "ECS 实例 ID: " INSTANCE

    read -r -p "关机阈值 (GB, 默认180): " LIMIT
    LIMIT=${LIMIT:-180}

    # 将构建好的 JSON 字符串赋值给全局变量 (去除了 resgroup，加入了 bill_endpoint 和 currency)
    build_user_json
}

# 完整安装流程 (首次运行)
run_full_install() {
    # 1. 目录准备
    if [ ! -d "$TARGET_DIR" ]; then
        mkdir -p "$TARGET_DIR"
        echo -e "${GREEN}创建目录: ${TARGET_DIR}${NC}"
    fi

    # 2. 安装依赖
    echo -e "${YELLOW}>> 安装系统依赖...${NC}"
    if [ -f /etc/debian_version ]; then
        apt-get update -y && apt-get install -y python3 python3-venv python3-pip cron wget
    elif [ -f /etc/redhat-release ]; then
        yum install -y python3 python3-pip cronie wget
        systemctl enable crond && systemctl start crond
    fi

    # 3. 虚拟环境
    if [ ! -d "$VENV_DIR" ]; then
        python3 -m venv "$VENV_DIR"
        echo -e "${GREEN}虚拟环境创建完成。${NC}"
    fi

    echo -e "${YELLOW}>> 安装 Python 依赖库...${NC}"
    "$VENV_DIR/bin/pip" install requests aliyun-python-sdk-core aliyun-python-sdk-ecs aliyun-python-sdk-bssopenapi --upgrade >/dev/null 2>&1

    # 4. 下载源码
    echo -e "${YELLOW}>> 从 GitHub 下载最新脚本...${NC}"
    wget -q -O "${TARGET_DIR}/monitor.py" "${REPO_URL}/monitor.py"
    wget -q -O "${TARGET_DIR}/report.py" "${REPO_URL}/report.py"

    if [ ! -s "${TARGET_DIR}/monitor.py" ]; then
        echo -e "${RED}下载失败！请检查网络或 GitHub 地址是否正确。${NC}"
        exit 1
    fi

    # 6. 交互式配置 Telegram
    echo -e "\n${BLUE}### 配置 Telegram ###${NC}"
    echo -e "1. 联系 ${CYAN}@BotFather${NC} -> 创建机器人获取 Token"
    echo -e "2. 联系 ${CYAN}@userinfobot${NC} -> 获取您的 Chat ID"
    read -r -p "请输入 Telegram Bot Token: " TG_TOKEN
    read -r -p "请输入 Telegram Chat ID: " TG_ID

    TG_TOKEN_JSON=$(json_escape "$TG_TOKEN")
    TG_ID_JSON=$(json_escape "$TG_ID")

    # 7. 配置阿里云对象
    USERS_JSON=""
    while true; do
        get_single_user_json

        if [ -z "$USERS_JSON" ]; then
            USERS_JSON="$CURRENT_USER_JSON"
        else
            USERS_JSON="$USERS_JSON, $CURRENT_USER_JSON"
        fi

        echo ""
        read -r -p "是否继续添加第二个账号/实例? (y/n): " CONTIN
        if [ "$CONTIN" != "y" ] && [ "$CONTIN" != "Y" ]; then
            break
        fi
    done

    # 8. 生成配置文件
    cat > "$CONFIG_FILE" <<EOF
{
    "telegram": {
        "bot_token": ${TG_TOKEN_JSON},
        "chat_id": ${TG_ID_JSON}
    },
    "users": [
        $USERS_JSON
    ]
}
EOF
    echo -e "${GREEN}配置文件已生成: ${CONFIG_FILE}${NC}"

    # 9. 设置 Crontab
    echo -e "${YELLOW}>> 配置定时任务...${NC}"
    crontab -l > /tmp/cron_bk 2>/dev/null
    grep -v "aliyun_monitor" /tmp/cron_bk > /tmp/cron_clean
    echo "*/5 * * * * ${VENV_DIR}/bin/python ${TARGET_DIR}/monitor.py >> ${TARGET_DIR}/monitor.log 2>&1 #aliyun_monitor" >> /tmp/cron_clean
    echo "0 9 * * * ${VENV_DIR}/bin/python ${TARGET_DIR}/report.py >> ${TARGET_DIR}/report.log 2>&1 #aliyun_monitor" >> /tmp/cron_clean
    crontab /tmp/cron_clean
    rm /tmp/cron_bk /tmp/cron_clean

    echo -e "\n${GREEN}安装与配置完成!${NC}"
    echo -e "您可以使用以下命令手动测试日报发送:"
    echo -e "${YELLOW}${VENV_DIR}/bin/python ${TARGET_DIR}/report.py${NC}"
}

# 管理菜单 (二次运行)
run_manage_menu() {
    while true; do
        echo ""
        echo -e "${GREEN}=====================================${NC}"
        echo -e "${YELLOW}已检测到存在配置文件，请选择管理操作:${NC}"
        echo "1) 添加新的监控实例 (Add)"
        echo "2) 删除已有监控实例 (Delete)"
        echo "3) 暂停/恢复监控实例 (Pause/Resume)"
        echo "4) 更新脚本并重置所有配置 (Update & Reset)"
        echo "5) 退出脚本 (Exit)"
        echo -e "${GREEN}=====================================${NC}"
        read -r -p "请输入序号 (1-5): " MENU_OPT

        case $MENU_OPT in
            1)
                get_single_user_json
                python3 -c "
import json
with open('$CONFIG_FILE', 'r') as f:
    data = json.load(f)
data['users'].append(json.loads('''$CURRENT_USER_JSON'''))
with open('$CONFIG_FILE', 'w') as f:
    json.dump(data, f, indent=4)
"
                echo -e "${GREEN}实例添加成功！配置文件已更新。${NC}"
                ;;
            2)
                echo -e "\n${BLUE}当前监控的实例列表:${NC}"
                python3 -c "
import json
with open('$CONFIG_FILE', 'r') as f:
    users = json.load(f).get('users', [])
if not users:
    print('当前没有配置任何监控实例。')
else:
    for i, u in enumerate(users):
        print(f' [{i}] 备注名: {u.get(\"name\")} | 实例ID: {u.get(\"instance_id\")} | 区域: {u.get(\"region\")}')
"
                echo ""
                read -r -p "请输入要删除的实例序号 (输入 q 取消): " DEL_IDX
                if [ "$DEL_IDX" = "q" ] || [ -z "$DEL_IDX" ]; then
                    continue
                fi
                python3 -c "
import json, sys
idx = int('$DEL_IDX')
with open('$CONFIG_FILE', 'r') as f:
    data = json.load(f)
try:
    removed = data['users'].pop(idx)
    with open('$CONFIG_FILE', 'w') as f:
        json.dump(data, f, indent=4)
    print(f'\n\033[0;32m成功删除实例: {removed.get(\"name\")} ({removed.get(\"instance_id\")})\033[0m')
except Exception as e:
    print(f'\n\033[0;31m删除失败: 无效的序号 {idx}\033[0m')
"
                ;;
            3)
                echo -e "\n${BLUE}当前监控的实例列表:${NC}"
                python3 -c "
import json
with open('$CONFIG_FILE', 'r') as f:
    users = json.load(f).get('users', [])
if not users:
    print('当前没有配置任何监控实例。')
else:
    for i, u in enumerate(users):
        paused = '已暂停' if u.get('paused') or u.get('disabled') else '运行中'
        print(f' [{i}] 备注名: {u.get(\"name\")} | 实例ID: {u.get(\"instance_id\")} | 状态: {paused}')
"
                echo ""
                read -r -p "请输入要切换暂停/恢复的实例序号 (输入 q 取消): " TOGGLE_IDX
                if [ "$TOGGLE_IDX" = "q" ] || [ -z "$TOGGLE_IDX" ]; then
                    continue
                fi
                python3 -c "
import json
idx = int('$TOGGLE_IDX')
with open('$CONFIG_FILE', 'r') as f:
    data = json.load(f)
try:
    user = data['users'][idx]
    paused = bool(user.get('paused') or user.get('disabled'))
    user['paused'] = not paused
    user.pop('disabled', None)
    with open('$CONFIG_FILE', 'w') as f:
        json.dump(data, f, indent=4)
    state = '已暂停' if user['paused'] else '已恢复'
    print(f'\n\033[0;32m成功切换实例: {user.get(\"name\")} ({user.get(\"instance_id\")}) -> {state}\033[0m')
except Exception:
    print(f'\n\033[0;31m操作失败: 无效的序号 {idx}\033[0m')
"
                ;;
            4)
                echo -e "${RED}此操作将更新代码并覆盖现有的 config.json!${NC}"
                read -r -p "确认要更新并重置配置吗？(y/n): " CONFIRM_REINSTALL
                if [ "$CONFIRM_REINSTALL" = "y" ] || [ "$CONFIRM_REINSTALL" = "Y" ]; then
                    run_full_install
                    exit 0
                fi
                ;;
            5)
                echo -e "${GREEN}退出脚本。${NC}"
                exit 0
                ;;
            *)
                echo -e "${RED}输入无效，请重新选择。${NC}"
                ;;
        esac
    done
}

# ================= 脚本入口 =================

if [ -f "$CONFIG_FILE" ]; then
    # 如果检测到 config.json 已存在，进入管理菜单
    run_manage_menu
else
    # 首次安装
    run_full_install
fi
