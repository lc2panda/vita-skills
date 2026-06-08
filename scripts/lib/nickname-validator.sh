#!/usr/bin/env bash
# Input:  用户输入的昵称字符串 (stdin 或参数), 环境变量 LLM_API_ENDPOINT (可选)
# Output: 校验结果 JSON — 包含 pass/reject, reason, suggestions, device_fingerprint
# Pos:    打榜注册流程的前置校验关卡 — 确保昵称合法、唯一、合规

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ── 配置 ────────────────────────────────────────────────────────
NICKNAME_MIN_LENGTH="${NICKNAME_MIN_LENGTH:-1}"
NICKNAME_MAX_LENGTH="${NICKNAME_MAX_LENGTH:-20}"
NICKNAME_STATE_FILE="${VITA_STATE_DIR}/nickname_bindings.json"
SENSITIVE_WORDS_FILE="${VITA_STATE_DIR}/sensitive_words.txt"

# ── SHA-256 ─────────────────────────────────────────────────────
if ! declare -f vita_sha256 &>/dev/null; then
    vita_sha256() {
        if command -v shasum &>/dev/null; then
            echo -n "$1" | shasum -a 256 | cut -d' ' -f1
        elif command -v sha256sum &>/dev/null; then
            echo -n "$1" | sha256sum | cut -d' ' -f1
        else
            echo ""
        fi
    }
fi

# ── 第 1 层: 长度与字符集校验 ────────────────────────────────────
validate_charset() {
    local nickname="$1"
    local result="pass"
    local reason=""

    # 长度校验
    local len="${#nickname}"
    if [[ "${len}" -lt "${NICKNAME_MIN_LENGTH}" ]]; then
        echo '{"layer":"charset","verdict":"reject","reason":"昵称过短，至少需要1个字符"}'
        return 0
    fi
    if [[ "${len}" -gt "${NICKNAME_MAX_LENGTH}" ]]; then
        echo '{"layer":"charset","verdict":"reject","reason":"昵称过长，最多20个字符"}'
        return 0
    fi

    # 禁止纯数字
    if [[ "${nickname}" =~ ^[0-9]+$ ]]; then
        echo '{"layer":"charset","verdict":"reject","reason":"昵称不能为纯数字"}'
        return 0
    fi

    # 禁止纯符号
    if [[ "${nickname}" =~ ^[[:punct:][:space:]]+$ ]]; then
        echo '{"layer":"charset","verdict":"reject","reason":"昵称不能为纯符号"}'
        return 0
    fi

    # 禁止空白字符开头/结尾
    if [[ "${nickname}" =~ ^[[:space:]] ]] || [[ "${nickname}" =~ [[:space:]]$ ]]; then
        echo '{"layer":"charset","verdict":"reject","reason":"昵称不能以空白字符开头或结尾"}'
        return 0
    fi

    # 允许的字符范围:
    # - 中文 (CJK Unified Ideographs): U+4E00-U+9FFF
    # - 中文扩展: U+3400-U+4DBF, U+20000-U+2A6DF
    # - 日文平假名/片假名: U+3040-U+309F, U+30A0-U+30FF
    # - 韩文: U+AC00-U+D7AF
    # - 拉丁字母 (含扩展): U+0041-U+005A, U+0061-U+007A, U+00C0-U+024F
    # - 数字: U+0030-U+0039
    # - 下划线/连字符: U+005F, U+002D
    # - 英文空格: U+0020 (中间位置)
    #
    # 使用 Python 进行精确 Unicode 范围校验
    local charset_check
    charset_check="$(python3 -c "
import sys
import re

nickname = '''${nickname}'''

# 允许的 Unicode 范围
allowed_pattern = re.compile(
    r'^[\u4e00-\u9fff\u3400-\u4dbf\u3040-\u309f\u30a0-\u30ff'
    r'\uac00-\ud7af'
    r'\u0041-\u005a\u0061-\u007a\u00c0-\u024f'
    r'\u0030-\u0039'
    r'\u005f\u002d\u0020]+$'
)

# 禁止的不可见字符
invisible_chars = re.findall(r'[\u200b-\u200f\u2028-\u202f\u00a0\u2060-\u2064]', nickname)

if invisible_chars:
    print('INVISIBLE_CHAR')
    sys.exit(0)

if allowed_pattern.match(nickname):
    print('PASS')
else:
    # 找出非法字符
    bad_chars = set()
    for c in nickname:
        if not allowed_pattern.match(c):
            cp = ord(c)
            bad_chars.add(f'U+{cp:04X}')
    if bad_chars:
        print(f'ILLEGAL_CHARS:{chr(10).join(sorted(bad_chars))}')
    else:
        print('PASS')
" 2>/dev/null || echo "PASS")"

    if [[ "${charset_check}" == "PASS" ]]; then
        echo '{"layer":"charset","verdict":"pass"}'
    elif [[ "${charset_check}" == "INVISIBLE_CHAR" ]]; then
        echo '{"layer":"charset","verdict":"reject","reason":"昵称包含不可见字符"}'
    else
        local bad_desc="${charset_check#ILLEGAL_CHARS:}"
        echo "{\"layer\":\"charset\",\"verdict\":\"reject\",\"reason\":\"包含不允许的字符: ${bad_desc}\"}"
    fi
    return 0
}

