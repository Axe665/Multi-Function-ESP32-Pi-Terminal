#!/usr/bin/env bash
# 浏览器摇杆测试入口：功能 / 界面 / 性能 三层测试。
# 用法:
#   pi_terminal/tests/run_joystick_tests.sh                # 全部三层
#   pi_terminal/tests/run_joystick_tests.sh --benchmark    # 只跑性能层并打印指标
# 其余参数原样传给 cmake 配置。
set -euo pipefail

BENCH_ONLY=0
if [[ "${1:-}" == "--benchmark" ]]; then
    BENCH_ONLY=1
    shift
fi

SOURCE_DIR="$(dirname "$(dirname "$(realpath "${BASH_SOURCE[0]}")")")"
source "$SOURCE_DIR/scripts/env.sh"
BUILD_DIR="${BUILD_DIR:-$SOURCE_DIR/build-tests}"

cmake -S "$SOURCE_DIR" -B "$BUILD_DIR" \
      -DCMAKE_BUILD_TYPE="${CMAKE_BUILD_TYPE:-Release}" \
      -DBUILD_TESTING=ON "$@"

cmake --build "$BUILD_DIR" --parallel "${JOBS:-2}"

if [[ $BENCH_ONLY -eq 1 ]]; then
    TESTS=(browser_joystick_performance)
else
    TESTS=(browser_joystick_cursor browser_joystick_ui browser_joystick_performance)
fi

FAILED=0
for test in "${TESTS[@]}"; do
    echo ""
    echo "===== $test ====="
    if ! ctest --test-dir "$BUILD_DIR" -R "^${test}$" --output-on-failure; then
        FAILED=1
    fi
done

echo ""
if [[ $FAILED -eq 0 ]]; then
    echo "摇杆测试全部通过（${TESTS[*]}）"
else
    echo "存在失败用例，请查看上方输出" >&2
fi
exit $FAILED
