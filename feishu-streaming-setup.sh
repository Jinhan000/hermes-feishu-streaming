#!/usr/bin/env bash
# =============================================================================
# feishu-streaming-setup.sh
# 飞书 Card Kit 流式输出 — 配置管理工具
# =============================================================================
# 用法:
#   ./feishu-streaming-setup.sh enable             启用流式（均衡模式）
#   ./feishu-streaming-setup.sh enable --edit-interval 0.4 --buffer-threshold 15
#   ./feishu-streaming-setup.sh disable             禁用流式
#   ./feishu-streaming-setup.sh status              查看当前配置
#   ./feishu-streaming-setup.sh restart             重启 Gateway
# =============================================================================

set -euo pipefail

CONFIG_FILE="${HERMES_HOME:-$HOME/.hermes}/config.yaml"
SCRIPTS_DIR="${HERMES_HOME:-$HOME/.hermes}/scripts"
LOG_FILE="${HERMES_HOME:-$HOME/.hermes}/logs/gateway.log"

# ── 颜色 ──
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

info()  { echo -e "${BLUE}ℹ${NC} $1"; }
ok()    { echo -e "${GREEN}✓${NC} $1"; }
warn()  { echo -e "${YELLOW}⚠${NC} $1"; }
err()   { echo -e "${RED}✗${NC} $1"; }

# ── 帮助 ──
show_help() {
  cat <<EOF
飞书 Card Kit 流式输出 — 配置管理工具

用法:
  $(basename "$0") enable [options]     启用飞书流式输出
  $(basename "$0") disable              禁用飞书流式输出
  $(basename "$0") status               查看当前配置状态
  $(basename "$0") restart              重启 Hermes Gateway

启用选项:
  --edit-interval SEC    编辑间隔秒数 (默认: 0.6)
  --buffer-threshold N   缓冲字符阈值 (默认: 25)
  --print-step N         Card Kit print_step (默认: 4, 需改源码)

示例:
  $(basename "$0") enable                          # 均衡模式
  $(basename "$0") enable --edit-interval 0.4      # 流畅优先
  $(basename "$0") enable --buffer-threshold 50    # 节省 API
EOF
}

# ── 检查 config.yaml 是否存在 ──
check_config() {
  if [[ ! -f "$CONFIG_FILE" ]]; then
    err "config.yaml 不存在: $CONFIG_FILE"
    exit 1
  fi
}

# ── 检查 yq 或 python 是否可用（用来解析 YAML） ──
check_yaml_tool() {
  if command -v python3 &>/dev/null; then
    echo "python3"
  elif command -v yq &>/dev/null; then
    echo "yq"
  else
    echo "none"
  fi
}

# ── 读取 config.yaml 指定路径的值 ──
yaml_get() {
  local path="$1"
  local tool
  tool=$(check_yaml_tool)
  case "$tool" in
    python3)
      python3 -c "
import yaml, sys
with open('$CONFIG_FILE') as f:
    d = yaml.safe_load(f)
parts = '$path'.split('.')
for p in parts:
    d = d.get(p, {}) if isinstance(d, dict) else {}
if not isinstance(d, (str, int, float, bool)):
    d = None
print(d if d is not None else '')
" 2>/dev/null || echo ""
      ;;
    yq)
      yq eval ".$path // \"\"" "$CONFIG_FILE" 2>/dev/null || echo ""
      ;;
    *)
      echo ""
      ;;
  esac
}

# ── 检查 feishu.py 中 print_step 当前值 ──
get_print_step() {
  local feishu_py="${HERMES_HOME:-$HOME/.hermes}/hermes-agent/gateway/platforms/feishu.py"
  if [[ -f "$feishu_py" ]]; then
    grep -o '"print_step": {"default": [0-9]*}' "$feishu_py" 2>/dev/null | grep -o '[0-9]*' || echo "4"
  else
    echo "unknown"
  fi
}

# ── 设置 print_step（可选，改源码） ──
set_print_step() {
  local step="$1"
  local feishu_py="${HERMES_HOME:-$HOME/.hermes}/hermes-agent/gateway/platforms/feishu.py"
  if [[ ! -f "$feishu_py" ]]; then
    warn "feishu.py 未找到，无法修改 print_step: $feishu_py"
    return 1
  fi
  local current
  current=$(get_print_step)
  if [[ "$current" == "$step" ]]; then
    ok "print_step 已是 $step"
    return 0
  fi
  if sed -i "s/\"print_step\": {\"default\": [0-9]*}/\"print_step\": {\"default\": $step}/" "$feishu_py" 2>/dev/null; then
    ok "print_step: $current → $step (已修改 feishu.py)"
  else
    warn "修改 print_step 失败，请手动编辑 feishu.py"
  fi
}