# ── 第 2 层: Unicode 同形字检测 ──────────────────────────────────
detect_homoglyphs() {
    local nickname="$1"

    # 使用 Python 进行同形字检测
    # 已知同形字映射:
    # Cyrillic а (U+0430) -> Latin a (U+0061)
    # Cyrillic е (U+0435) -> Latin e (U+0065)
    # Cyrillic о (U+043E) -> Latin o (U+006F)
    # Cyrillic р (U+0440) -> Latin p (U+0070)
    # Cyrillic с (U+0441) -> Latin c (U+0063)
    # Cyrillic у (U+0443) -> Latin y (U+0079)
    # Cyrillic х (U+0445) -> Latin x (U+0078)
    # Greek ο (U+03BF) -> Latin o (U+006F)
    # Greek Α (U+0391) -> Latin A (U+0041)
    # Greek Β (U+0392) -> Latin B (U+0042)
    # Greek Ε (U+0395) -> Latin E (U+0045)
    # Greek Η (U+0397) -> Latin H (U+0048)
    # Greek Ι (U+0399) -> Latin I (U+0049)
    # Greek Κ (U+039A) -> Latin K (U+004B)
    # Greek Μ (U+039C) -> Latin M (U+004D)
    # Greek Ν (U+039D) -> Latin N (U+004E)
    # Greek Ο (U+039F) -> Latin O (U+004F)
    # Greek Ρ (U+03A1) -> Latin P (U+0050)
    # Greek Τ (U+03A4) -> Latin T (U+0054)
    # Greek Υ (U+03A5) -> Latin Y (U+0059)
    # Greek Χ (U+03A7) -> Latin X (U+0058)
    # Greek Ζ (U+0396) -> Latin Z (U+005A)

    local result
    result="$(python3 -c "
import sys

# 已知同形字映射: 混淆字符 -> 真正的 Latin 字符
HOMOGLYPH_MAP = {
    # Cyrillic -> Latin
    '\u0430': 'a', '\u0435': 'e', '\u043E': 'o', '\u0440': 'p',
    '\u0441': 'c', '\u0443': 'y', '\u0445': 'x',
    '\u0410': 'A', '\u0412': 'B', '\u0415': 'E', '\u041C': 'M',
    '\u041D': 'H', '\u041E': 'O', '\u0420': 'P', '\u0421': 'C',
    '\u0422': 'T', '\u0425': 'X',
    # Greek -> Latin
    '\u0391': 'A', '\u0392': 'B', '\u0395': 'E', '\u0397': 'H',
    '\u0399': 'I', '\u039A': 'K', '\u039C': 'M', '\u039D': 'N',
    '\u039F': 'O', '\u03A1': 'P', '\u03A4': 'T', '\u03A5': 'Y',
    '\u03A7': 'X', '\u0396': 'Z', '\u03BF': 'o',
    # Fullwidth Latin -> ASCII Latin
    '\uFF21': 'A', '\uFF22': 'B', '\uFF23': 'C', '\uFF24': 'D',
    '\uFF25': 'E', '\uFF26': 'F', '\uFF27': 'G', '\uFF28': 'H',
    '\uFF29': 'I', '\uFF2A': 'J', '\uFF2B': 'K', '\uFF2C': 'L',
    '\uFF2D': 'M', '\uFF2E': 'N', '\uFF2F': 'O', '\uFF30': 'P',
    '\uFF31': 'Q', '\uFF32': 'R', '\uFF33': 'S', '\uFF34': 'T',
    '\uFF35': 'U', '\uFF36': 'V', '\uFF37': 'W', '\uFF38': 'X',
    '\uFF39': 'Y', '\uFF3A': 'Z',
    '\uFF41': 'a', '\uFF42': 'b', '\uFF43': 'c', '\uFF44': 'd',
    '\uFF45': 'e', '\uFF46': 'f', '\uFF47': 'g', '\uFF48': 'h',
    '\uFF49': 'i', '\uFF4A': 'j', '\uFF4B': 'k', '\uFF4C': 'l',
    '\uFF4D': 'm', '\uFF4E': 'n', '\uFF4F': 'o', '\uFF50': 'p',
    '\uFF51': 'q', '\uFF52': 'r', '\uFF53': 's', '\uFF54': 't',
    '\uFF55': 'u', '\uFF56': 'v', '\uFF57': 'w', '\uFF58': 'x',
    '\uFF59': 'y', '\uFF5A': 'z',
}

nickname = '''${nickname}'''
suspicious_chars = []

for i, c in enumerate(nickname):
    if c in HOMOGLYPH_MAP:
        suspicious_chars.append({
            'position': i,
            'char': c,
            'codepoint': f'U+{ord(c):04X}',
            'looks_like': HOMOGLYPH_MAP[c],
            'script': 'Cyrillic' if 0x0400 <= ord(c) <= 0x04FF else
                      ('Greek' if 0x0370 <= ord(c) <= 0x03FF else
                       ('Fullwidth' if 0xFF00 <= ord(c) <= 0xFFEF else 'Unknown'))
        })

if suspicious_chars:
    import json
    print(json.dumps({'verdict': 'flag', 'suspicious': suspicious_chars}, ensure_ascii=False))
else:
    print('{\"verdict\": \"pass\"}')
" 2>/dev/null || echo '{"verdict":"pass"}')"

    echo "{\"layer\":\"homoglyph\",${result#\{}"
}

