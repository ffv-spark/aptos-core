#!/bin/bash
# 列出所有可用的 Feature Flags（YAML 格式）
# 用途：自动生成可以直接复制到 YAML 配置中的 feature flags 列表

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FEATURE_FLAGS_FILE="$SCRIPT_DIR/aptos-move/aptos-release-builder/src/components/feature_flags.rs"

# 颜色定义
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${BLUE}=================================================${NC}"
echo -e "${BLUE}   Aptos Feature Flags - YAML 格式列表${NC}"
echo -e "${BLUE}=================================================${NC}"
echo ""

# 检查文件是否存在
if [ ! -f "$FEATURE_FLAGS_FILE" ]; then
    echo -e "${YELLOW}错误: 找不到 feature_flags.rs 文件${NC}"
    exit 1
fi

echo -e "${GREEN}从 Rust 枚举提取并转换为 snake_case...${NC}"
echo ""
echo -e "${BLUE}# 可以直接复制到 framework-upgrade-config.yaml 的 enabled: 部分${NC}"
echo ""

# 提取枚举并转换
grep -A 200 "pub enum FeatureFlag {" "$FEATURE_FLAGS_FILE" | \
    grep -E "^\s+[A-Z][a-zA-Z0-9]+" | \
    sed 's/,//g' | \
    awk '{print $1}' | \
    sed -r 's/([a-z0-9])([A-Z])/\1_\L\2/g; s/([A-Z]+)([A-Z][a-z])/\1_\2/g' | \
    tr '[:upper:]' '[:lower:]' | \
    sed 's/^/  - /'

echo ""
echo -e "${GREEN}=================================================${NC}"
echo -e "${GREEN}完成！共 $(grep -A 200 "pub enum FeatureFlag {" "$FEATURE_FLAGS_FILE" | grep -c -E "^\s+[A-Z][a-zA-Z0-9]+") 个 feature flags${NC}"
echo -e "${GREEN}=================================================${NC}"
echo ""
echo -e "${YELLOW}使用方法：${NC}"
echo "  1. 从上面复制需要的 feature flags"
echo "  2. 粘贴到 framework-upgrade-config.yaml 的 enabled: 部分"
echo ""
echo -e "${YELLOW}示例：${NC}"
echo "  - FeatureFlag:"
echo "      enabled:"
echo "        - code_dependency_check"
echo "        - module_event"
echo "        - vm_binary_format_v8"
echo ""