# ── 修改 config.yaml 中的值 ──
yaml_set() {
  local path="$1"
  local value="$2"
  local tmpfile
  tmpfile=$(mktemp)

  # 使用 python3+yaml 来保持格式
  python3 -c "
import yaml, sys

with open('$CONFIG_FILE') as f:
    data = yaml.safe_load(f) or {}

parts = '$path'.split('.')
current = data
for i, p in enumerate(parts[:-1]):
    if p not in current or not isinstance(current[p], dict):
        current[p] = {}
    current = current[p]

# Parse value type
val = '$value'
if val.lower() == 'true':
    val = True
elif val.lower() == 'false':
    val = False
elif val.isdigit():
    val = int(val)
elif val.replace('.', '', 1).isdigit() and val.count('.') == 1:
    val = float(val)

current[parts[-1]] = val

with open('$tmpfile', 'w') as f:
    yaml.dump(data, f, default_flow_style=False, allow_unicode=True, sort_keys=False)
" 2>/dev/null

  if [[ -s "$tmpfile" ]]; then
    mv "$tmpfile" "$CONFIG_FILE"
    return 0
  else
    rm -f "$tmpfile"
    return 1
  fi
}

# ── 启用流式 ──
cmd_enable() {
  local edit_interval="${1:-0.6}"
  local buffer_threshold="${2:-25}"
  local print_step="${3:-4}"

  check_config

  info "启用飞书 Card Kit 流式输出..."

  # 1. 设置 feishu.streaming
  yaml_set "feishu" "streaming" "true" 2>/dev/null || {
    # 如果 feishu 是标量，用 Python 方式写
    python3 -c "
import yaml
with open('$CONFIG_FILE') as f:
    data = yaml.safe_load(f) or {}
data.setdefault('feishu', {})['streaming'] = True
with open('$CONFIG_FILE', 'w') as f:
    yaml.dump(data, f, default_flow_style=False, allow_unicode=True, sort_keys=False)
"
  }
  ok "feishu.streaming = true"

  # 2. 设置 streaming 全局配置
  yaml_set "streaming" "enabled" "true" 2>/dev/null || {
    python3 -c "
import yaml
with open('$CONFIG_FILE') as f:
    data = yaml.safe_load(f) or {}
data.setdefault('streaming', {})['enabled'] = True
with open('$CONFIG_FILE', 'w') as f:
    yaml.dump(data, f, default_flow_style=False, allow_unicode=True, sort_keys=False)
"
  }
  yaml_set "streaming" "edit_interval" "$edit_interval"
  yaml_set "streaming" "buffer_threshold" "$buffer_threshold"
  ok "streaming.edit_interval = $edit_interval"
  ok "streaming.buffer_threshold = $buffer_threshold"

  # 3. 关闭 runtime_footer
  python3 -c "
import yaml
with open('$CONFIG_FILE') as f:
    data = yaml.safe_load(f) or {}
display = data.setdefault('display', {})
if isinstance(display, dict):
    footer = display.setdefault('runtime_footer', {})
    if isinstance(footer, dict):
        footer['enabled'] = False
with open('$CONFIG_FILE', 'w') as f:
    yaml.dump(data, f, default_flow_style=False, allow_unicode=True, sort_keys=False)
"
  ok "display.runtime_footer.enabled = false"

  # 4. 可选：设置 print_step
  if [[ "$print_step" != "4" ]]; then
    set_print_step "$print_step"
  fi

  echo
  echo -e "${GREEN}┌────────────────────────────────────────────────────────────┐${NC}"
  echo -e "${GREEN}│${NC}  飞书流式输出已启用                                       ${GREEN}│${NC}"
  echo -e "${GREEN}├────────────────────────────────────────────────────────────┤${NC}"
  printf "${GREEN}│${NC}  edit_interval:    ${BLUE}%-34s${NC} ${GREEN}│${NC}\n" "$edit_interval s"
  printf "${GREEN}│${NC}  buffer_threshold: ${BLUE}%-34s${NC} ${GREEN}│${NC}\n" "$buffer_threshold chars"
  printf "${GREEN}│${NC}  print_step:       ${BLUE}%-34s${NC} ${GREEN}│${NC}\n" "$(get_print_step) chars/reveal"
  echo -e "${GREEN}├────────────────────────────────────────────────────────────┤${NC}"
  echo -e "${GREEN}│${NC}  ${YELLOW}请重启 Gateway 使配置生效${NC}                                   ${GREEN}│${NC}"
  echo -e "${GREEN}│${NC}  ${BLUE}hermes gateway restart${NC}  或  ${BLUE}hermes gateway run --replace${NC}  ${GREEN}│${NC}"
  echo -e "${GREEN}└────────────────────────────────────────────────────────────┘${NC}"
}