# ── 第 3 层: 敏感词匹配 ──────────────────────────────────────────
check_sensitive_words() {
    local nickname="$1"

    # 内置敏感词库（最小集合，实际部署时从远程获取）
    local builtin_sensitive=(
        # 政治人物（含别名变体）
        "习近平" "习大大" "习总" "总书记" "Xi Jinping" "xi jinping" "xijinping"
        "普京" "普京总统" "Putin" "putin"
        "特朗普" "川普" "懂王" "Trump" "trump"
        "拜登" "Biden" "biden"
        "金正恩" "金三胖" "三胖" "Kim Jong"
        "毛泽东" "毛主席" "邓小平" "周恩来" "朱德" "刘少奇"
        "奥巴马" "Obama" "obama"
        "希特勒" "Hitler" "hitler"
        "斯大林" "Stalin" "stalin"
        "朴正熙" "全斗焕" "卢武铉" "文在寅" "尹锡悦"
        "李光耀" "李显龙" "吴作栋" "黄循财"
        # 政治敏感词
        "法轮功" "法轮大法" "真善忍" "九评" "退党"
        "六四" "天安门" "法轮"
        "台独" "藏独" "疆独" "港独"
        # 色情/低俗
        "色情" "成人" "约炮" "一夜情"
        # 违法
        "毒品" "吸毒" "赌博" "赌场"
        # 冒充官方
        "管理员" "admin" "系统" "官方"
        "客服" "administrator" "root"
    )

    local nickname_lower
    if command -v python3 &>/dev/null; then
        nickname_lower="$(python3 -c "print('''${nickname}'''.lower())")"
    else
        nickname_lower="$(echo "${nickname}" | tr '[:upper:]' '[:lower:]')"
    fi

    for word in "${builtin_sensitive[@]}"; do
        local word_lower
        if command -v python3 &>/dev/null; then
            word_lower="$(python3 -c "print('''${word}'''.lower())")"
        else
            word_lower="$(echo "${word}" | tr '[:upper:]' '[:lower:]')"
        fi
        if [[ "${nickname_lower}" == *"${word_lower}"* ]]; then
            echo "{\"layer\":\"sensitive\",\"verdict\":\"reject\",\"reason\":\"包含敏感词: ${word}\",\"matched\":\"${word}\"}"
            return 0
        fi
    done

    # 检查外部敏感词库文件
    if [[ -f "${SENSITIVE_WORDS_FILE}" ]]; then
        while IFS= read -r ext_word; do
            [[ -z "${ext_word}" || "${ext_word}" =~ ^[[:space:]]*# ]] && continue
            local ext_lower
            if command -v python3 &>/dev/null; then
                ext_lower="$(python3 -c "print('''${ext_word}'''.lower())")"
            else
                ext_lower="$(echo "${ext_word}" | tr '[:upper:]' '[:lower:]')"
            fi
            if [[ "${nickname_lower}" == *"${ext_lower}"* ]]; then
                echo "{\"layer\":\"sensitive\",\"verdict\":\"reject\",\"reason\":\"包含敏感词: ${ext_word}\",\"matched\":\"${ext_word}\"}"
                return 0
            fi
        done < "${SENSITIVE_WORDS_FILE}"
    fi

    echo '{"layer":"sensitive","verdict":"pass"}'
}

# ── 第 4 层: AI 合规审查 ─────────────────────────────────────────
ai_compliance_check() {
    local nickname="$1"
    local llm_endpoint="${LLM_API_ENDPOINT:-}"

    if [[ -z "${llm_endpoint}" ]]; then
        echo '{"layer":"ai_compliance","verdict":"pass","note":"LLM_API_ENDPOINT not configured, skipped"}'
        return 0
    fi

    local prompt
    prompt="你是内容合规审查员。审查用户提交的昵称。拒绝以下情况：1.包含或暗示政治人物姓名（现任/历届，国内外）2.包含违法、暴力、仇恨、色情内容 3.包含广告、钓鱼、欺诈意图 4.冒充官方机构或公众人物。审查昵称：\"${nickname}\" 设备地区：zh-CN。返回JSON：{\"verdict\":\"pass\"|\"reject\",\"reason\":\"简洁的拒绝理由（中文，20字以内）\",\"suggestions\":[\"建议1\",\"建议2\"]}"

    local resp
    resp="$(curl -s -X POST "${llm_endpoint}" \
        -H 'Content-Type: application/json' \
        -d "{\"messages\":[{\"role\":\"user\",\"content\":\"${prompt}\"}],\"temperature\":0}" \
        --connect-timeout 15 --max-time 30 2>/dev/null || echo '{"verdict":"error","reason":"LLM request failed"}')"

    # 尝试解析 LLM 返回的 JSON
    local verdict
    verdict="$(echo "${resp}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('verdict','pass'))" 2>/dev/null || echo "pass")"
    if [[ "${verdict}" == "pass" ]]; then
        echo '{"layer":"ai_compliance","verdict":"pass"}'
    else
        local reason
        reason="$(echo "${resp}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('reason','AI判定不合规'))" 2>/dev/null || echo "AI判定不合规")"
        echo "{\"layer\":\"ai_compliance\",\"verdict\":\"reject\",\"reason\":\"${reason}\"}"
    fi
}

