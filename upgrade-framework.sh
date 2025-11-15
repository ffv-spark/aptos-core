#!/bin/bash
# Aptos 多框架库升级自动化脚本
# 用途：一键执行框架升级的完整流程

set -e  # 遇到错误立即退出

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 配置参数
RELEASE_CONFIG="${RELEASE_CONFIG:-framework-upgrade-config.yaml}"
OUTPUT_DIR="${OUTPUT_DIR:-./framework-upgrade-output}"
NETWORK="${NETWORK:-testnet}"
POOL_ADDRESS="${POOL_ADDRESS:-}"

# 打印带颜色的日志
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 检查必要的工具
check_prerequisites() {
    log_info "检查必要的工具..."

    if ! command -v cargo &> /dev/null; then
        log_error "cargo 未安装，请先安装 Rust 工具链"
        exit 1
    fi

    if ! command -v aptos &> /dev/null; then
        log_warn "aptos CLI 未安装，正在安装..."
        cargo install --git https://github.com/aptos-labs/aptos-core.git aptos
    fi

    log_success "所有必要工具已就绪"
}

# 构建 release-builder
build_release_builder() {
    log_info "构建 aptos-release-builder..."
    cargo build --release -p aptos-release-builder
    log_success "aptos-release-builder 构建完成"
}

# 生成升级脚本
generate_proposals() {
    log_info "生成升级提案脚本..."

    if [ ! -f "$RELEASE_CONFIG" ]; then
        log_error "配置文件不存在: $RELEASE_CONFIG"
        exit 1
    fi

    cargo run --release -p aptos-release-builder -- \
        generate-proposals \
        --release-config "$RELEASE_CONFIG" \
        --output-dir "$OUTPUT_DIR"

    log_success "升级脚本已生成到: $OUTPUT_DIR"
}

# 模拟执行验证
simulate_proposals() {
    log_info "在 $NETWORK 上模拟执行提案..."

    cargo run --release -p aptos-release-builder -- \
        simulate \
        --network "$NETWORK" \
        --path "$OUTPUT_DIR"

    log_success "模拟执行通过！"
}

# 列出生成的脚本
list_generated_scripts() {
    log_info "生成的升级脚本列表："
    echo ""

    if [ -d "$OUTPUT_DIR/sources" ]; then
        ls -lh "$OUTPUT_DIR/sources/"*.move | while read -r line; do
            echo "  $line"
        done
    else
        log_warn "未找到生成的脚本文件"
    fi
    echo ""
}

# 提交提案
submit_proposal() {
    if [ -z "$POOL_ADDRESS" ]; then
        log_warn "未设置 POOL_ADDRESS 环境变量，跳过自动提交"
        log_info "请手动执行以下命令提交提案："
        echo ""
        echo "  export POOL_ADDRESS=<your_stake_pool_address>"
        echo "  aptos governance propose \\"
        echo "    --assume-yes \\"
        echo "    --pool-address \$POOL_ADDRESS \\"
        echo "    --script-path $OUTPUT_DIR/sources/0-move-stdlib.move"
        echo ""
        return
    fi

    log_info "提交治理提案..."

    # 查找第一个脚本文件
    FIRST_SCRIPT=$(ls "$OUTPUT_DIR/sources/"*.move 2>/dev/null | head -1)

    if [ -z "$FIRST_SCRIPT" ]; then
        log_error "未找到升级脚本"
        exit 1
    fi

    log_info "使用脚本: $FIRST_SCRIPT"

    aptos governance propose \
        --assume-yes \
        --pool-address "$POOL_ADDRESS" \
        --script-path "$FIRST_SCRIPT"

    log_success "提案已提交！"
}

# 显示使用说明
show_usage() {
    cat << EOF
Aptos 多框架库升级工具

用法:
    $0 [command]

命令:
    build       - 构建 release-builder 工具
    generate    - 生成升级提案脚本
    simulate    - 模拟执行提案（验证）
    submit      - 提交治理提案
    all         - 执行完整流程（build + generate + simulate）
    help        - 显示此帮助信息

环境变量:
    RELEASE_CONFIG - 配置文件路径（默认: framework-upgrade-config.yaml）
    OUTPUT_DIR     - 输出目录（默认: ./framework-upgrade-output）
    NETWORK        - 网络类型（默认: testnet，可选: mainnet, devnet）
    POOL_ADDRESS   - 质押池地址（提交提案时需要）

示例:
    # 执行完整流程
    $0 all

    # 仅生成脚本
    $0 generate

    # 提交提案
    POOL_ADDRESS=0x123...abc $0 submit

    # 使用自定义配置
    RELEASE_CONFIG=my-config.yaml OUTPUT_DIR=./output $0 all

EOF
}

# 主流程
main() {
    local command="${1:-all}"

    case "$command" in
        build)
            check_prerequisites
            build_release_builder
            ;;
        generate)
            check_prerequisites
            build_release_builder
            generate_proposals
            list_generated_scripts
            ;;
        simulate)
            check_prerequisites
            simulate_proposals
            ;;
        submit)
            check_prerequisites
            submit_proposal
            ;;
        all)
            log_info "开始执行完整升级流程..."
            check_prerequisites
            build_release_builder
            generate_proposals
            list_generated_scripts
            simulate_proposals
            log_success "所有步骤完成！"
            echo ""
            log_info "下一步操作："
            echo "  1. 检查生成的脚本: ls -lh $OUTPUT_DIR/sources/"
            echo "  2. 提交提案: POOL_ADDRESS=<your_pool> $0 submit"
            echo "  3. 投票: aptos governance vote --proposal-id <id> --should-pass true"
            ;;
        help|--help|-h)
            show_usage
            ;;
        *)
            log_error "未知命令: $command"
            show_usage
            exit 1
            ;;
    esac
}

# 执行主流程
main "$@"