# ── 禁用流式 ──
cmd_disable() {
  check_config

  info "禁用飞书 Card Kit 流式输出..."

  python3 -c "
import yaml
with open('$CONFIG_FILE') as f:
    data = yaml.safe_load(f) or {}
# 关闭 feishu.streaming
if 'feishu' in data and isinstance(data['feishu'], dict):
    data['feishu']['streaming'] = False
# 关闭全局 streaming
if 'streaming' in data and isinstance(data['streaming'], dict):
    data['streaming']['enabled'] = False
with open('$CONFIG_FILE', 'w') as f:
    yaml.dump(data, f, default_flow_style=False, allow_unicode=True, sort_keys=False)
"
  ok "飞书流式输出已禁用"
  echo
  echo "请重启 Gateway 使配置生效："
  echo "  hermes gateway restart"
}

# ── 查看状态 ──
cmd_status() {
  check_config

  echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
  echo -e "${BLUE}  飞书 Card Kit 流式输出 — 配置状态${NC}"
  echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
  echo

  # feishu.streaming
  fs=$(yaml_get "feishu.streaming")
  if [[ "$fs" == "True" || "$fs" == "true" ]]; then
    echo -e "  feishu.streaming:        ${GREEN}true${NC}"
  elif [[ "$fs" == "False" || "$fs" == "false" ]]; then
    echo -e "  feishu.streaming:        ${RED}false${NC}"
  else
    echo -e "  feishu.streaming:        ${YELLOW}未配置${NC}"
  fi

  # streaming.enabled
  se=$(yaml_get "streaming.enabled")
  if [[ "$se" == "True" || "$se" == "true" ]]; then
    echo -e "  streaming.enabled:       ${GREEN}true${NC}"
  else
    echo -e "  streaming.enabled:       ${RED}false${NC}"
  fi

  # streaming.edit_interval
  ei=$(yaml_get "streaming.edit_interval")
  echo -e "  streaming.edit_interval: ${BLUE}${ei:-未配置}${NC}"

  # streaming.buffer_threshold
  bt=$(yaml_get "streaming.buffer_threshold")
  echo -e "  streaming.buffer_threshold: ${BLUE}${bt:-未配置}${NC}"

  # print_step
  ps=$(get_print_step)
  echo -e "  print_step (源码):       ${BLUE}${ps}${NC}"

  # runtime_footer
  rf=$(yaml_get "display.runtime_footer.enabled")
  if [[ "$rf" == "False" || "$rf" == "false" ]]; then
    echo -e "  runtime_footer.enabled:  ${GREEN}false${NC}"
  else
    echo -e "  runtime_footer.enabled:  ${YELLOW}true (建议关掉)${NC}"
  fi

  # FEISHU_STREAMING env var
  if [[ -n "${FEISHU_STREAMING:-}" ]]; then
    echo -e "  FEISHU_STREAMING (env):  ${BLUE}$FEISHU_STREAMING${NC}"
  fi

  echo

  # Gateway 运行状态
  if pgrep -f "hermes.*gateway.*run" &>/dev/null || pgrep -f "python.*gateway.run" &>/dev/null; then
    echo -e "  Gateway:                 ${GREEN}运行中${NC}"
    # 最近 streaming 日志
    if [[ -f "$LOG_FILE" ]]; then
      recent=$(grep -i "streaming card" "$LOG_FILE" 2>/dev/null | tail -3)
      if [[ -n "$recent" ]]; then
        echo
        echo "  最近 streaming 事件:"
        echo "$recent" | while IFS= read -r line; do
          echo "    $line"
        done
      fi
    fi
  else
    echo -e "  Gateway:                 ${RED}未运行${NC}"
  fi

  echo
  echo -e "${BLUE}──────────────────────────────────────────────────────────${NC}"
}

# ── 重启 Gateway ──
cmd_restart() {
  info "正在重启 Hermes Gateway..."
  if command -v hermes &>/dev/null; then
    hermes gateway restart 2>/dev/null || hermes gateway run --replace 2>/dev/null || {
      warn "自动重启失败，请手动执行: hermes gateway restart"
    }
  else
    warn "hermes 命令未找到，请手动重启 Gateway"
  fi
}

# ── 主入口 ──
main() {
  if [[ $# -eq 0 ]]; then
    show_help
    exit 0
  fi

  case "$1" in
    enable)
      shift
      local edit_interval="0.6"
      local buffer_threshold="25"
      local print_step="4"

      while [[ $# -gt 0 ]]; do
        case "$1" in
          --edit-interval) edit_interval="$2"; shift 2 ;;
          --buffer-threshold) buffer_threshold="$2"; shift 2 ;;
          --print-step) print_step="$2"; shift 2 ;;
          *) err "未知参数: $1"; show_help; exit 1 ;;
        esac
      done

      cmd_enable "$edit_interval" "$buffer_threshold" "$print_step"
      ;;
    disable)
      cmd_disable
      ;;
    status)
      cmd_status
      ;;
    restart)
      cmd_restart
      ;;
    -h|--help|help)
      show_help
      ;;
    *)
      err "未知命令: $1"
      show_help
      exit 1
      ;;
  esac
}

main "$@"