# ── 第 5 层: 设备指纹 + 唯一性绑定 ───────────────────────────────
generate_device_fingerprint() {
    # 指纹因子: hostname + machine-id + username + OS version + shell
    local hostname_str
    hostname_str="$(hostname 2>/dev/null || echo "unknown")"

    local machine_id=""
    case "${VITA_PLATFORM}" in
        macos)
            machine_id="$(ioreg -rd1 -c IOPlatformExpertDevice 2>/dev/null | grep -o '"IOPlatformUUID"[[:space:]]*=[[:space:]]*"[^"]*"' | sed 's/.*"\([^"]*\)"$/\1/' || echo "")"
            ;;
        linux)
            machine_id="$(cat /etc/machine-id 2>/dev/null || cat /var/lib/dbus/machine-id 2>/dev/null || echo "")"
            ;;
    esac
    machine_id="${machine_id:-unknown}"

    local username_str
    username_str="$(whoami 2>/dev/null || echo "unknown")"

    local os_version
    os_version="$(uname -s)-$(uname -r)"

    local shell_name
    shell_name="$(basename "${SHELL:-sh}")"

    local fingerprint_raw="${hostname_str}|${machine_id}|${username_str}|${os_version}|${shell_name}"
    local full_hash
    full_hash="$(vita_sha256 "${fingerprint_raw}")"
    # 取前 16 位
    echo "${full_hash:0:16}"
}

check_uniqueness() {
    local nickname="$1"
    local fingerprint="$2"

    ensure_state_dir
    if [[ ! -f "${NICKNAME_STATE_FILE}" ]]; then
        echo '{}' > "${NICKNAME_STATE_FILE}"
    fi

    local result
    result="$(python3 -c "
import json, sys

try:
    with open('${NICKNAME_STATE_FILE}', 'r') as f:
        bindings = json.load(f)
except:
    bindings = {}

nickname = '''${nickname}'''
fingerprint = '${fingerprint}'

# 检查: 是否有其他设备使用同一昵称
for fp, nick_list in bindings.items():
    if fp != fingerprint:
        if nickname in nick_list:
            print(json.dumps({
                'verdict': 'reject',
                'reason': '该昵称已被其他设备注册',
                'binding_conflict': fp[:8] + '...'
            }, ensure_ascii=False))
            sys.exit(0)

# 允许同一设备更换昵称 (更新绑定)
print(json.dumps({'verdict': 'pass'}, ensure_ascii=False))
" 2>/dev/null || echo '{"verdict":"pass"}')"

    echo "{\"layer\":\"uniqueness\",${result#\{}"
}

save_nickname_binding() {
    local nickname="$1"
    local fingerprint="$2"

    python3 -c "
import json, os

state_file = '${NICKNAME_STATE_FILE}'
os.makedirs(os.path.dirname(state_file), exist_ok=True)

try:
    with open(state_file, 'r') as f:
        bindings = json.load(f)
except:
    bindings = {}

fingerprint = '${fingerprint}'
nickname = '''${nickname}'''

if fingerprint not in bindings:
    bindings[fingerprint] = []

if nickname not in bindings[fingerprint]:
    bindings[fingerprint].append(nickname)

with open(state_file, 'w') as f:
    json.dump(bindings, f, ensure_ascii=False, indent=2)
" 2>/dev/null
}

# ── 全流程校验 ──────────────────────────────────────────────────
validate_nickname() {
    local nickname="${1:-}"
    if [[ -z "${nickname}" ]]; then
        echo '{"verdict":"reject","reason":"昵称不能为空","results":[]}' >&2
        echo '{"verdict":"reject","reason":"昵称不能为空","results":[]}'
        return 1
    fi

    local results=()
    local final_verdict="pass"
    local final_reason=""

    # Layer 1: 字符集
    local r1
    r1="$(validate_charset "${nickname}")"
    results+=("${r1}")
    if echo "${r1}" | grep -q '"reject"'; then
        final_verdict="reject"
        final_reason="$(echo "${r1}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('reason','字符校验未通过'))" 2>/dev/null || echo "字符校验未通过")"
    fi

    # Layer 2: 同形字
    if [[ "${final_verdict}" == "pass" ]]; then
        local r2
        r2="$(detect_homoglyphs "${nickname}")"
        results+=("${r2}")
        if echo "${r2}" | grep -q '"flag"'; then
            final_verdict="reject"
            final_reason="昵称包含混淆字符（Unicode同形字），可能用于伪装"
        fi
    fi

    # Layer 3: 敏感词
    if [[ "${final_verdict}" == "pass" ]]; then
        local r3
        r3="$(check_sensitive_words "${nickname}")"
        results+=("${r3}")
        if echo "${r3}" | grep -q '"reject"'; then
            final_verdict="reject"
            final_reason="$(echo "${r3}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('reason','敏感词校验未通过'))" 2>/dev/null || echo "敏感词校验未通过")"
        fi
    fi

    # Layer 4: AI 合规
    if [[ "${final_verdict}" == "pass" ]]; then
        local r4
        r4="$(ai_compliance_check "${nickname}")"
        results+=("${r4}")
        if echo "${r4}" | grep -q '"reject"'; then
            final_verdict="reject"
            final_reason="$(echo "${r4}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('reason','AI合规校验未通过'))" 2>/dev/null || echo "AI合规校验未通过")"
        fi
    fi

    # Layer 5: 设备指纹 + 唯一性
    local fingerprint
    fingerprint="$(generate_device_fingerprint)"
    local r5
    r5="$(check_uniqueness "${nickname}" "${fingerprint}")"
    results+=("${r5}")
    if echo "${r5}" | grep -q '"reject"'; then
        final_verdict="reject"
        final_reason="$(echo "${r5}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('reason','唯一性校验未通过'))" 2>/dev/null || echo "唯一性校验未通过")"
    fi

    # 如果通过，保存绑定
    if [[ "${final_verdict}" == "pass" ]]; then
        save_nickname_binding "${nickname}" "${fingerprint}"
    fi

    # 组装最终结果
    local results_json
    results_json="$(printf '%s\n' "${results[@]}" | paste -sd ',' -)"
    local ts
    ts="$(now_iso)"
    cat << EOF
{
  "verdict": "${final_verdict}",
  "reason": "${final_reason}",
  "nickname": "${nickname}",
  "device_fingerprint": "${fingerprint}",
  "timestamp": "${ts}",
  "results": [${results_json}]
}
EOF
}

# ── 便捷函数 ────────────────────────────────────────────────────
get_device_fingerprint() {
    generate_device_fingerprint
}

# ── CLI 入口 ────────────────────────────────────────────────────
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    MODE="${1:-validate}"
    case "${MODE}" in
        validate)
            NICKNAME="${2:-}"
            if [[ -z "${NICKNAME}" ]]; then
                echo "Usage: $0 validate <nickname>" >&2
                exit 1
            fi
            validate_nickname "${NICKNAME}"
            ;;
        fingerprint)
            get_device_fingerprint
            ;;
        *)
            echo "Usage: $0 {validate <nickname> | fingerprint}" >&2
            exit 1
            ;;
    esac
fi
